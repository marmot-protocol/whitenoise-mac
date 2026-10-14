import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// The reaction details popover: MDK's complete `messageReactions` read merged with the
/// conversation window's preview, and the model that owns the read. Ported from the iOS client's
/// `MessageReactionsModelTests`.
@MainActor
struct MessageReactionsTests: WorkspaceTestSupport {
    private typealias Presentation = MessageReactionDetailsPresentation

    private static let target = String(repeating: "a", count: 64)

    private static func account(_ byte: Int) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private static let me = account(0x11)

    private static func reaction(
        _ sender: Int, _ emoji: String, at reactedAt: UInt64, id: String? = nil
    ) -> TimelineUserReactionFfi {
        TimelineUserReactionFfi(
            reactionMessageIdHex: id ?? "\(sender)-\(emoji)-\(reactedAt)",
            targetMessageIdHex: target,
            sender: account(sender),
            emoji: emoji,
            reactedAt: reactedAt
        )
    }

    /// A conversation-window preview: `count` reactions, at most the listed senders named.
    private static func preview(
        _ emoji: String, count: Int, senders: [String], mine: Bool = false, id: String? = nil
    ) -> MessageReaction {
        MessageReaction(emoji: emoji, count: count, isOwn: mine, senders: senders, reactionMessageIdHex: id)
    }

    private static func users(_ details: MessageReactionDetails, _ emoji: String) -> [String]? {
        details.reactions.first { $0.emoji == emoji }?.senders
    }

    // MARK: Complete details

    @Test func everyReactorIsListedWithoutAProjectedPreview() {
        let reactions =
            (1...5).map { Self.reaction($0, "👍", at: UInt64($0)) } + [
                Self.reaction(1, "🔥", at: 6),
                Self.reaction(6, "🔥", at: 7),
            ]

        let details = Presentation.completeDetails(reactions, projected: nil, me: Self.me)

        #expect(details.reactions.map(\.emoji) == ["👍", "🔥"])
        #expect(details.reactions.map(\.count) == [5, 2])
        #expect(details.reactions[0].senders == (1...5).map(Self.account))
        #expect(details.totalCount == 7)
        #expect(!details.isTruncated)
    }

    @Test func theCompleteReadReplacesATruncatedPreview() {
        let projected = MessageReactionDetails(
            reactions: [Self.preview("👍", count: 4, senders: [Self.account(1), Self.account(2)], id: "window-id")],
            omittedKinds: 1,
            totalCount: 5
        )
        #expect(projected.isTruncated)
        let reactions = (1...4).map { Self.reaction($0, "👍", at: UInt64($0)) } + [Self.reaction(5, "🎉", at: 9)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(!details.isTruncated)
        // The window's emoji keep its order; one only the read knows follows.
        #expect(details.reactions.map(\.emoji) == ["👍", "🎉"])
        #expect(details.reactions.map(\.count) == [4, 1])
        #expect(details.reactions[0].reactionMessageIdHex == "window-id")
        #expect(details.reactions[1].reactionMessageIdHex == "5-🎉-9")
    }

    @Test func theWindowsEmojiOrderIsKeptSoAFilterDoesNotJumpUnderThePointer() {
        let projected = MessageReactionDetails(reactions: [
            Self.preview("🔥", count: 1, senders: [Self.account(2)]),
            Self.preview("👍", count: 1, senders: [Self.account(3)]),
        ])
        let reactions = [
            Self.reaction(2, "🔥", at: 1), Self.reaction(3, "👍", at: 2), Self.reaction(4, "👍", at: 3),
        ]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.reactions.map(\.emoji) == ["🔥", "👍"])
    }

    @Test func theEarliestReactionNamesAnEmojiOutsideThePreview() {
        let reactions = [
            Self.reaction(2, ":cat:", at: 20, id: "later"),
            Self.reaction(1, ":cat:", at: 10, id: "b-earliest"),
            Self.reaction(3, ":cat:", at: 10, id: "c-tie"),
        ]

        let details = Presentation.completeDetails(reactions, projected: nil, me: Self.me)

        #expect(details.reactions.first?.reactionMessageIdHex == "b-earliest")
    }

