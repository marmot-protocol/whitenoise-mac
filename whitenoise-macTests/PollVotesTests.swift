import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// The "View votes" sheet's paging over MarmotKit's `pollVotes`, and how it restarts when the
/// poll's row is reprojected.
@MainActor
struct PollVotesTests: WorkspaceTestSupport {
    private static let alice = String(repeating: "a", count: 64)
    private static let bob = String(repeating: "b", count: 64)
    private static let carol = String(repeating: "c", count: 64)

    private static let poll = MessagePoll(
        question: "Lunch?",
        options: [
            .init(id: "0", label: "Tacos", votes: 2),
            .init(id: "1", label: "Ramen", votes: 2),
            .init(id: "2", label: "Pizza", votes: 0),
        ],
        kind: .multipleChoice,
        participants: 3,
        localSelection: [],
        endsAt: nil,
        isOpen: true
    )

    private static func vote(_ voter: String, _ options: [String], at votedAt: UInt64) -> PollVoteFfi {
        PollVoteFfi(voterAccountIdHex: voter, optionIds: options, votedAt: votedAt)
    }

    private static func model(runtime: FakeMarmotRuntime, pageSize: Int = 2) -> PollVotesViewModel {
        PollVotesViewModel(
            accountRef: "account",
            groupIdHex: "group",
            pollEventId: "poll",
            poll: poll,
            runtime: runtime,
            pageSize: pageSize
        )
    }

    // MARK: Paging

    @Test func pagesSumToTheTallyAndEachCursorIsThePreviousPagesLastVote() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.pollVotePages = [
            PollVotePageFfi(
                votes: [Self.vote(Self.alice, ["0"], at: 100), Self.vote(Self.bob, ["0", "1"], at: 200)],
                hasMoreAfter: true
            ),
            PollVotePageFfi(votes: [Self.vote(Self.carol, ["1"], at: 300)], hasMoreAfter: false),
        ]
        let model = Self.model(runtime: runtime)

        await model.reload().value
        #expect(model.hasMoreAfter)
        try await #require(model.loadMore()).value

