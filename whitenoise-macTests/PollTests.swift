import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Rendering, voting, and composing kind-1068 polls from MDK's projected tally.
@MainActor
struct PollTests {
    private static let pollKind: UInt64 = 1068

    private static func poll(
        kind: MessagePoll.Kind = .singleChoice,
        votes: [UInt64] = [0, 0, 0],
        participants: UInt64 = 0,
        localSelection: [String] = [],
        endsAt: UInt64? = nil,
        isOpen: Bool = true
    ) -> MessagePoll {
        MessagePoll(
            question: "Lunch?",
            options: votes.enumerated().map {
                MessagePoll.Option(id: String($0.offset), label: "Option \($0.offset)", votes: $0.element)
            },
            kind: kind,
            participants: participants,
            localSelection: localSelection,
            endsAt: endsAt,
            isOpen: isOpen
        )
    }

    nonisolated private static func projection(
        localSelection: [String] = [],
        votes: [UInt64] = [1, 0]
    ) -> PollProjectionFfi {
        PollProjectionFfi(
            question: "Lunch on Friday?",
            options: votes.enumerated().map {
                PollOptionResultFfi(id: String($0.offset), label: ["Tacos", "Ramen"][$0.offset], votes: $0.element)
            },
            pollType: .multipleChoice,
            participants: 1,
            localSelection: localSelection,
            creator: String(repeating: "a", count: 64),
            endsAt: 2_000_000_000,
            open: true
        )
    }

    nonisolated private static func pollRecord(
        id: String = "poll",
        sender: String = "alice",
        projection: PollProjectionFfi? = projection()
    ) -> TimelineMessageRecordFfi {
        var record = timelineMessage(
            id: id,
            groupIdHex: "group",
            sender: sender,
            plaintext: "Lunch on Friday?",
            kind: pollKind,
            recordedAt: 1_700_000_000
        )
        record.poll = projection
        return record
    }

