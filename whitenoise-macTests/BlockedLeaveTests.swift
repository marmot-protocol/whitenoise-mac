import MarmotKit
import Testing

@testable import whitenoise_mac

/// MarmotKit 0.15 blocked leave: a pending leave MDK cannot finish because this account became the
/// group's only admin. Cancel clears it on this device, and the surface re-reads whatever happens.
@MainActor
struct BlockedLeaveTests {
    @Test func onlyAPendingLeaveCanBeBlocked() {
        #expect(BlockedLeavePresentation.isBlocked(leaveRequestPending: true, leaveBlocked: true))
        #expect(!BlockedLeavePresentation.isBlocked(leaveRequestPending: false, leaveBlocked: true))
        #expect(!BlockedLeavePresentation.isBlocked(leaveRequestPending: true, leaveBlocked: false))
    }

    @Test func cancellingRejoinsAndRereads() async {
        var refreshes = 0
        let outcome = await BlockedLeaveCancellation.perform(cancelLeave: {}, refresh: { refreshes += 1 })
        #expect(outcome == .rejoined)
        #expect(refreshes == 1)
        #expect(BlockedLeaveCancellation.failureMessage(for: outcome) == nil)
    }

    @Test func aLeaveThatStoppedBeingBlockedSaysSoAndRereads() async {
        var refreshes = 0
        let outcome = await BlockedLeaveCancellation.perform(
            cancelLeave: { throw MarmotKitError.LeaveNotBlocked(groupIdHex: "group") },
            refresh: { refreshes += 1 })
        #expect(outcome == .noLongerBlocked)
        #expect(refreshes == 1)
        #expect(
            BlockedLeaveCancellation.failureMessage(for: outcome)
                == L10n.string("This leave is no longer blocked."))
    }

    @Test func anyOtherFailureShowsMappedCopyAndRereads() async {
        var refreshes = 0
        let error = MarmotKitError.StorageBusy(details: "database is locked")
        let outcome = await BlockedLeaveCancellation.perform(
            cancelLeave: { throw error }, refresh: { refreshes += 1 })
        #expect(outcome == .failed(UserFacingError.message(for: error)))
        #expect(refreshes == 1)
    }

    @Test func theConversationCancelsThroughTheRuntimeForItsGroup() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let conversation = ConversationViewModel(
            account: AccountItem.samples[0], groupIdHex: "group", runtime: runtime)
        var refreshed = false

        await conversation.cancelBlockedLeave(refresh: { refreshed = true })

        #expect(runtime.cancelLeaveGroupIds == ["group"])
        #expect(refreshed)
        #expect(conversation.cancelLeaveFailure == nil)
        #expect(!conversation.isCancellingLeave)
    }

    @Test func aFailedCancelIsShownOnTheConversation() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.cancelLeaveError = MarmotKitError.LeaveNotBlocked(groupIdHex: "group")
        let conversation = ConversationViewModel(
            account: AccountItem.samples[0], groupIdHex: "group", runtime: runtime)

        await conversation.cancelBlockedLeave()

        #expect(conversation.cancelLeaveFailure == L10n.string("This leave is no longer blocked."))
    }
}
