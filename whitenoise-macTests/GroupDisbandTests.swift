//
//  GroupDisbandTests.swift
//  whitenoise-macTests
//
//  Ending a group for everyone: the lifecycle policy every surface reads, and the End Group action
//  driven against the fake core — enabling a group that predates disbanding, advisory consent
//  across both commits, the refusals the core can return, and dismissing a failed request.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
struct GroupDisbandTests {
    private static let groupIdHex = "group"

    // MARK: - Lifecycle policy

    @Test func lifecycleFoldsTheCoreFlagsIntoOneAnswer() {
        #expect(GroupLifecycle(lifecycleState: .stable, disbanding: false) == .active)
        #expect(GroupLifecycle(lifecycleState: .stable, disbanding: true) == .ending)
        // Terminal outranks a stale `disbanding` flag.
        #expect(GroupLifecycle(lifecycleState: .disbanded, disbanding: true) == .ended)
        #expect(GroupLifecycle.active.allowsMessaging)
        #expect(!GroupLifecycle.ending.allowsMessaging)
        #expect(!GroupLifecycle.ended.allowsMessaging)
        #expect(GroupLifecycle.active.composerNotice == nil)
        #expect(GroupLifecycle.ending.composerNotice == L10n.string("This group is ending. New messages are disabled."))
        #expect(GroupLifecycle.ended.composerNotice == L10n.string("This group has ended. New messages are disabled."))
    }

    @Test func statusReportsEndedThenFailureThenPending() {
        let failed = DisbandRequestFfi.failed(requestedAtMs: 1, reason: .noLongerAdmin)
        let pending = DisbandRequestFfi.pending(requestedAtMs: 1)

        #expect(GroupDisbandState(lifecycle: .ended, request: failed).status == .disbanded)
        #expect(GroupDisbandState(lifecycle: .ending, request: failed).status == .failed(.noLongerAdmin))
        #expect(GroupDisbandState(lifecycle: .ending, request: pending).status == .pending)
        #expect(GroupDisbandState.inactive.status == .none)
    }

    /// The details record and the management state can each learn of a request first. A failure on
    /// either is what the user has to dismiss, so it wins over a pending request on the other.
    @Test func aFailureOnEitherRecordWinsOverAPendingRequest() {
        var group = messageGroup()
        group.disbandRequest = .failed(requestedAtMs: 2, reason: .noLongerMember)
        let state = Self.managementState(disbanding: true, disbandRequest: .pending(requestedAtMs: 1))

        let disband = GroupDisbandState(managementState: state, group: group)

        #expect(disband.lifecycle == .ending)
        #expect(disband.status == .failed(.noLongerMember))
    }

    @Test func aDisbandedGroupRecordEndsTheGroupEvenBeforeTheStateCatchesUp() {
        var group = messageGroup()
        group.disbanded = true

        let disband = GroupDisbandState(managementState: Self.managementState(canDisband: true), group: group)

        #expect(disband.lifecycle == .ended)
        #expect(!disband.canEndGroup)
        #expect(!disband.showsEndGroup)
    }

