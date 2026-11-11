//
//  ChatListSelectionTests.swift
//  whitenoise-macTests
//
//  Selecting several chats in the list: the pure bulk rules (`ChatListSelection`, matching
//  whitenoise-ios and Android) and the account-scoped model that runs the bulk actions.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct ChatListSelectionTests {
    // MARK: - Rules

    @Test func archiveTogglesToUnarchiveOnlyWhenEverySelectedChatIsArchived() {
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: []) == .archive)
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [true, false]) == .archive)
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [false]) == .archive)
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [true, true]) == .unarchive)
    }

    @Test func muteTogglesToUnmuteOnlyWhenEverySelectedChatIsMuted() {
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: []))
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: [true, false]))
        #expect(!ChatListSelection.bulkMuteMutes(mutedFlags: [true, true]))
    }

    @Test func toggleAllSelectsEveryVisibleChatThenClears() {
        let visible: Set<String> = ["a", "b", "c"]
        let all = ChatListSelection.togglingAll(["a"], visibleIds: visible)
        #expect(all == visible)
        #expect(ChatListSelection.allSelected(all, visibleIds: visible))
        #expect(ChatListSelection.togglingAll(all, visibleIds: visible).isEmpty)
        #expect(!ChatListSelection.allSelected([], visibleIds: []))
    }

    @Test func reconcileDropsChatsThatLeftTheVisibleList() {
        #expect(ChatListSelection.reconcile(["a", "b"], visibleIds: ["b", "c"]) == ["b"])
    }

    @Test func shiftClickSelectsTheRangeInListOrderInEitherDirection() {
        let order = ["a", "b", "c", "d", "e"]
        #expect(ChatListSelection.extending([], from: "b", to: "d", in: order) == ["b", "c", "d"])
        #expect(ChatListSelection.extending(["e"], from: "d", to: "b", in: order) == ["b", "c", "d", "e"])
        // No usable anchor: only the clicked row.
        #expect(ChatListSelection.extending([], from: nil, to: "c", in: order) == ["c"])
        #expect(ChatListSelection.extending([], from: "gone", to: "c", in: order) == ["c"])
        // A row that is not in the list changes nothing.
        #expect(ChatListSelection.extending(["a"], from: "a", to: "gone", in: order) == ["a"])
    }

    @Test func leaveTargetsSkipChatsAlreadyLeftOrLeaving() {
        let member = selectionChat("member")
        let left = selectionChat("left", selfMembership: .left)
        let leaving = selectionChat("leaving", leaveRequestPending: true)
        #expect(ChatListSelection.leaveTargets([member, left, leaving]).map(\.id) == ["member"])
    }

    /// A group whose End Group run is in flight is skipped, as its row menu disables Leave: the
    /// disband is a commit the row cannot see yet, and a leave would race it.
    @Test func leaveTargetsSkipGroupsBeingEnded() {
        let member = selectionChat("member")
        let ending = selectionChat("ending")
        #expect(
            ChatListSelection.leaveTargets([member, ending], endingGroupIds: ["ending"]).map(\.id) == ["member"])
        #expect(ChatListSelection.leaveTargets([member, ending]).map(\.id) == ["member", "ending"])
    }

    @Test func muteDurationsMatchTheRowMenu() {
        #expect(
            ChatMuteDuration.allCases.map(\.titleKey) == [
                "For 1 Hour", "For 8 Hours", "For 1 Week", "Until I Turn It Back On",
            ])
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ChatMuteDuration.oneHour.mutedUntilMs(from: now) == 4_600_000)
        #expect(ChatMuteDuration.indefinitely.mutedUntilMs(from: now) == nil)
    }

    // MARK: - Model

    @MainActor
    @Test func clickingThroughASelectionTogglesAndEndsCleanly() {
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: nil)
        model.updateVisibleChats(["a", "b", "c"])

        model.begin(with: "a")
        #expect(model.isActive)
        #expect(model.selectedIds == ["a"])

        model.toggle("b")
        model.toggle("a")
        #expect(model.selectedIds == ["b"])

        // The range runs from the last clicked row ("a"), as in Finder.
        model.extend(to: "c")
        #expect(model.selectedIds == ["a", "b", "c"])
        #expect(model.allSelected)

        model.toggleAll()
        #expect(model.selectedIds.isEmpty)
        model.toggleAll()
        #expect(model.allSelected)

        model.end()
        #expect(!model.isActive)
    }

    @MainActor
    @Test func shiftClickOutsideSelectionModeRangesFromTheOpenChat() {
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: nil)
        model.updateVisibleChats(["a", "b", "c", "d"])

        model.extend(to: "c", defaultAnchor: "a")

        #expect(model.isActive)
        #expect(model.selectedIds == ["a", "b", "c"])
    }

    @MainActor
    @Test func aFilterChangeDropsSelectionsThatAreNoLongerVisible() {
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: nil)
        model.updateVisibleChats(["a", "b"])
        model.begin(with: "a")
        model.toggle("b")

        model.updateVisibleChats(["b", "c"])

        #expect(model.selectedIds == ["b"])
    }

    @MainActor
    @Test func bulkArchiveArchivesEveryChatThenEndsSelection() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b", "c"])
        var changes: [Set<String>] = []
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime) { departed in
            changes.append(departed)
        }
        model.updateVisibleChats(["a", "b", "c"])
        model.begin(with: "a")
        model.toggle("c")

        let task = try #require(model.setArchived(true, groupIds: ["a", "c"]))
        #expect(model.operation == .archiving)
        await task.value

        #expect(runtime.setGroupArchivedCallCount == 2)
        #expect(changes == [[]])
        #expect(!model.isActive)
        #expect(!model.isBusy)
        #expect(model.alert == nil)
    }

    @MainActor
    @Test func failedArchivesStaySelectedAndAreReportedTogether() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        runtime.setGroupArchivedError = FakeMarmotRuntimeError.unused
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"])
        model.begin(with: "a")
        model.toggle("b")

        await model.setArchived(true, groupIds: ["a", "b"])?.value

        #expect(model.isActive)
        #expect(model.selectedIds == ["a", "b"])
        #expect(model.alert?.title == L10n.string("Couldn't archive chat"))
    }

    @MainActor
    @Test func bulkMuteMutesEachChatAndUnmuteClearsIt() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"])

        model.begin(with: "a")
        model.toggle("b")
        await model.setMuted(.indefinitely, groupIds: ["a", "b"])?.value
        #expect(runtime.setChatMutedCallCount == 2)
        #expect(runtime.lastMutedUntilMs == nil)
        #expect(!model.isActive)

        model.begin(with: "a")
        await model.setMuted(nil, groupIds: ["a"])?.value
        #expect(runtime.clearChatMutedCallCount == 1)
    }

    @MainActor
    @Test func bulkLeaveAsksOnceThenLeavesEveryChat() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        var departedChats = Set<String>()
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime) { departed in
            departedChats.formUnion(departed)
        }
        let chats = [selectionChat("a"), selectionChat("b")]
        model.updateVisibleChats(chats.map(\.id))
        model.begin(with: "a")
        model.toggle("b")

        await model.requestLeave(chats)?.value

        // Preparing publishes nothing: it only opens the confirmation.
        let confirmation = try #require(model.pendingLeave)
        #expect(confirmation.groupIds == ["a", "b"])
        #expect(runtime.leaveGroupCallCount == 0)

        await model.confirmLeave(confirmation)?.value

        #expect(runtime.leaveGroupCallCount == 2)
        #expect(departedChats == ["a", "b"])
        #expect(!model.isActive)
        #expect(model.alert == nil)
    }

    /// SwiftUI can clear the dialog's binding before it runs the button's action, so confirming
    /// must not depend on `pendingLeave` still being set.
    @MainActor
    @Test func confirmingStillLeavesAfterTheDialogClearedItsBinding() async throws {
        let runtime = selectionRuntime(groupIds: ["a"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a"])
        model.begin(with: "a")
        await model.requestLeave([selectionChat("a")])?.value
        let confirmation = try #require(model.pendingLeave)

        model.pendingLeave = nil
        await model.confirmLeave(confirmation)?.value

        #expect(runtime.leaveGroupCallCount == 1)
    }

    @MainActor
    @Test func aSoleAdminChatStopsTheBulkLeaveBeforeAnythingIsPublished() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"], soleAdminIds: ["b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        let chats = [selectionChat("a"), selectionChat("b", title: "Book club")]
        model.updateVisibleChats(chats.map(\.id))
        model.begin(with: "a")
        model.toggle("b")

        await model.requestLeave(chats)?.value

        #expect(model.pendingLeave == nil)
        #expect(
            model.alert?.title
                == String(format: L10n.string("Couldn't leave “%@”"), PeerDisplayText.templateFragment("Book club")))
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        // The selection survives, so the user can drop the blocking chat and try again.
        #expect(model.selectedIds == ["a", "b"])
    }

    @MainActor
    @Test func failedLeavesStaySelected() async throws {
        let runtime = selectionRuntime(groupIds: ["a"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        let chats = [selectionChat("a")]
        model.updateVisibleChats(["a"])
        model.begin(with: "a")
        await model.requestLeave(chats)?.value
        let confirmation = try #require(model.pendingLeave)
        runtime.leaveGroupError = FakeMarmotRuntimeError.unused

        await model.confirmLeave(confirmation)?.value

        #expect(model.isActive)
        #expect(model.selectedIds == ["a"])
        #expect(model.alert?.message == L10n.plural("Couldn't leave %lld chats. Try again.", Int64(1)))
    }

    /// An admin who is not the last one steps down before leaving. A batch cancelled while the
    /// eligibility read is suspended must not go on to publish that step-down.
    @MainActor
    @Test func aCancelledLeaveNeverStepsDownAfterTheEligibilityRead() async throws {
        let runtime = selectionRuntime(groupIds: ["a"], stepDownIds: ["a"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a"])
        model.begin(with: "a")
        await model.requestLeave([selectionChat("a")])?.value
        let confirmation = try #require(model.pendingLeave)
        runtime.groupManagementStateGateEnabled = true

        let leave = try #require(model.confirmLeave(confirmation))
        await runtime.waitUntilGroupManagementStateGateReached()
        leave.cancel()
        runtime.releaseGroupManagementStateGate()
        await leave.value

        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(runtime.leaveGroupCallCount == 0)
    }

    @MainActor
    @Test func stoppingTheScopeCancelsTheBatchAndForgetsTheSelection() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        runtime.groupMutationGateEnabled = true
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"])
        model.begin(with: "a")
        model.toggle("b")

        let task = try #require(model.setArchived(true, groupIds: ["a", "b"]))
        while !runtime.didReachGroupMutationGate {
            await Task.yield()
        }
        model.stop()
        runtime.releaseGroupMutationGate()
        await task.value

        #expect(runtime.setGroupArchivedCallCount == 1)
        #expect(!model.isActive)
        #expect(!model.isBusy)
        #expect(model.alert == nil)
    }

    // MARK: - Selection against MDK's view

    @Test func orderedSelectionFollowsTheListThenKeepsTheRest() {
        #expect(ChatListSelection.ordered(["c", "a", "z"], by: ["a", "b", "c"]) == ["a", "c", "z"])
    }

    /// The inbox is a 50-row window; Select All must reach every chat in the view, and count them.
    @MainActor
    @Test func selectAllInAWindowedListSelectsEveryChatInTheView() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b", "c", "d"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)

        model.begin(with: "a")
        #expect(!model.canToggleAll)
        await model.viewIdsTask?.value

        #expect(model.viewIds == ["a", "b", "c", "d"])
        model.toggleAll()
        #expect(model.selectedIds == ["a", "b", "c", "d"])
        #expect(model.allSelected)
        #expect(model.orderedSelection == ["a", "b", "c", "d"])

        // Paging the window does not shed chats that scrolled out of it.
        model.updateVisibleChats(["c", "d"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
        await model.viewIdsTask?.value
        #expect(model.selectedIds == ["a", "b", "c", "d"])
    }

    @MainActor
    @Test func selectAllStaysOffWhileTheViewIsNotReadyThenRetries() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        runtime.chatListIdsErrors = [MarmotKitError.ChatPresentationNotReady]
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)

        model.begin(with: "a")
        model.toggleAll()
        #expect(model.selectedIds == ["a"])

        await model.viewIdsTask?.value
        #expect(runtime.chatListIdsCallCount == 2)
        #expect(model.viewIds == ["a", "b"])
        #expect(model.canToggleAll)
    }

    @MainActor
    @Test func aWindowedListDropsOnlyChatsThatLeftTheView() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b", "c"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b", "c"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
        model.begin(with: "a")
        model.toggle("c")
        await model.viewIdsTask?.value

        runtime.chatListIdsByView[.chats] = ["a", "b"]
        model.updateVisibleChats(["a", "b"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
        await model.viewIdsTask?.value

        #expect(model.selectedIds == ["a"])
    }

    @MainActor
    @Test func aBulkArchiveRevalidatesAndActsOnlyOnChatsStillInTheView() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b", "c"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b", "c"], query: ChatListSearchQuery.unfiltered(.archived))
        model.begin(with: "c")
        model.toggle("a")
        // "c" was unarchived elsewhere after it was picked.
        runtime.chatListIdsByView[.archived] = ["a", "b"]

        await model.setArchived(false, groupIds: model.orderedSelection)?.value

        #expect(runtime.revalidateChatListIdsCalls.count == 1)
        #expect(runtime.revalidateChatListIdsCalls.first?.view == .archived)
        #expect(runtime.revalidateChatListIdsCalls.first?.groupIds == ["a", "c"])
        #expect(runtime.setGroupArchivedCallCount == 1)
        #expect(!model.isActive)
    }

    @MainActor
    @Test func aBulkMuteRetriesRevalidationWhileTheViewIsNotReady() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"])
        model.begin(with: "a")
        model.toggle("b")
        runtime.chatListIdsErrors = [MarmotKitError.ChatPresentationNotReady]

        await model.setMuted(.oneHour, groupIds: model.orderedSelection)?.value

        #expect(runtime.revalidateChatListIdsCalls.count == 2)
        #expect(runtime.setChatMutedCallCount == 2)
        #expect(model.alert == nil)
    }

    @MainActor
    @Test func aFailedRevalidationKeepsTheSelectionAndPublishesNothing() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"])
        model.begin(with: "a")
        model.toggle("b")
        runtime.chatListIdsErrors = [FakeMarmotRuntimeError.unused]

        await model.setArchived(true, groupIds: model.orderedSelection)?.value

        #expect(runtime.setGroupArchivedCallCount == 0)
        #expect(model.isActive)
        #expect(model.selectedIds == ["a", "b"])
        #expect(model.alert?.message == L10n.plural("%lld chats remain. Try again.", Int64(2)))
    }

    /// The group can leave the view between the confirmation and the click; the leave revalidates
    /// right before it runs.
    @MainActor
    @Test func confirmingALeaveSkipsChatsThatLeftTheViewSinceTheConfirmation() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        let chats = [selectionChat("a"), selectionChat("b")]
        model.updateVisibleChats(chats.map(\.id))
        model.begin(with: "a")
        model.toggle("b")
        await model.requestLeave(chats)?.value
        let confirmation = try #require(model.pendingLeave)

        runtime.chatListIdsByView[.chats] = ["b"]
        await model.confirmLeave(confirmation)?.value

        #expect(runtime.leaveGroupCallCount == 1)
        #expect(runtime.revalidateChatListIdsCalls.last?.groupIds == ["a", "b"])
        #expect(!model.isActive)
    }
}

