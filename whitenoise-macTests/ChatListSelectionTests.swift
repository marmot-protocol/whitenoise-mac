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
        #expect(model.allVisibleSelected)

        model.toggleAll()
        #expect(model.selectedIds.isEmpty)
        model.toggleAll()
        #expect(model.allVisibleSelected)

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
/// only admin and the core refuses the leave.
@MainActor
private func selectionRuntime(groupIds: [String], soleAdminIds: Set<String> = []) -> FakeMarmotRuntime {
    let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
    for groupIdHex in groupIds {
        var group = messageGroup()
        group.groupIdHex = groupIdHex
        let isSoleAdmin = soleAdminIds.contains(groupIdHex)
        runtime.installGroupDetailsRecord(
            GroupDetailsFfi(group: group, members: []),
            managementState: GroupManagementStateFfi(
                myAccountIdHex: desktopAccount().accountIdHex,
                isSelfAdmin: isSoleAdmin,
                isLastAdmin: isSoleAdmin,
                canInvite: isSoleAdmin,
                canLeave: !isSoleAdmin,
                requiresSelfDemoteBeforeLeave: isSoleAdmin,
                memberActions: []
            )
        )
    }
    return runtime
}