    @Test func onlyAnAdminOfAnActiveGroupIsOfferedEndGroup() {
        #expect(GroupDisbandState(isSelfAdmin: true, canDisband: true).canEndGroup)
        // A group that predates disbanding is ended through the enabling commit.
        #expect(GroupDisbandState(isSelfAdmin: true, canEnableDisbanding: true).canEndGroup)
        #expect(!GroupDisbandState(isSelfAdmin: false, canDisband: true).showsEndGroup)
        #expect(!GroupDisbandState(lifecycle: .ending, isSelfAdmin: true, canDisband: true).showsEndGroup)
        // A failed request is dismissed before another is offered.
        #expect(
            !GroupDisbandState(
                isSelfAdmin: true, canDisband: true,
                request: .failed(requestedAtMs: 1, reason: .noLongerAdmin)
            ).showsEndGroup)
    }

    /// Members on old clients hold the action back, but the row stays so the footer can say why.
    @Test func outdatedMembersKeepTheRowAndExplainTheBlock() {
        let blocked = GroupDisbandState(isSelfAdmin: true, blockerCount: 2)

        #expect(blocked.showsEndGroup)
        #expect(!blocked.canEndGroup)
        #expect(blocked.blockerMessage == GroupDisbandPresentation.updateRequiredMessage(count: 2))
        #expect(GroupDisbandState(isSelfAdmin: true, canDisband: true, blockerCount: 2).blockerMessage == nil)
        #expect(GroupDisbandState(isSelfAdmin: false, blockerCount: 2).blockerMessage == nil)
    }

    /// A single outdated member is the common case, so the count needs real plural variants rather
    /// than a `%lld` dropped into plural wording.
    @Test func theUpdateRequiredMessageAgreesWithTheCount() {
        let key = "%lld members must update White Noise before you can end this group."
        let english = Locale(identifier: "en")
        let russian = Locale(identifier: "ru")

        #expect(
            L10n.plural(key, Int64(1), locale: english)
                == "1 member must update White Noise before you can end this group.")
        #expect(
            L10n.plural(key, Int64(3), locale: english)
                == "3 members must update White Noise before you can end this group.")
        #expect(L10n.plural(key, Int64(1), locale: russian).hasPrefix("1 участник должен"))
        #expect(L10n.plural(key, Int64(2), locale: russian).hasPrefix("2 участника должны"))
        #expect(L10n.plural(key, Int64(5), locale: russian).hasPrefix("5 участников должны"))
    }

    // MARK: - Destructive actions and row status

    /// Once the group is over nobody is left to strand, so the local delete is the way to close it
    /// out — even for an account the core still lists as a member.
    @Test func anEndedGroupOffersTheLocalDelete() {
        #expect(
            ChatDestructiveActions.action(membership: .member, leaveRequestPending: false, lifecycle: .ended)
                == .deleteLocally)
        #expect(
            ChatDestructiveActions.action(membership: .removed, leaveRequestPending: false, lifecycle: .ended)
                == .deleteLocally)
    }

    /// Mid-disband the core refuses a leave, and dropping the copy would abandon the final commit.
    @Test func anEndingGroupOffersNothingToAMember() {
        #expect(
            ChatDestructiveActions.action(membership: .member, leaveRequestPending: false, lifecycle: .ending)
                == nil)
        #expect(
            ChatDestructiveActions.action(membership: .left, leaveRequestPending: true, lifecycle: .ending)
                == .deleteLocally)
    }

    @Test func theGroupsLifecycleOutranksTheAccountsMembershipOnTheRow() {
        #expect(
            ChatRowStatus.status(
                membership: .removed, leaveRequestPending: false, pendingConfirmation: false, lifecycle: .ended)
                == .groupLifecycle(.ended))
        #expect(
            ChatRowStatus.status(
                membership: .member, leaveRequestPending: true, pendingConfirmation: false, lifecycle: .ending)
                == .groupLifecycle(.ending))
        #expect(
            ChatRowStatus.status(membership: .member, leaveRequestPending: true, pendingConfirmation: false)
                == .leaving)
    }

    @Test func anEndingGroupClosesTheComposer() {
        let active = ChatItem(
            id: Self.groupIdHex, title: "Room", subtitle: "", preview: "", updatedAt: nil,
            avatarSeed: Self.groupIdHex, pictureURL: nil, unreadCount: 0)
        let ending = ChatItem(
            id: Self.groupIdHex, title: "Room", subtitle: "", preview: "", updatedAt: nil,
            avatarSeed: Self.groupIdHex, pictureURL: nil, unreadCount: 0, lifecycle: .ending)

        #expect(active.canUseComposer)
        #expect(!ending.canUseComposer)
    }

    @Test func aChatListRowCarriesTheGroupsLifecycle() {
        let row = ChatListRowFfi(
            groupIdHex: Self.groupIdHex, archived: false, pendingConfirmation: false, title: "Room",
            groupName: "Room", avatarUrl: nil, avatar: nil, lastMessage: nil, unreadCount: 0, hasUnread: false,
            unreadMentionCount: 0, unreadMention: false, firstUnreadMessageIdHex: nil, lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil, updatedAt: 0, selfMembership: .member, disbanding: true)

        let chat = ChatItem(row: row, activeAccountIdHex: desktopAccount().accountIdHex)

        #expect(chat.lifecycle == .ending)
        #expect(ChatDestructiveActions.action(for: chat) == nil)
    }

    // MARK: - Ending a group

    @Test func endingAGroupThatPredatesDisbandingEnablesItFirst() async throws {
        let (runtime, model) = Self.disbandableGroup(Self.managementState(canEnableDisbanding: true))

        let accepted = await model.endGroup(
            GroupDisbandState(managementState: Self.managementState(canEnableDisbanding: true)), advisory: nil)

        #expect(accepted)
        #expect(runtime.groupMutationOrder == ["enableDisbanding", "disband"])
        #expect(model.alert == nil)
        #expect(!model.isEnding)
        let state = try await runtime.groupManagementState(
            accountRef: desktopAccount().accountIdHex, groupIdHex: Self.groupIdHex)
        #expect(GroupDisbandState(managementState: state).status == .pending)
    }

    @Test func anEnabledGroupIsDisbandedInOneCommit() async {
        let state = Self.managementState(canDisband: true)
        let (runtime, model) = Self.disbandableGroup(state)

        #expect(await model.endGroup(GroupDisbandState(managementState: state), advisory: nil))
        #expect(runtime.groupMutationOrder == ["disband"])
    }

    /// The enabling commit can land while the disband stays blocked — members on old clients turn
    /// up only then. The user is told why, and nothing more is attempted.
    @Test func aBlockerFoundWhileEnablingStopsBeforeTheDisband() async {
        let state = Self.managementState(canEnableDisbanding: true)
        let (runtime, model) = Self.disbandableGroup(state)
        runtime.canDisbandAfterEnabling = false

        let accepted = await model.endGroup(GroupDisbandState(managementState: state), advisory: nil)

        #expect(!accepted)
        #expect(runtime.disbandGroupCallCount == 0)
        #expect(model.alert?.title == L10n.string("Couldn't end group"))
        #expect(model.alert?.message == L10n.string("This group can't be ended right now."))
    }

    @Test func aGroupThatCannotBeEndedIsNeverTouched() async {
        let (runtime, model) = Self.disbandableGroup(Self.managementState())

        let accepted = await model.endGroup(GroupDisbandState(isSelfAdmin: true, blockerCount: 3), advisory: nil)

        #expect(!accepted)
        #expect(runtime.groupMutationOrder.isEmpty)
        #expect(model.alert?.message == GroupDisbandPresentation.updateRequiredMessage(count: 3))
    }

    /// The user agreed to end the group, not to each commit on the way: one prompt, though each
    /// commit is acknowledged on its own.
    @Test func oneConsentCoversEnablingAndDisbanding() async {
        let state = Self.managementState(canEnableDisbanding: true)
        let (runtime, model) = Self.disbandableGroup(state)
        runtime.groupChangeAdvisoryRefusals[Self.groupIdHex] = .GroupCatchingUp(groupIdHex: Self.groupIdHex)
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = DisbandPromptAnswerer(prompter)

        let accepted = await model.endGroup(GroupDisbandState(managementState: state), advisory: prompter)
        answerer.stop()

        #expect(accepted)
        #expect(answerer.answeredCount == 1)
        #expect(
            runtime.groupChangeAdvisoryAcknowledgements
                == ["catchingUp:\(Self.groupIdHex)", "catchingUp:\(Self.groupIdHex)"])
        #expect(runtime.disbandGroupCallCount == 2)
    }

    @Test func waitingOnAnAdvisoryIsANoteNotAFailure() async {
        let state = Self.managementState(canDisband: true)
        let (runtime, model) = Self.disbandableGroup(state)
        runtime.groupChangeAdvisoryRefusals[Self.groupIdHex] = .GroupCommitUndelivered(groupIdHex: Self.groupIdHex)

        let accepted = await model.endGroup(GroupDisbandState(managementState: state), advisory: nil)

        #expect(!accepted)
        #expect(model.alert == GroupChangeAdvisory.commitUndelivered.waitedAlert)
        #expect(runtime.groupChangeAdvisoryAcknowledgements.isEmpty)
    }

    @Test func theCoresRefusalsAreReportedInTheUsersTerms() async {
        let state = Self.managementState(canDisband: true)
        let (runtime, model) = Self.disbandableGroup(state)
        runtime.disbandGroupError = MarmotKitError.DisbandingUnsupportedMembers(
            groupIdHex: Self.groupIdHex, memberIdsHex: ["a", "b"])

        #expect(!(await model.endGroup(GroupDisbandState(managementState: state), advisory: nil)))
        #expect(model.alert == .endGroupFailed(GroupDisbandPresentation.updateRequiredMessage(count: 2)))
        #expect(
            GroupDisbandPresentation.message(for: MarmotKitError.DisbandingNotEnabled(groupIdHex: Self.groupIdHex))
                == L10n.string("Group ending isn't ready yet. Try again."))
    }

    @Test func everyRefusalAndFailureHasItsOwnWording() {
        #expect(
            GroupDisbandPresentation.message(for: MarmotKitError.GroupDisbanding(groupIdHex: Self.groupIdHex))
                == L10n.string("This group is ending. New messages are disabled."))
        // Anything the core does not single out keeps its own description.
        let other = MarmotKitError.DisbandingNotEnabled(groupIdHex: Self.groupIdHex) as Error
        let unrelated = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(GroupDisbandPresentation.message(for: unrelated) == "boom")
        #expect(GroupDisbandPresentation.message(for: other) != "boom")

        let notAdmin = GroupDisbandPresentation.failureMessage(.noLongerAdmin)
        let notMember = GroupDisbandPresentation.failureMessage(.noLongerMember)
        #expect(notAdmin == L10n.string("The group wasn't ended because you're no longer an admin."))
        #expect(notMember == L10n.string("The group wasn't ended because you're no longer a member."))
        #expect(!GroupDisbandPresentation.confirmationTitle.isEmpty)
        #expect(!GroupDisbandPresentation.confirmationMessage.isEmpty)
    }

    /// The sidebar capsule and its glyph exist only for a group someone set out to end.
    @Test func onlyAnEndingOrEndedGroupWearsABadge() {
        #expect(GroupLifecycle.active.sidebarBadgeLabel == nil)
        #expect(GroupLifecycle.active.symbolName == nil)
        #expect(GroupLifecycle.ending.sidebarBadgeLabel == L10n.string("Ending"))
        #expect(GroupLifecycle.ending.symbolName == "hourglass")
        #expect(GroupLifecycle.ended.sidebarBadgeLabel == L10n.string("Ended"))
        #expect(GroupLifecycle.ended.symbolName == "xmark.circle.fill")
    }

    @Test func aDismissalTheCoreRefusesIsReported() async {
        let failed = Self.managementState(disbandRequest: .failed(requestedAtMs: 1, reason: .noLongerAdmin))
        let (runtime, model) = Self.disbandableGroup(failed)
        let refusal = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "storage closed"])
        runtime.acknowledgeDisbandFailureError = refusal

        #expect(!(await model.dismissFailure()))
        #expect(model.alert == .disbandFailureDismissFailed("storage closed"))
        #expect(model.alert?.title == L10n.string("Couldn't dismiss group status"))
        #expect(!model.isDismissingFailure)
    }

    /// A cancelled run is neither accepted nor a failure to show.
    @Test func aCancelledEndGroupRaisesNoAlert() async {
        let state = Self.managementState(canDisband: true)
        let (runtime, model) = Self.disbandableGroup(state)
        runtime.disbandGroupError = CancellationError()

        #expect(!(await model.endGroup(GroupDisbandState(managementState: state), advisory: nil)))
        #expect(model.alert == nil)
        #expect(!model.isEnding)
    }

    @Test func aCancelledDismissalRaisesNoAlert() async {
        let failed = Self.managementState(disbandRequest: .failed(requestedAtMs: 1, reason: .noLongerAdmin))
        let (runtime, model) = Self.disbandableGroup(failed)
        runtime.acknowledgeDisbandFailureError = CancellationError()

        #expect(!(await model.dismissFailure()))
        #expect(model.alert == nil)
    }

    @Test func dismissingAFailedRequestClearsIt() async throws {
        let failed = Self.managementState(disbandRequest: .failed(requestedAtMs: 1, reason: .noLongerAdmin))
        let (runtime, model) = Self.disbandableGroup(failed)

        #expect(await model.dismissFailure())
        #expect(runtime.acknowledgeDisbandFailureCallCount == 1)
        let state = try await runtime.groupManagementState(
            accountRef: desktopAccount().accountIdHex, groupIdHex: Self.groupIdHex)
        #expect(GroupDisbandState(managementState: state).status == .none)
        // Nothing left to clear.
        #expect(!(await model.dismissFailure()))
    }

    /// End to end through the workspace: once the core accepts, the inspector reports the group as
    /// ending and its row closes the composer and offers nothing destructive.
    @Test func anAcceptedDisbandReachesTheInspectorAndTheRow() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex),
            managementState: Self.managementState(canDisband: true))
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()
        await workspace.showGroupDetails(for: try #require(workspace.activeChats.first))
        let snapshot = try #require(workspace.groupDetailsSnapshot)
        #expect(snapshot.disband.showsEndGroup)
        let model = GroupDisbandViewModel(
            accountRef: account.accountIdHex, groupIdHex: snapshot.groupIdHex, runtime: runtime)

        #expect(await model.endGroup(snapshot.disband, advisory: nil))
        await workspace.reloadSelectedGroupDetails()
        await workspace.reloadChats(forceFreshSnapshot: true)

        let reloaded = try #require(workspace.groupDetailsSnapshot)
        #expect(reloaded.disband.status == .pending)
        #expect(!reloaded.disband.showsEndGroup)
        #expect(reloaded.destructiveAction == nil)
        #expect(reloaded.leaveGuidance == nil)
        let chat = try #require(workspace.activeChats.first { $0.id == snapshot.groupIdHex })
        #expect(chat.lifecycle == .ending)
        #expect(!chat.canUseComposer)
    }

    // MARK: - Helpers

    private static func disbandableGroup(
        _ managementState: GroupManagementStateFfi
    ) -> (FakeMarmotRuntime, GroupDisbandViewModel) {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex), managementState: managementState)
        let model = GroupDisbandViewModel(accountRef: account.accountIdHex, groupIdHex: groupIdHex, runtime: runtime)
        return (runtime, model)
    }

    private static func managementState(
        isSelfAdmin: Bool = true,
        disbanding: Bool = false,
        canEnableDisbanding: Bool = false,
        canDisband: Bool = false,
        disbandingBlockers: [String] = [],
        disbandRequest: DisbandRequestFfi? = nil
    ) -> GroupManagementStateFfi {
        GroupManagementStateFfi(
            myAccountIdHex: desktopAccount().accountIdHex,
            isSelfAdmin: isSelfAdmin,
            isLastAdmin: isSelfAdmin,
            canInvite: isSelfAdmin && !disbanding,
            canLeave: false,
            requiresSelfDemoteBeforeLeave: isSelfAdmin && !disbanding,
            leaveRequestPending: false,
            leaveRequestedAtMs: nil,
            lifecycleState: .stable,
            disbandingEnabled: canDisband,
            disbanding: disbanding,
            canEnableDisbanding: canEnableDisbanding,
            canDisband: canDisband,
            disbandingBlockers: disbandingBlockers,
            disbandRequest: disbandRequest,
            memberActions: []
        )
    }
}

/// Approves every advisory prompt as it appears, counting them.
@MainActor
private final class DisbandPromptAnswerer {
    private(set) var answeredCount = 0
    private var task: Task<Void, Never>?

    init(_ prompter: GroupChangeAdvisoryPrompter) {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let prompt = prompter.prompt {
                    self?.answeredCount += 1
                    prompter.resolve(id: prompt.id, approved: true)
                }
                await Task.yield()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
