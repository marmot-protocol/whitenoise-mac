import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
struct ApplicationBadgeTests {
    private static func total(
        unread: UInt64 = 0,
        conversations: UInt64 = 0,
        attentionOnly: UInt64 = 0
    ) -> AccountAttentionTotalFfi {
        AccountAttentionTotalFfi(
            unreadCount: unread,
            unreadMentionCount: 0,
            unreadConversations: conversations,
            attentionOnlyConversations: attentionOnly
        )
    }

    private static func snapshot(sequence: UInt64, _ entries: [(String, AccountAttentionStateFfi)])
        -> AccountAttentionSnapshotFfi
    {
        AccountAttentionSnapshotFfi(
            subscriptionGeneration: "attention",
            sequence: sequence,
            accounts: entries.map { AccountAttentionEntryFfi(accountIdHex: $0.0, state: $0.1) }
        )
    }

    /// The model publishes asynchronously off a subscription task; wait on wall-clock time,
    /// since yields alone cannot advance the fake's async iterator reliably under load.
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Projection

    @Test func projectionSumsUnreadMessagesAndAttentionOnlyConversationsAcrossAccounts() {
        let count = ApplicationBadgeCountProjection.count(for: [
            Self.total(unread: 4, conversations: 2, attentionOnly: 1),
            Self.total(unread: 2, conversations: 1),
        ])

        #expect(count == 7)
    }

    @Test func projectionCountsAnUnreadConversationWithoutMessagesAsOne() {
        // A conversation marked unread by hand carries no unread messages.
        #expect(ApplicationBadgeCountProjection.contribution(for: Self.total(conversations: 1)) == 1)
        #expect(ApplicationBadgeCountProjection.contribution(for: Self.total()) == 0)
    }

    @Test func projectionSaturatesInsteadOfOverflowing() {
        let count = ApplicationBadgeCountProjection.count(for: [
            Self.total(unread: .max, attentionOnly: 1),
            Self.total(unread: .max),
        ])

        #expect(count == Int.max)
    }

    // MARK: - Dock controller

    @Test func dockLabelIsEmptyAtZeroAndUngroupedAboveIt() {
        #expect(DockBadgeController.label(forCount: 0) == nil)
        #expect(DockBadgeController.label(forCount: 3) == "3")
        #expect(DockBadgeController.label(forCount: 1234)?.count == 4)
    }

    @Test func dockControllerKeepsTheBadgeForAnUnknownCountAndWritesOnlyChanges() {
        var writes: [String?] = []
        let controller = DockBadgeController { writes.append($0) }

        controller.apply(count: nil)
        controller.apply(count: 5)
        controller.apply(count: 5)
        controller.apply(count: nil)
        controller.apply(count: 0)

        #expect(writes == ["5", nil])
    }

    @Test func dockControllerClearsTheBadgeWhenTheActiveAccountSignedOut() {
        var writes: [String?] = []
        let controller = DockBadgeController { writes.append($0) }
        controller.apply(count: 5)

        // The replacement scope has no ready total yet.
        controller.activeAccountDidChange(from: "signed-out", signedInAccountIds: ["remaining"])
        controller.apply(count: nil)

        #expect(writes == ["5", nil])
    }

    @Test func dockControllerKeepsTheBadgeAcrossAnOrdinaryAccountSwitch() {
        var writes: [String?] = []
        let controller = DockBadgeController { writes.append($0) }
        controller.apply(count: 5)

        controller.activeAccountDidChange(from: "previous", signedInAccountIds: ["previous", "next"])
        controller.activeAccountDidChange(from: nil, signedInAccountIds: ["next"])
        controller.apply(count: nil)

        #expect(writes == ["5"])
    }

    // MARK: - Attention model

    @Test func attentionModelPublishesTheTotalAcrossEveryAccount() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountAttentionInitialSnapshot = Self.snapshot(
            sequence: 1,
            [
                ("active", .ready(total: Self.total(unread: 3, conversations: 1))),
                ("other", .ready(total: Self.total(unread: 1, conversations: 1, attentionOnly: 2))),
            ]
        )
        let model = AccountAttentionViewModel(runtime: runtime)
        #expect(model.applicationBadgeCount == nil)

        model.start()
        await Self.waitUntil { model.applicationBadgeCount != nil }

        #expect(model.applicationBadgeCount == 6)
        model.stop()
    }

    @Test func attentionModelWithholdsTheTotalWhileAnAccountHasNeverBeenReady() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountAttentionInitialSnapshot = Self.snapshot(
            sequence: 1,
            [
                ("ready", .ready(total: Self.total(unread: 3, conversations: 1))),
                ("preparing", .unavailable(reason: .preparing)),
            ]
        )
        let model = AccountAttentionViewModel(runtime: runtime)

        model.start()
        await Self.waitUntil { model.valuesByAccountId.count == 2 }

        #expect(model.applicationBadgeCount == nil)
        model.stop()
    }

    @Test func attentionModelKeepsCountingAnAccountThatTurnsUnavailable() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountAttentionInitialSnapshot = Self.snapshot(
            sequence: 1,
            [
                ("first", .ready(total: Self.total(unread: 3, conversations: 1))),
                ("second", .ready(total: Self.total(unread: 2, conversations: 1))),
            ]
        )
        runtime.accountAttentionUpdates = [
            Self.snapshot(
                sequence: 2,
                [
                    ("first", .ready(total: Self.total(unread: 1, conversations: 1))),
                    ("second", .unavailable(reason: .preparing)),
                ]
            )
        ]
        let model = AccountAttentionViewModel(runtime: runtime)

        model.start()
        await Self.waitUntil { model.applicationBadgeCount == 3 }

        #expect(model.applicationBadgeCount == 3)
        model.stop()
    }

    @Test func attentionModelClearsTheTotalWhenNothingIsUnread() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountAttentionInitialSnapshot = Self.snapshot(
            sequence: 1,
            [("account", .ready(total: Self.total()))]
        )
        let model = AccountAttentionViewModel(runtime: runtime)

        model.start()
        await Self.waitUntil { model.applicationBadgeCount != nil }

        #expect(model.applicationBadgeCount == 0)
        model.stop()
    }
}