    private static func item(_ record: TimelineMessageRecordFfi, activeAccountIdHex: String = "self") throws
        -> MessageItem
    {
        try #require(
            MessageItem.timeline(
                from: TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
                activeAccountIdHex: activeAccountIdHex
            ).first)
    }

    private static func armedGate() -> AsyncFfiGate {
        let gate = AsyncFfiGate()
        gate.isEnabled = true
        return gate
    }

    private static func model(runtime: FakeMarmotRuntime) -> ConversationViewModel {
        ConversationViewModel(account: AccountItem.samples[0], groupIdHex: "group", runtime: runtime)
    }

    // MARK: Mapping

    @Test func aProjectedPollCarriesItsTallyAndALabelBody() throws {
        let message = try Self.item(Self.pollRecord())

        let poll = try #require(message.poll)
        #expect(message.presentation == .poll)
        #expect(poll.question == "Lunch on Friday?")
        #expect(poll.options.map(\.label) == ["Tacos", "Ramen"])
        #expect(poll.options.map(\.votes) == [1, 0])
        #expect(poll.kind == .multipleChoice)
        #expect(poll.endsAt == 2_000_000_000)
        #expect(message.body == MessageItem.pollLabel(question: "Lunch on Friday?"))
        #expect(!message.body.contains(L10n.string("This poll can’t be displayed.")))
    }

    @Test func aPollSitsOnItsAuthorsSide() throws {
        #expect(try Self.item(Self.pollRecord(sender: "self")).isOutgoing)
        #expect(try !Self.item(Self.pollRecord(sender: "alice")).isOutgoing)
    }

    @Test func aMalformedOrDeletedPollHasNoTally() throws {
        #expect(try Self.item(Self.pollRecord(projection: nil)).poll == nil)

        var deleted = Self.pollRecord()
        deleted.deleted = true
        #expect(try Self.item(deleted).poll == nil)
    }

    @Test func aChangedTallyMakesTheRowUnequal() throws {
        let before = try Self.item(Self.pollRecord(projection: Self.projection(votes: [1, 0])))
        let after = try Self.item(Self.pollRecord(projection: Self.projection(votes: [1, 1])))
        #expect(before != after)
    }

    // MARK: Selection

    @Test func singleChoiceClickReplacesTheVoteAndIgnoresTheCurrentChoice() {
        let order = ["0", "1", "2"]
        #expect(
            PollPresentation.toggledSelection(current: [], option: "1", kind: .singleChoice, optionOrder: order)
                == ["1"])
        #expect(
            PollPresentation.toggledSelection(current: ["1"], option: "2", kind: .singleChoice, optionOrder: order)
                == ["2"])
        #expect(
            PollPresentation.toggledSelection(current: ["1"], option: "1", kind: .singleChoice, optionOrder: order)
                == nil)
    }

    @Test func multipleChoiceTogglesInOptionOrderButNeverWithdrawsTheLastVote() {
        let order = ["0", "1", "2"]
        #expect(
            PollPresentation.toggledSelection(current: ["2"], option: "0", kind: .multipleChoice, optionOrder: order)
                == ["0", "2"])
        #expect(
            PollPresentation.toggledSelection(
                current: ["0", "2"], option: "2", kind: .multipleChoice, optionOrder: order) == ["0"])
        #expect(
            PollPresentation.toggledSelection(current: ["0"], option: "0", kind: .multipleChoice, optionOrder: order)
                == nil)
    }

    @Test func unknownOptionIsIgnored() {
        #expect(
            PollPresentation.toggledSelection(current: [], option: "9", kind: .singleChoice, optionOrder: ["0", "1"])
                == nil)
    }

    // MARK: Optimistic overlay

    @Test func firstLocalVoteAddsAParticipantAndAVote() {
        let result = PollPresentation.applyingLocalSelection(["1"], to: Self.poll(votes: [2, 0, 1], participants: 3))
        #expect(result.options.map(\.votes) == [2, 1, 1])
        #expect(result.participants == 4)
        #expect(result.localSelection == ["1"])
    }

    @Test func changedLocalVoteMovesTheVoteWithoutAddingAParticipant() {
        let base = Self.poll(votes: [2, 1, 1], participants: 4, localSelection: ["1"])
        let result = PollPresentation.applyingLocalSelection(["2"], to: base)
        #expect(result.options.map(\.votes) == [2, 0, 2])
        #expect(result.participants == 4)
    }

    @Test func overlayNeverUnderflowsAStaleZeroCount() {
        let base = Self.poll(votes: [0, 0, 0], participants: 1, localSelection: ["0"])
        #expect(PollPresentation.applyingLocalSelection(["1"], to: base).options.map(\.votes) == [0, 1, 0])
    }

    // MARK: Deadline and results

    @Test func pollClosesAtItsDeadlineEvenWhenProjectedOpen() {
        let base = Self.poll(endsAt: 1_000)
        #expect(PollPresentation.isOpen(base, now: Date(timeIntervalSince1970: 1_000)))
        #expect(!PollPresentation.isOpen(base, now: Date(timeIntervalSince1970: 1_001)))
        #expect(!PollPresentation.isOpen(Self.poll(isOpen: false), now: Date(timeIntervalSince1970: 0)))
    }

    @Test func resultFractionIsShareOfVoters() {
        #expect(PollPresentation.fraction(votes: 0, participants: 0) == 0)
        #expect(PollPresentation.fraction(votes: 1, participants: 4) == 0.25)
        #expect(PollPresentation.fraction(votes: 9, participants: 4) == 1)
    }

    @Test func footerSaysFinalResultsOnceClosed() {
        let closed = PollFooter.text(poll: Self.poll(participants: 2, isOpen: false), isOpen: false)
        #expect(closed.contains(L10n.string("Final results")))
        #expect(closed.hasPrefix(L10n.plural("%lld votes", Int64(2))))
    }

    // MARK: Draft validation

    @Test func draftSubmitsTrimmedSingleLineTextAndSkipsBlankRows() throws {
        var draft = PollDraft()
        draft.question = "  Where\nto eat?  "
        draft.options = [" Tacos ", "", "Ramen\u{202E}"]
        let submission = try draft.validated(now: Date(timeIntervalSince1970: 100)).get()
        #expect(submission.question == "Where to eat?")
        #expect(submission.options == ["Tacos", "Ramen"])
        #expect(submission.pollType == .singleChoice)
        #expect(submission.endsAt == nil)
    }

    @Test func draftDurationAndMultipleAnswersMapToMDKFields() throws {
        var draft = PollDraft()
        draft.question = "Days?"
        draft.options = ["Mon", "Tue"]
        draft.allowsMultipleAnswers = true
        draft.duration = .oneDay
        let submission = try draft.validated(now: Date(timeIntervalSince1970: 100)).get()
        #expect(submission.pollType == .multipleChoice)
        #expect(submission.endsAt == 100 + 86_400)
    }

    @Test func draftRejectsInputMDKWouldRefuse() {
        var draft = PollDraft()
        draft.options = ["A", "B"]
        #expect(draft.validated(now: .now) == .failure(.missingQuestion))

        draft.question = String(repeating: "q", count: PollDraft.maximumQuestionBytes + 1)
        #expect(draft.validated(now: .now) == .failure(.questionTooLong))

        draft.question = "Q"
        draft.options = ["A", "  "]
        #expect(draft.validated(now: .now) == .failure(.tooFewOptions))

        draft.options = ["A", String(repeating: "é", count: 129)]
        #expect(draft.validated(now: .now) == .failure(.optionTooLong))

        draft.options = ["Yes", "yes"]
        #expect(draft.validated(now: .now) == .failure(.duplicateOption))
    }

    @Test func draftKeepsBetweenTwoAndTenOptionRows() {
        var draft = PollDraft()
        #expect(!draft.canRemoveOption)
        draft.removeOption(at: 0)
        #expect(draft.options.count == 2)
        for _ in 0..<20 { draft.addOption() }
        #expect(draft.options.count == PollDraft.maximumOptions)
        #expect(!draft.canAddOption)
        draft.removeOption(at: 3)
        #expect(draft.options.count == PollDraft.maximumOptions - 1)
    }

    // MARK: Composer menu

    @Test func pollAppearsInTheAttachmentMenuOnlyWhenAvailable() {
        #expect(!ComposerAttachmentOption.available(gifsAvailable: true).contains(.poll))
        #expect(
            ComposerAttachmentOption.available(gifsAvailable: true, pollsAvailable: true) == [.files, .gifs, .poll])
        #expect(ComposerAttachmentOption.available(gifsAvailable: false, pollsAvailable: true) == [.files, .poll])
    }

    // MARK: View model

    @Test func createPollForwardsTheSubmissionToThisGroup() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let submission = PollDraft.Submission(
            question: "Lunch?",
            options: ["Tacos", "Ramen"],
            pollType: .multipleChoice,
            endsAt: 42
        )

        try await Self.model(runtime: runtime).createPoll(submission)

        #expect(
            runtime.createdPolls == [
                CreatedPoll(
                    groupIdHex: "group",
                    question: "Lunch?",
                    options: ["Tacos", "Ramen"],
                    pollType: .multipleChoice,
                    endsAt: 42
                )
            ])
    }

    @Test func aVoteShowsBeforeMDKConfirmsIt() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let gate = Self.armedGate()
        runtime.pollVoteGates = [gate]
        let model = Self.model(runtime: runtime)
        let poll = Self.poll(kind: .multipleChoice, votes: [1, 0, 0], participants: 1)

        let vote = Task { try await model.votePoll(option: "1", messageIdHex: "poll", poll: poll) }
        for _ in 0..<100 where !gate.didReach { await Task.yield() }

        #expect(gate.didReach)
        let shown = model.displayedPoll(poll, messageIdHex: "poll")
        #expect(shown.localSelection == ["1"])
        #expect(shown.options.map(\.votes) == [1, 1, 0])
        #expect(shown.participants == 2)

        gate.release()
        try await vote.value
        #expect(runtime.castPollVotes == [CastPollVote(groupIdHex: "group", pollEventId: "poll", optionIds: ["1"])])
    }

    @Test func aSecondClickBuildsOnTheInFlightSelection() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = Self.model(runtime: runtime)
        let poll = Self.poll(kind: .multipleChoice)

        try await model.votePoll(option: "0", messageIdHex: "poll", poll: poll)
        try await model.votePoll(option: "2", messageIdHex: "poll", poll: poll)

        #expect(runtime.castPollVotes.map(\.optionIds) == [["0"], ["0", "2"]])
    }

    /// The older vote fails first, then the newer one. Nothing MDK accepted is left, so the card
    /// must fall back to MDK's tally, not to the older selection that already failed.
    @Test func overlappingVotesThatBothFailLeaveNoOverlay() async throws {
        struct Refused: Error {}
        let runtime = FakeMarmotRuntime(accounts: [])
        let first = Self.armedGate()
        let second = Self.armedGate()
        runtime.pollVoteGates = [first, second]
        runtime.pollActionError = Refused()
        let model = Self.model(runtime: runtime)
        let poll = Self.poll()

        let older = Task { try await model.votePoll(option: "0", messageIdHex: "poll", poll: poll) }
        for _ in 0..<100 where !first.didReach { await Task.yield() }
        let newer = Task { try await model.votePoll(option: "1", messageIdHex: "poll", poll: poll) }
        for _ in 0..<100 where !second.didReach { await Task.yield() }
        #expect(model.pendingPollSelections["poll"] == ["1"])

        first.release()
        await #expect(throws: Refused.self) { try await older.value }
        #expect(model.pendingPollSelections["poll"] == ["1"])

        second.release()
        await #expect(throws: Refused.self) { try await newer.value }
        #expect(model.pendingPollSelections["poll"] == nil)
        #expect(model.displayedPoll(poll, messageIdHex: "poll") == poll)
    }

    /// The newer vote fails while the older one is still in flight: the older selection is what
    /// may still land, so it takes the overlay back.
    @Test func aNewerFailedVoteFallsBackToTheOlderInFlightOne() async throws {
        struct Refused: Error {}
        let runtime = FakeMarmotRuntime(accounts: [])
        let first = Self.armedGate()
        runtime.pollVoteGates = [first]
        let model = Self.model(runtime: runtime)
        let poll = Self.poll()

        let older = Task { try await model.votePoll(option: "0", messageIdHex: "poll", poll: poll) }
        for _ in 0..<100 where !first.didReach { await Task.yield() }
        runtime.pollActionError = Refused()
        await #expect(throws: Refused.self) {
            try await model.votePoll(option: "1", messageIdHex: "poll", poll: poll)
        }
        #expect(model.pendingPollSelections["poll"] == ["0"])

        runtime.pollActionError = nil
        first.release()
        try await older.value
        #expect(model.pendingPollSelections["poll"] == ["0"])
    }

    @Test func aFailedVoteRestoresTheTallyAndRethrows() async {
        struct Refused: Error {}
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.pollActionError = Refused()
        let model = Self.model(runtime: runtime)
        let poll = Self.poll(votes: [1, 0, 0], participants: 1, localSelection: ["0"])

        await #expect(throws: Refused.self) {
            try await model.votePoll(option: "1", messageIdHex: "poll", poll: poll)
        }

        #expect(model.pendingPollSelections["poll"] == nil)
        #expect(model.displayedPoll(poll, messageIdHex: "poll") == poll)
    }

    @Test func aClosedPollIgnoresClicks() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = Self.model(runtime: runtime)

        try await model.votePoll(option: "0", messageIdHex: "poll", poll: Self.poll(isOpen: false))
        try await model.votePoll(
            option: "0",
            messageIdHex: "poll",
            poll: Self.poll(endsAt: 10),
            now: Date(timeIntervalSince1970: 11)
        )

        #expect(runtime.castPollVotes.isEmpty)
    }

    @Test func theOverlayClearsOnceASnapshotProjectsTheSameSelection() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        var initial = ProjectionMigrationTests.conversationSnapshot(sequence: 1, title: "Planning")
        initial.messages = [ProjectionMigrationTests.conversationMessage(Self.pollRecord())]
        var confirmed = ProjectionMigrationTests.conversationSnapshot(sequence: 2, title: "Planning")
        confirmed.messages = [
            ProjectionMigrationTests.conversationMessage(
                Self.pollRecord(projection: Self.projection(localSelection: ["1"], votes: [1, 1])))
        ]
        runtime.conversationWindowInitialSnapshots["group"] = initial
        let gate = Self.armedGate()
        runtime.pollVoteGates = [gate]
        let model = Self.model(runtime: runtime)
        model.start(mode: .latest)
        for _ in 0..<100 where model.snapshot == nil { await Task.yield() }
        let poll = try #require(try Self.item(Self.pollRecord()).poll)

        let vote = Task { try await model.votePoll(option: "1", messageIdHex: "poll", poll: poll) }
        for _ in 0..<100 where !gate.didReach { await Task.yield() }
        #expect(model.pendingPollSelections["poll"] == ["1"])

        runtime.conversationWindowUpdates["group"] = [confirmed]
        model.start(mode: .latest)
        for _ in 0..<100 where model.pendingPollSelections["poll"] != nil { await Task.yield() }

        #expect(model.pendingPollSelections["poll"] == nil)
        gate.release()
        try await vote.value
        model.stop()
    }
}
