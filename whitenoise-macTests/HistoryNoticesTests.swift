import MarmotKit
import Testing

@testable import whitenoise_mac

/// MDK 0.11.0's "history may be incomplete" notices: a parked loss fences the account's
/// transport cursor until the user dismisses it, so the app must list, re-read and dismiss them.
@MainActor
struct HistoryNoticesTests: WorkspaceTestSupport {
    private static let account = AccountItem.samples[0]
    private static let accountNotice = HistoryNoticeFfi(
        noticeId: String(repeating: "a", count: 48),
        cause: .deliveryLoss,
        groupIdHex: nil,
        parkedAtMs: 1_700_000_000_000
    )
    private static let groupNotice = HistoryNoticeFfi(
        noticeId: String(repeating: "b", count: 48),
        cause: .epochGap,
        groupIdHex: "group-a",
        parkedAtMs: nil
    )

    private func makeModel(_ runtime: FakeMarmotRuntime) -> HistoryNoticesViewModel {
        HistoryNoticesViewModel(
            accountRef: Self.account.accountRef,
            accountIdHex: Self.account.accountIdHex,
            runtime: runtime
        )
    }

    @Test func accountNoticesExcludeGroupScopedOnes() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.historyNoticeRecords = [Self.accountNotice, Self.groupNotice]
        let model = makeModel(runtime)

        await model.refresh()