        #expect(
            runtime.pollVotesRequests == [
                PollVotesRequest(
                    groupIdHex: "group", pollEventId: "poll", afterVotedAt: nil, afterVoterAccountIdHex: nil, limit: 2),
                PollVotesRequest(
                    groupIdHex: "group", pollEventId: "poll", afterVotedAt: 200, afterVoterAccountIdHex: Self.bob,
                    limit: 2),
            ])
        #expect(!model.hasMoreAfter)
        #expect(model.loadMore() == nil)
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.alice, Self.bob, Self.carol])

        let groups = model.groups(blockedAccountIDs: [])
        #expect(groups.map(\.option.id) == ["0", "1", "2"])
        // Every page together: each option's voters match its tally, and distinct voters match
        // the participant count even though Bob picked two options.
        for group in groups {
            #expect(UInt64(group.voters.count) == group.option.votes)
        }
        #expect(groups[0].voters.map(\.accountIdHex) == [Self.alice, Self.bob])
        #expect(groups[1].voters.map(\.accountIdHex) == [Self.bob, Self.carol])
        #expect(UInt64(Set(groups.flatMap(\.voters).map(\.accountIdHex)).count) == Self.poll.participants)
    }

    @Test func aReloadDiscardsAPageThatWasStillInFlight() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let gate = BlockingFfiGate()
        gate.isEnabled = true
        runtime.pollVotesGates = [gate]
        // The held first read answers with whatever is queued once it is released: the second
        // page here, which belongs to the list the reload threw away.
        runtime.pollVotePages = [
            PollVotePageFfi(votes: [Self.vote(Self.carol, ["1"], at: 300)], hasMoreAfter: false),
            PollVotePageFfi(votes: [Self.vote(Self.alice, ["0"], at: 100)], hasMoreAfter: true),
        ]
        let model = Self.model(runtime: runtime)

        let stale = model.reload()
        await Self.waitUntil { gate.didReach }
        await model.reload().value
        gate.release()
        await stale.value

        #expect(runtime.pollVotesRequests.count == 2)
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.carol])
        #expect(!model.hasMoreAfter)
        #expect(!model.isLoading)
    }

    @Test func loadMoreWaitsForTheReadInFlight() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let gate = BlockingFfiGate()
        gate.isEnabled = true
        runtime.pollVotesGates = [gate]
        runtime.pollVotePages = [
            PollVotePageFfi(votes: [Self.vote(Self.alice, ["0"], at: 100)], hasMoreAfter: true)
        ]
        let model = Self.model(runtime: runtime)

        let first = model.reload()
        await Self.waitUntil { gate.didReach }
        #expect(model.isLoading)
        #expect(model.loadMore() == nil)
        gate.release()
        await first.value

        #expect(runtime.pollVotesRequests.count == 1)
        #expect(model.hasMoreAfter)
    }

    @Test func aBlockedVoterStaysListedAndIsMarked() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.pollVotePages = [
            PollVotePageFfi(
                votes: [Self.vote(Self.alice, ["0"], at: 100), Self.vote(Self.bob.uppercased(), ["0"], at: 200)],
                hasMoreAfter: false
            )
        ]
        let model = Self.model(runtime: runtime)

        await model.reload().value
        let voters = model.groups(blockedAccountIDs: [Self.bob])[0].voters

        #expect(voters.map(\.accountIdHex) == [Self.alice, Self.bob.uppercased()])
        #expect(voters.map(\.isBlocked) == [false, true])
    }

    @Test func anEmptyPageEndsPagingWithNoVoters() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        // A missing, deleted, hidden or non-poll row reads as an empty page; one that still claims
        // more cannot advance the cursor, so paging stops rather than asking again forever.
        runtime.pollVotePages = [PollVotePageFfi(votes: [], hasMoreAfter: true)]
        let model = Self.model(runtime: runtime)

        await model.reload().value

        #expect(model.votes.isEmpty)
        #expect(!model.hasMoreAfter)
        #expect(!model.failed)
        #expect(model.loadMore() == nil)
        #expect(model.groups(blockedAccountIDs: []).allSatisfy { $0.voters.isEmpty })
    }

    @Test func theLimitIsClampedToMDKsRange() async {
        #expect(PollVotesPresentation.clampedLimit(0) == 1)
        #expect(PollVotesPresentation.clampedLimit(-5) == 1)
        #expect(PollVotesPresentation.clampedLimit(50) == 50)
        #expect(PollVotesPresentation.clampedLimit(100) == 100)
        #expect(PollVotesPresentation.clampedLimit(1_000) == 100)

        let runtime = FakeMarmotRuntime(accounts: [])
        await Self.model(runtime: runtime, pageSize: 1_000).reload().value
        await Self.model(runtime: runtime, pageSize: 0).reload().value

        #expect(runtime.pollVotesRequests.map(\.limit) == [100, 1])
    }

    @Test func aFailedPageKeepsWhatLoadedAndRetryResumesFromTheCursor() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.pollVotePages = [
            PollVotePageFfi(votes: [Self.vote(Self.alice, ["0"], at: 100)], hasMoreAfter: true),
            PollVotePageFfi(votes: [Self.vote(Self.bob, ["1"], at: 200)], hasMoreAfter: false),
        ]
        let model = Self.model(runtime: runtime)
        await model.reload().value

        runtime.pollVotesError = PollVotesReadFailure()
        try await #require(model.loadMore()).value
        #expect(model.failed)
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.alice])

        runtime.pollVotesError = nil
        try await #require(model.retry()).value

        #expect(!model.failed)
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.alice, Self.bob])
        #expect(runtime.pollVotesRequests.last?.afterVoterAccountIdHex == Self.alice)
        #expect(runtime.pollVotesRequests.last?.afterVotedAt == 100)
    }

    // MARK: Reprojection

    private static func pollRecord(votes: [UInt64]) -> TimelineMessageRecordFfi {
        var record = timelineMessage(
            id: "poll",
            groupIdHex: "group",
            sender: alice,
            plaintext: "Lunch?",
            kind: 1068,
            recordedAt: 1_700_000_000
        )
        record.poll = PollProjectionFfi(
            question: "Lunch?",
            options: votes.enumerated().map {
                PollOptionResultFfi(id: String($0.offset), label: ["Tacos", "Ramen"][$0.offset], votes: $0.element)
            },
            pollType: .multipleChoice,
            participants: votes.reduce(0, +),
            localSelection: [],
            creator: alice,
            endsAt: nil,
            open: true
        )
        return record
    }

    private static func snapshot(sequence: UInt64, votes: [UInt64]) -> ConversationWindowSnapshotFfi {
        var snapshot = ProjectionMigrationTests.conversationSnapshot(sequence: sequence, title: "Planning")
        snapshot.messages = [ProjectionMigrationTests.conversationMessage(pollRecord(votes: votes))]
        return snapshot
    }

    @Test func aReprojectedPollRowRestartsTheListFromTheFirstPage() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.conversationWindowInitialSnapshots["group"] = Self.snapshot(sequence: 1, votes: [1, 0])
        let conversation = ConversationViewModel(
            account: AccountItem.samples[0], groupIdHex: "group", runtime: runtime)
        conversation.start(mode: .latest)
        await Self.yieldUntil { conversation.snapshot != nil }
        let shown = try #require(
            conversation.snapshot?.messages.first?.timeline.poll.map(MessagePoll.init(projection:)))

        runtime.pollVotePages = [
            PollVotePageFfi(votes: [Self.vote(Self.alice, ["0"], at: 100)], hasMoreAfter: true)
        ]
        conversation.showPollVotes(messageIdHex: "poll", poll: shown)
        let sheet = try #require(conversation.pollVotes)
        await sheet.reload().value
        try await #require(sheet.loadMore()).value
        #expect(runtime.pollVotesRequests.count == 2)

        // A snapshot that carries the row unchanged leaves the list alone.
        runtime.pollVotePages = [
            PollVotePageFfi(
                votes: [Self.vote(Self.alice, ["0"], at: 100), Self.vote(Self.bob, ["1"], at: 200)],
                hasMoreAfter: false
            )
        ]
        runtime.conversationWindowUpdates["group"] = [
            Self.snapshot(sequence: 2, votes: [1, 0]),
            Self.snapshot(sequence: 3, votes: [1, 1]),
        ]
        conversation.start(mode: .latest)
        await Self.waitUntil { runtime.pollVotesRequests.count >= 3 && !sheet.isLoading }

        #expect(runtime.pollVotesRequests.count == 3)
        #expect(runtime.pollVotesRequests.last?.afterVotedAt == nil)
        #expect(runtime.pollVotesRequests.last?.afterVoterAccountIdHex == nil)
        #expect(sheet.poll?.options.map(\.votes) == [1, 1])
        #expect(sheet.votes.map(\.voterAccountIdHex) == [Self.alice, Self.bob])

        conversation.dismissPollVotes()
        #expect(conversation.pollVotes == nil)
        conversation.stop()
    }
}

private struct PollVotesReadFailure: Error {}