// MARK: - Fixtures

private func selectionChat(
    _ id: String,
    title: String? = nil,
    leaveRequestPending: Bool = false,
    selfMembership: ChatSelfMembership = .member
) -> ChatItem {
    ChatItem(
        id: id,
        title: title ?? "Chat \(id)",
        subtitle: "Group message",
        preview: "",
        updatedAt: nil,
        avatarSeed: id,
        pictureURL: nil,
        unreadCount: 0,
        leaveRequestPending: leaveRequestPending,
        selfMembership: selfMembership
    )
}

/// Groups this account can leave without stepping down, except `soleAdminIds`, where it is the
/// only admin and the core refuses the leave, and `stepDownIds`, where it is one of several
/// admins and steps down before leaving.
@MainActor
private func selectionRuntime(
    groupIds: [String],
    soleAdminIds: Set<String> = [],
    stepDownIds: Set<String> = []
) -> FakeMarmotRuntime {
    let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
    for groupIdHex in groupIds {
        var group = messageGroup()
        group.groupIdHex = groupIdHex
        let isSoleAdmin = soleAdminIds.contains(groupIdHex)
        let stepsDown = isSoleAdmin || stepDownIds.contains(groupIdHex)
        runtime.installGroupDetailsRecord(
            GroupDetailsFfi(group: group, members: []),
            managementState: GroupManagementStateFfi(
                myAccountIdHex: desktopAccount().accountIdHex,
                isSelfAdmin: stepsDown,
                isLastAdmin: isSoleAdmin,
                canInvite: isSoleAdmin,
                canLeave: !isSoleAdmin,
                requiresSelfDemoteBeforeLeave: stepsDown,
                memberActions: []
            )
        )
    }
    return runtime
}