    // MARK: Own-reaction precedence

    @Test func aPendingUnreactHidesTheViewerBeforeMDKCatchesUp() {
        // The window already applies the local removal; the read is older.
        let projected = MessageReactionDetails(reactions: [Self.preview("👍", count: 1, senders: [Self.account(2)])])
        let reactions = [Self.reaction(0x11, "👍", at: 1), Self.reaction(2, "👍", at: 2)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.reactions.map(\.count) == [1])
        #expect(details.reactions[0].senders == [Self.account(2)])
        #expect(details.reactions[0].isOwn == false)
    }

    @Test func aPendingReactShowsTheViewerBeforeMDKCatchesUp() {
        let projected = MessageReactionDetails(reactions: [
            Self.preview("👍", count: 1, senders: [Self.account(2)]),
            Self.preview("🔥", count: 1, senders: [Self.me], mine: true),
        ])
        let reactions = [Self.reaction(2, "👍", at: 2)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(Self.users(details, "🔥") == [Self.me])
        #expect(details.reactions.first { $0.emoji == "🔥" }?.isOwn == true)
    }

    @Test func theWindowsViewerFlagWinsEvenWhenTheViewerIsOutsideThePreviewNames() {
        let projected = MessageReactionDetails(reactions: [
            Self.preview("👍", count: 3, senders: [Self.account(2), Self.account(3)], mine: true)
        ])
        let reactions = [
            Self.reaction(2, "👍", at: 1), Self.reaction(3, "👍", at: 2), Self.reaction(0x11, "👍", at: 3),
        ]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.reactions[0].senders == [Self.account(2), Self.account(3), Self.me])
        #expect(details.reactions[0].isOwn)
        #expect(details.reactions[0].canRemoveOwnReaction)
    }