        #expect(model.accountNotices.map(\.noticeId) == [Self.accountNotice.noticeId])
        #expect(model.notices(forGroup: "group-a").map(\.noticeId) == [Self.groupNotice.noticeId])
        #expect(model.notices(forGroup: "group-b").isEmpty)
    }

    @Test func dismissingRoutesTheIdToTheCoreAndReReads() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.historyNoticeRecords = [Self.accountNotice]
        let model = makeModel(runtime)
        await model.refresh()

        let dismissed = await model.dismiss([Self.accountNotice.noticeId])

        #expect(dismissed)
        #expect(runtime.dismissedHistoryNoticeIds == [Self.accountNotice.noticeId])
        #expect(runtime.historyNoticesCallCount == 2)
        #expect(model.notices.isEmpty)
        #expect(model.dismissing.isEmpty)
    }

    @Test func aStaleDismissalReReadsTheCurrentList() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.historyNoticeRecords = [Self.accountNotice]
        let model = makeModel(runtime)
        await model.refresh()
        // Recovery re-armed: the occurrence the user sees now has a new id.
        let rearmed = HistoryNoticeFfi(
            noticeId: String(repeating: "c", count: 48),
            cause: .deliveryLoss,
            groupIdHex: nil,
            parkedAtMs: nil
        )
        runtime.historyNoticeRecords = [rearmed]

        let dismissed = await model.dismiss([Self.accountNotice.noticeId])

        #expect(!dismissed)
        #expect(model.notices == [rearmed])
    }

    @Test func aFailedReadKeepsTheShownNotices() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.historyNoticeRecords = [Self.accountNotice]
        let model = makeModel(runtime)
        await model.refresh()
        runtime.historyNoticesError = FakeMarmotRuntimeError.unused

        await model.refresh()

        #expect(model.notices == [Self.accountNotice])
    }

    @Test func aChangeEventForThisAccountReReads() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = makeModel(runtime)
        model.start()
        defer { model.stop() }
        await Self.waitUntil { runtime.historyNoticesCallCount == 1 }
        #expect(model.notices.isEmpty)

        runtime.historyNoticeRecords = [Self.accountNotice]
        runtime.eventHub.emit(
            .historyNoticesChanged(accountIdHex: Self.account.accountIdHex.uppercased(), accountLabel: "jeff")
        )
        await Self.waitUntil { model.notices == [Self.accountNotice] }

        #expect(model.notices == [Self.accountNotice])
    }

    @Test func eventsForOtherAccountsAndOtherKindsAreIgnored() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = makeModel(runtime)
        model.start()
        defer { model.stop() }
        await Self.waitUntil { runtime.historyNoticesCallCount == 1 }

        runtime.eventHub.emit(
            .historyNoticesChanged(accountIdHex: AccountItem.samples[1].accountIdHex, accountLabel: "lab")
        )
        runtime.eventHub.emit(
            .agentStreamActivity(accountIdHex: Self.account.accountIdHex, accountLabel: "jeff")
        )
        // A matching event queued after the ignored ones proves they were consumed and skipped.
        runtime.eventHub.emit(
            .historyNoticesChanged(accountIdHex: Self.account.accountIdHex, accountLabel: "jeff")
        )
        await Self.waitUntil { runtime.historyNoticesCallCount == 2 }

        #expect(runtime.historyNoticesCallCount == 2)
    }

    @Test func stoppingEndsTheEventSubscription() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = makeModel(runtime)
        model.start()
        #expect(runtime.eventHub.subscriberCount == 1)

        model.stop()
        await Self.waitUntil { runtime.eventHub.subscriberCount == 0 }

        #expect(runtime.eventHub.subscriberCount == 0)
    }

    @Test func switchingAccountsDiscardsTheOldNotices() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.historyNoticeRecords = [Self.accountNotice]
        let session = SessionState()
        await session.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: true)
        let first = try #require(session.accountScope?.historyNotices)
        await first.refresh()
        #expect(first.accountNotices.count == 1)

        runtime.historyNoticeRecords = []
        await session.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: true)
        let second = try #require(session.accountScope?.historyNotices)

        #expect(second !== first)
        #expect(second.notices.isEmpty)
        await session.deactivate()
    }

    @Test func groupNoticeAppearsOnlyInItsGroupAndDismissesThere() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.historyNoticeRecords = [Self.accountNotice, Self.groupNotice]
        runtime.groupRecoveryStatuses["group-a"] = GroupRecoveryStatusFfi(
            groupIdHex: "group-a",
            automaticRecoveryFailed: false,
            pendingReinvites: 0,
            failedReinvites: 0,
            rejoinInvitations: [],
            historyMayBeIncomplete: true,
            historyNoticeIds: [Self.groupNotice.noticeId]
        )
        let notices = makeModel(runtime)
        await notices.refresh()
        let groupA = GroupSafetyViewModel(
            accountRef: Self.account.accountRef, groupIdHex: "group-a", runtime: runtime, historyNotices: notices
        )
        let groupB = GroupSafetyViewModel(
            accountRef: Self.account.accountRef, groupIdHex: "group-b", runtime: runtime, historyNotices: notices
        )
        await groupA.load(canModerate: false)
        await groupB.load(canModerate: false)

        #expect(groupA.historyNoticeIds == [Self.groupNotice.noticeId])
        #expect(groupA.historyNoticeMessage == HistoryNoticePresentation.message(for: .epochGap))
        #expect(groupB.historyNoticeIds.isEmpty)

        runtime.groupRecoveryStatuses["group-a"]?.historyMayBeIncomplete = false
        runtime.groupRecoveryStatuses["group-a"]?.historyNoticeIds = []
        await groupA.dismissHistoryNotice()

        #expect(runtime.dismissedHistoryNoticeIds == [Self.groupNotice.noticeId])
        #expect(groupA.historyNoticeIds.isEmpty)
        #expect(notices.accountNotices.map(\.noticeId) == [Self.accountNotice.noticeId])
    }

    @Test func aFlaggedGroupWithoutIdsShowsNothingToDismiss() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.groupRecoveryStatuses["group-a"] = GroupRecoveryStatusFfi(
            groupIdHex: "group-a",
            automaticRecoveryFailed: false,
            pendingReinvites: 0,
            failedReinvites: 0,
            rejoinInvitations: [],
            historyMayBeIncomplete: true,
            historyNoticeIds: []
        )
        let model = GroupSafetyViewModel(accountRef: Self.account.accountRef, groupIdHex: "group-a", runtime: runtime)
        await model.load(canModerate: false)

        #expect(model.historyNoticeIds.isEmpty)
    }

    @Test(arguments: [
        HistoryNoticeCauseFfi.deliveryLoss, .notificationLoss, .epochGap, .incrementalHistory,
        .explicitRepair, .knownEvent, .maintenanceBoundary,
    ])
    func everyCauseHasLocalizedWording(_ cause: HistoryNoticeCauseFfi) {
        let message = HistoryNoticePresentation.message(for: cause)
        #expect(!message.isEmpty)
    }

    @Test func groupWordingFallsBackToAnEpochGapForAnUnlistedId() {
        let message = HistoryNoticePresentation.groupMessage(noticeIds: ["unlisted"], notices: [Self.accountNotice])
        #expect(message == HistoryNoticePresentation.message(for: .epochGap))
    }
}