    @Test func anEmojiTheWindowDroppedIsNotResurrectedByAnOlderRead() {
        // Removing the only 🔥 drops it from a window that lists every kind.
        let projected = MessageReactionDetails(reactions: [Self.preview("👍", count: 1, senders: [Self.account(2)])])
        let reactions = [
            Self.reaction(2, "👍", at: 1), Self.reaction(0x11, "🔥", at: 2), Self.reaction(3, "😂", at: 3),
        ]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.reactions.map(\.emoji) == ["👍"])
    }

    @Test func kindsTheWindowOmittedComeFromTheRead() {
        let projected = MessageReactionDetails(
            reactions: [Self.preview("👍", count: 1, senders: [Self.account(2)])],
            omittedKinds: 2,
            totalCount: 3
        )
        let reactions = [
            Self.reaction(2, "👍", at: 1), Self.reaction(0x11, "🔥", at: 2), Self.reaction(3, "😂", at: 3),
        ]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(Set(details.reactions.map(\.emoji)) == ["👍", "🔥", "😂"])
        #expect(details.reactions.first { $0.emoji == "🔥" }?.isOwn == true)
    }

    @Test func malformedAndDuplicateEntriesAreIgnored() {
        let reactions = [
            Self.reaction(2, "👍", at: 1),
            Self.reaction(2, "👍", at: 2),
            Self.reaction(3, "", at: 3),
            TimelineUserReactionFfi(
                reactionMessageIdHex: "x", targetMessageIdHex: Self.target, sender: "", emoji: "👍", reactedAt: 4),
        ]

        let details = Presentation.completeDetails(reactions, projected: nil, me: Self.me)

        #expect(details.reactions.map(\.emoji) == ["👍"])
        #expect(details.reactions[0].senders == [Self.account(2)])
    }

    // MARK: Popover content

    @Test func aCompletePreviewShowsImmediatelyWhileTheFirstReadRuns() {
        let projected = MessageReactionDetails(reactions: [
            Self.preview("👍", count: 2, senders: [Self.account(2), Self.account(3)])
        ])

        let content = Presentation.content(
            phase: .loading, hasLoaded: false, reactions: [], projected: projected, me: Self.me)

        #expect(content == .details(projected, refreshFailed: false))
    }

    @Test func aTruncatedOrMissingPreviewWaitsForTheRead() {
        let truncated = MessageReactionDetails(reactions: [
            Self.preview("👍", count: 3, senders: [Self.account(2), Self.account(3)])
        ])

        #expect(
            Presentation.content(phase: .loading, hasLoaded: false, reactions: [], projected: truncated, me: Self.me)
                == .loading)
        #expect(
            Presentation.content(phase: .idle, hasLoaded: false, reactions: [], projected: nil, me: Self.me)
                == .loading)
        #expect(
            Presentation.content(
                phase: .loading, hasLoaded: false, reactions: [], projected: MessageReactionDetails(reactions: []),
                me: Self.me) == .loading)
    }

    @Test func anEmptyReadIsAnEmptyStateNotAnError() {
        #expect(
            Presentation.content(phase: .loaded, hasLoaded: true, reactions: [], projected: nil, me: Self.me)
                == .empty)
    }

    @Test func aFailedFirstReadIsRetryableEvenWithACompletePreview() {
        let projected = MessageReactionDetails(reactions: [Self.preview("👍", count: 1, senders: [Self.account(2)])])

        #expect(
            Presentation.content(
                phase: .failed("Nope"), hasLoaded: false, reactions: [], projected: projected, me: Self.me)
                == .failed("Nope"))
        #expect(
            Presentation.content(phase: .failed("Nope"), hasLoaded: true, reactions: [], projected: nil, me: Self.me)
                == .failed("Nope"))
    }

    @Test func aFailedRefreshKeepsTheLastCompleteList() {
        let content = Presentation.content(
            phase: .failed("Nope"), hasLoaded: true, reactions: [Self.reaction(2, "👍", at: 1)], projected: nil,
            me: Self.me)

        guard case .details(let details, let refreshFailed) = content else {
            Issue.record("Expected details, got \(content)")
            return
        }
        #expect(details.reactions.map(\.emoji) == ["👍"])
        #expect(refreshFailed)
    }

    @Test func theClickedEmojiSurvivesLoadingAndClearsOnlyWhenTheListLacksIt() {
        #expect(Presentation.selection("🔥", availableEmojis: nil) == "🔥")
        #expect(Presentation.selection("🔥", availableEmojis: ["👍", "🔥"]) == "🔥")
        #expect(Presentation.selection("🔥", availableEmojis: ["👍"]) == nil)
        #expect(Presentation.selection(nil, availableEmojis: ["👍"]) == nil)
        #expect(Presentation.availableEmojis(in: .loading) == nil)
        #expect(Presentation.availableEmojis(in: .empty) == nil)
        let details = MessageReactionDetails(reactions: [Self.preview("👍", count: 1, senders: [Self.account(2)])])
        #expect(Presentation.availableEmojis(in: .details(details, refreshFailed: false)) == ["👍"])
    }

    // MARK: Loading

    private static func model(
        runtime: FakeMarmotRuntime,
        messageIdHex: String = target,
        loadingIndicatorDelay: Duration = MessageReactionDetailsPresentation.loadingIndicatorDelay
    ) -> MessageReactionsViewModel {
        MessageReactionsViewModel(messageIdHex: messageIdHex, viewerAccountIdHex: me) {
            try runtime.messageReactions(accountRef: "alice", groupIdHex: "group", messageIdHex: messageIdHex)
        }
    }

    @Test func loadsTheMessagesCompleteList() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.messageReactionsResults = [[Self.reaction(2, "👍", at: 1)]]
        let model = Self.model(runtime: runtime)

        await model.start()?.value

        #expect(
            runtime.messageReactionsRequests == [
                MessageReactionsRequest(accountRef: "alice", groupIdHex: "group", messageIdHex: Self.target)
            ])
        #expect(model.hasLoaded)
        #expect(model.phase == .loaded)
        #expect(model.reactorAccountIds == [Self.account(2)])
    }

    @Test func aRefreshKeepsTheOldListUntilItCompletes() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let gate = BlockingFfiGate()
        runtime.messageReactionsGates = [BlockingFfiGate(), gate]
        runtime.messageReactionsResults = [[Self.reaction(2, "👍", at: 1)], [Self.reaction(3, "🔥", at: 2)]]
        let model = Self.model(runtime: runtime)
        await model.start()?.value

        gate.isEnabled = true
        let refresh = try #require(model.refresh())
        await Self.waitUntil { gate.didReach }

        #expect(model.phase == .loading)
        #expect(model.reactions.map(\.emoji) == ["👍"])
        #expect(model.content(projected: nil) != .loading)

        gate.release()
        await refresh.value
        #expect(model.reactions.map(\.emoji) == ["🔥"])
    }

    @Test func aRefreshAskedForMidReadRunsAfterIt() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let gate = BlockingFfiGate()
        gate.isEnabled = true
        runtime.messageReactionsGates = [gate]
        runtime.messageReactionsResults = [[Self.reaction(2, "👍", at: 1)], [Self.reaction(3, "🔥", at: 2)]]
        let model = Self.model(runtime: runtime)

        let first = try #require(model.start())
        await Self.waitUntil { gate.didReach }
        // Reads never overlap: the refresh waits for the first read instead of racing it.
        #expect(model.refresh() == nil)
        #expect(runtime.messageReactionsRequests.count == 1)

        gate.release()
        await first.value
        await Self.waitUntil { runtime.messageReactionsRequests.count == 2 && model.phase == .loaded }

        #expect(model.reactions.map(\.emoji) == ["🔥"])
    }

    @Test func aReadFinishingAfterThePopoverClosedPublishesNothing() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let gate = BlockingFfiGate()
        gate.isEnabled = true
        runtime.messageReactionsGates = [gate]
        runtime.messageReactionsResults = [[Self.reaction(2, "👍", at: 1)]]
        let model = Self.model(runtime: runtime)

        let read = try #require(model.start())
        await Self.waitUntil { gate.didReach }
        model.cancel()
        gate.release()
        await read.value

        #expect(!model.hasLoaded)
        #expect(model.reactions.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func aFailedReadSurfacesItsMessageKeepsTheLastListAndRetryRepeatsIt() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.messageReactionsResults = [[Self.reaction(2, "👍", at: 1)], [Self.reaction(3, "🔥", at: 2)]]
        let model = MessageReactionsViewModel(
            messageIdHex: Self.target,
            viewerAccountIdHex: Self.me,
            errorMessage: { _ in "Nope" },
            load: {
                try runtime.messageReactions(accountRef: "alice", groupIdHex: "group", messageIdHex: Self.target)
            }
        )
        #expect(model.retry() == nil)
        await model.start()?.value

        runtime.messageReactionsError = MessageReactionsReadFailure()
        await model.refresh()?.value
        #expect(model.phase == .failed("Nope"))
        #expect(model.reactions.map(\.emoji) == ["👍"])
        guard case .details(_, refreshFailed: true) = model.content(projected: nil) else {
            Issue.record("Expected the last list with a refresh failure, got \(model.content(projected: nil))")
            return
        }

        runtime.messageReactionsError = nil
        try await #require(model.retry()).value
        #expect(model.phase == .loaded)
        #expect(model.reactions.map(\.emoji) == ["🔥"])
    }

    @Test func theSpinnerAppearsOnlyOnceTheFirstReadIsSlow() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let gate = BlockingFfiGate()
        gate.isEnabled = true
        runtime.messageReactionsGates = [gate]
        let model = MessageReactionsViewModel(
            messageIdHex: Self.target, viewerAccountIdHex: Self.me, loadingIndicatorDelay: .milliseconds(20)
        ) {
            try runtime.messageReactions(accountRef: "alice", groupIdHex: "group", messageIdHex: Self.target)
        }

        let read = try #require(model.start())
        #expect(!model.showsLoadingIndicator)
        await Self.waitUntil { model.showsLoadingIndicator }
        #expect(model.showsLoadingIndicator)

        gate.release()
        await read.value
        #expect(!model.showsLoadingIndicator)

        // A refresh over a loaded list never shows the spinner again.
        await model.refresh()?.value
        try await Task.sleep(for: .milliseconds(60))
        #expect(!model.showsLoadingIndicator)
    }

    // MARK: Conversation ownership

    private static func conversation(runtime: FakeMarmotRuntime) async -> ConversationViewModel {
        runtime.conversationWindowInitialSnapshots["group"] = ProjectionMigrationTests.conversationSnapshot(
            sequence: 1, title: "Planning")
        let conversation = ConversationViewModel(
            account: AccountItem.samples[0], groupIdHex: "group", runtime: runtime)
        conversation.start(mode: .latest)
        await yieldUntil { conversation.snapshot != nil }
        return conversation
    }

    @Test func aStaleReadAfterAMessageSwitchNeverLands() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let conversation = await Self.conversation(runtime: runtime)
        let gate = BlockingFfiGate()
        gate.isEnabled = true
        runtime.messageReactionsGates = [gate]
        // The ungated second read takes the first queued list; the held read answers with what is
        // left once released, the 👍 list, which belongs to the message no longer shown.
        runtime.messageReactionsResults = [[Self.reaction(3, "🔥", at: 2)], [Self.reaction(2, "👍", at: 1)]]

        conversation.showReactionDetails(messageIdHex: "first")
        let first = try #require(conversation.reactionDetails)
        await Self.waitUntil { gate.didReach }

        conversation.showReactionDetails(messageIdHex: "second")
        let second = try #require(conversation.reactionDetails)
        #expect(second !== first)
        await Self.waitUntil { second.hasLoaded }
        gate.release()
        await Self.waitUntil { runtime.messageReactionsRequests.count == 2 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(!first.hasLoaded)
        #expect(first.reactions.isEmpty)
        #expect(second.messageIdHex == "second")
        #expect(second.reactions.map(\.emoji) == ["🔥"])
        #expect(runtime.messageReactionsRequests.map(\.messageIdHex) == ["first", "second"])
        #expect(runtime.messageReactionsRequests.allSatisfy { $0.accountRef == AccountItem.samples[0].accountRef })
        conversation.stop()
    }

    @Test func eachInstalledRevisionReReadsTheOpenPopover() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let conversation = await Self.conversation(runtime: runtime)
        runtime.messageReactionsResults = [[Self.reaction(2, "👍", at: 1)], [Self.reaction(3, "🔥", at: 2)]]
        conversation.showReactionDetails(messageIdHex: Self.target)
        let details = try #require(conversation.reactionDetails)
        await Self.waitUntil { details.hasLoaded }

        runtime.conversationWindowUpdates["group"] = [
            ProjectionMigrationTests.conversationSnapshot(sequence: 2, title: "Planning")
        ]
        conversation.start(mode: .latest)
        await Self.waitUntil { details.reactions.map(\.emoji) == ["🔥"] }

        #expect(details.reactions.map(\.emoji) == ["🔥"])
        #expect(runtime.messageReactionsRequests.count == 2)
        conversation.stop()
    }

    @Test func closingAnotherMessagesPopoverLeavesTheOpenOneAlone() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let conversation = await Self.conversation(runtime: runtime)

        conversation.showReactionDetails(messageIdHex: "second")
        conversation.dismissReactionDetails(messageIdHex: "first")
        #expect(conversation.reactionDetails?.messageIdHex == "second")

        conversation.dismissReactionDetails(messageIdHex: "second")
        #expect(conversation.reactionDetails == nil)
        conversation.stop()
    }

    /// The conversation model lives for one account's open conversation, so stopping it (an
    /// account switch or a closed chat) has to take the open popover's read with it.
    @Test func stoppingTheConversationDiscardsTheReadInFlight() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let conversation = await Self.conversation(runtime: runtime)
        let gate = BlockingFfiGate()
        gate.isEnabled = true
        runtime.messageReactionsGates = [gate]
        runtime.messageReactionsResults = [[Self.reaction(2, "👍", at: 1)]]

        conversation.showReactionDetails(messageIdHex: Self.target)
        let details = try #require(conversation.reactionDetails)
        await Self.waitUntil { gate.didReach }
        conversation.stop()
        gate.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(conversation.reactionDetails == nil)
        #expect(!details.hasLoaded)
    }
}

private struct MessageReactionsReadFailure: Error {}
