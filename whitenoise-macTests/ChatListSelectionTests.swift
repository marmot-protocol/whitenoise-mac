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

    /// Delete is offered only when it is right for every selected chat — the iOS rule — so a mixed
    /// selection never drops a chat the user still belongs to.
    @Test func bulkDeleteIsOfferedOnlyWhenEverySelectedChatIsAlreadyLeft() {
        let left = selectionChat("left", selfMembership: .left)
        let removed = selectionChat("removed", selfMembership: .removed)
        let member = selectionChat("member")
        let ended = ChatItem(
            id: "ended", title: "Ended", subtitle: "", preview: "", updatedAt: nil, avatarSeed: "ended",
            pictureURL: nil, unreadCount: 0, lifecycle: .ended
        )
        let ending = ChatItem(
            id: "ending", title: "Ending", subtitle: "", preview: "", updatedAt: nil, avatarSeed: "ending",
            pictureURL: nil, unreadCount: 0, lifecycle: .ending
        )

        #expect(ChatListSelection.canDeleteLocally([left, removed, ended]))
        #expect(!ChatListSelection.canDeleteLocally([]))
        #expect(!ChatListSelection.canDeleteLocally([left, member]))
        #expect(!ChatListSelection.canDeleteLocally([left, ending]))
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
        var changes: [ChatListBatchChanges] = []
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime) { change in
            changes.append(change)
        }
        model.updateVisibleChats(["a", "b", "c"])
        model.begin(with: "a")
        model.toggle("c")

        let task = try #require(model.setArchived(true, groupIds: ["a", "c"]))
        #expect(model.operation == .archiving)
        await task.value

        #expect(runtime.setGroupArchivedCallCount == 2)
        #expect(changes == [.none])
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
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime) { change in
            departedChats.formUnion(change.departedGroupIds)
            #expect(change.deletedGroupIds.isEmpty)
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

    /// A selected chat the bar could not resolve to a row was never checked for a blocker; leaving
    /// the rest and then ending selection mode would drop it without a word.
    @MainActor
    @Test func aSelectedChatWithNoRowStopsTheLeaveAndStaysSelected() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"])
        model.begin(with: "a")
        model.toggle("b")

        #expect(model.requestLeave([selectionChat("a")]) == nil)

        #expect(model.pendingLeave == nil)
        #expect(!model.isBusy)
        #expect(model.isActive)
        #expect(model.selectedIds == ["a", "b"])
        #expect(model.alert?.message == L10n.plural("Couldn't leave %lld chats. Try again.", Int64(1)))
        #expect(runtime.leaveGroupCallCount == 0)
    }

    @MainActor
    @Test func aChatWhoseEndGroupIsRunningIsNotOfferedForLeave() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.isEnding = { $0 == "b" }
        let chats = [selectionChat("a"), selectionChat("b")]
        model.updateVisibleChats(chats.map(\.id))
        model.begin(with: "a")
        model.toggle("b")

        await model.requestLeave(chats)?.value

        #expect(model.pendingLeave?.groupIds == ["a"])
    }

    /// End Group can start on a chat between the confirmation and the click; the leave would race
    /// the disband, which the row menu prevents.
    @MainActor
    @Test func aChatWhoseEndGroupStartedAfterTheConfirmationIsNotLeft() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        let chats = [selectionChat("a"), selectionChat("b")]
        model.updateVisibleChats(chats.map(\.id))
        model.begin(with: "a")
        model.toggle("b")
        await model.requestLeave(chats)?.value
        let confirmation = try #require(model.pendingLeave)
        #expect(confirmation.groupIds == ["a", "b"])

        model.isEnding = { $0 == "b" }
        await model.confirmLeave(confirmation)?.value

        #expect(runtime.leaveGroupCallCount == 1)
        #expect(model.isActive)
        #expect(model.selectedIds == ["b"])
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

    /// After a read gives up, a quiet list has no row change to retry on; one more read runs on
    /// its own, so Select All does not stay off until selection mode is left and re-entered.
    @MainActor
    @Test func aFailedViewReadIsRetriedOnceWithoutARowChange() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        runtime.chatListIdsErrors = [ChatListSelectionTestError(), ChatListSelectionTestError()]
        let model = ChatListSelectionViewModel(
            accountRef: "account", runtime: runtime, failedReadRetryDelay: .zero)
        model.updateVisibleChats(["a"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)

        model.begin(with: "a")
        await model.viewIdsTask?.value
        // With no delay the retry may already have run by now; awaiting whichever is left.
        await model.viewIdsTask?.value

        // The retry failed too, and is not retried again.
        #expect(runtime.chatListIdsCallCount == 2)
        #expect(model.viewIdsTask == nil)
        #expect(model.viewIds == nil)

        // A row change still reads at once.
        model.updateVisibleChats(["a"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
        await model.viewIdsTask?.value
        #expect(model.viewIds == ["a", "b"])
    }

    /// Rows that keep changing push the refresh back only until it has waited `refreshMaxWait`;
    /// after that a change leaves the pending read alone, so a busy inbox still refreshes.
    @MainActor
    @Test func aRefreshIsNotPushedBackPastItsMaxWait() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let debounced = ChatListSelectionViewModel(
            accountRef: "account", runtime: runtime, refreshDelay: .seconds(60), refreshMaxWait: .seconds(60))
        let capped = ChatListSelectionViewModel(
            accountRef: "account", runtime: runtime, refreshDelay: .seconds(60), refreshMaxWait: .zero)
        for model in [debounced, capped] {
            model.updateVisibleChats(["a"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
            model.begin(with: "a")
            await model.viewIdsTask?.value
            model.updateVisibleChats(["b", "a"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
        }
        let debouncedFirst = try #require(debounced.viewIdsTask)
        let cappedFirst = try #require(capped.viewIdsTask)

        debounced.updateVisibleChats(["a", "b"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
        capped.updateVisibleChats(["a", "b"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)

        #expect(debounced.viewIdsTask != debouncedFirst)
        #expect(capped.viewIdsTask == cappedFirst)
        debounced.end()
        capped.end()
    }

    /// The first read is left to finish when rows change under it, so a chat that arrived
    /// meanwhile is read once more after it lands.
    @MainActor
    @Test func rowsThatChangeDuringTheFirstReadAreReadAgainAfterIt() async throws {
        let runtime = selectionRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime, refreshDelay: .zero)
        model.updateVisibleChats(["a"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)

        model.begin(with: "a")
        let first = try #require(model.viewIdsTask)
        model.updateVisibleChats(["b", "a"], query: ChatListSearchQuery.unfiltered(.chats), isWindowed: true)
        #expect(model.viewIdsTask == first)
        await first.value

        // With no delay the follow-up may already have run by now; awaiting whichever is left.
        await model.viewIdsTask?.value
        #expect(runtime.chatListIdsCallCount == 2)
        #expect(model.viewIdsTask == nil)
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

    /// MDK files a chat that is both archived and left under Left only. Were the Archived tab to
    /// draw it, a click would select it and the view-id read would drop it again a moment later.
    /// Every row the tab draws must still be selected once MDK's view has answered.
    @MainActor
    @Test func everyRowTheArchivedTabDrawsStaysSelectedAfterTheViewRead() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        var archived = messageGroup()
        archived.groupIdHex = "archived"
        archived.archived = true
        var archivedLeft = messageGroup(selfMembership: .left)
        archivedLeft.groupIdHex = "archived-left"
        archivedLeft.archived = true
        runtime.installGroups([archived, archivedLeft])
        let list = ChatListViewModel(account: AccountItem.samples[0], runtime: runtime)
        list.start()
        defer { list.stop() }
        for _ in 0..<100 where list.presentedRows.count != 2 {
            await Task.yield()
        }

        let drawn = list.chats(view: .archived, nicknames: .none).map(\.id)
        #expect(drawn == ["archived"])
        // The Left tab still lists it, and still knows it is archived (it offers Unarchive).
        #expect(list.chats(view: .left, nicknames: .none).map(\.id) == ["archived-left"])
        #expect(list.archivedGroupIds == ["archived", "archived-left"])

        let selection = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        selection.updateVisibleChats(drawn, query: ChatListSearchQuery.unfiltered(.archived), isWindowed: true)
        let first = try #require(drawn.first)
        selection.begin(with: first)
        for id in drawn.dropFirst() { selection.toggle(id) }
        await selection.viewIdsTask?.value

        #expect(selection.selectedIds == Set(drawn))
        #expect(selection.allSelected)
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

// MARK: - Bulk delete

extension ChatListSelectionTests {
    @MainActor
    @Test func bulkDeleteAsksOnceThenDeletesEveryLeftChat() async throws {
        let runtime = leftChatsRuntime(groupIds: ["a", "b", "c"])
        var changes: [ChatListBatchChanges] = []
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime) { change in
            changes.append(change)
        }
        let chats = ["a", "b", "c"].map { selectionChat($0, selfMembership: .left) }
        model.updateVisibleChats(chats.map(\.id), query: ChatListSearchQuery.unfiltered(.left))
        model.begin(with: "c")
        model.toggle("a")

        #expect(model.requestDelete(chats))

        // Asking deletes nothing; the confirmation carries the selection in list order.
        let confirmation = try #require(model.pendingDelete)
        #expect(confirmation.groupIds == ["a", "c"])
        #expect(runtime.deleteGroupLocalCallCount == 0)

        let task = try #require(model.confirmDelete(confirmation))
        #expect(model.operation == .deleting)
        #expect(model.pendingDelete == nil)
        await task.value

        #expect(runtime.locallyDeletedGroupIds == ["a", "c"])
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(changes == [ChatListBatchChanges(deletedGroupIds: ["a", "c"])])
        #expect(runtime.revalidateChatListIdsCalls.last?.view == .left)
        #expect(!model.isActive)
        #expect(!model.isBusy)
        #expect(model.alert == nil)
    }

    @MainActor
    @Test func aSelectionWithAChatStillJoinedIsNeverAskedToDelete() async throws {
        let runtime = leftChatsRuntime(groupIds: ["a"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        let chats = [selectionChat("a", selfMembership: .left), selectionChat("b")]
        model.updateVisibleChats(chats.map(\.id))
        model.begin(with: "a")
        model.toggle("b")

        #expect(!model.requestDelete(chats))
        #expect(model.pendingDelete == nil)
        #expect(runtime.deleteGroupLocalCallCount == 0)
    }

    /// A selected chat the bar could not resolve to a row was never checked, so it is not deleted
    /// on the strength of the others.
    @MainActor
    @Test func aSelectedChatWithNoRowIsNeverAskedToDelete() async throws {
        let runtime = leftChatsRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a", "b"], query: ChatListSearchQuery.unfiltered(.left))
        model.begin(with: "a")
        model.toggle("b")

        #expect(!model.requestDelete([selectionChat("a", selfMembership: .left)]))
        #expect(model.pendingDelete == nil)
        #expect(model.selectedIds == ["a", "b"])
    }

    @MainActor
    @Test func failedDeletesStaySelectedAndAreReportedTogether() async throws {
        let runtime = leftChatsRuntime(groupIds: ["a", "b", "c"])
        runtime.deleteGroupLocalFailingIds = ["b", "c"]
        var changes: [ChatListBatchChanges] = []
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime) { change in
            changes.append(change)
        }
        let chats = ["a", "b", "c"].map { selectionChat($0, selfMembership: .left) }
        model.updateVisibleChats(chats.map(\.id), query: ChatListSearchQuery.unfiltered(.left))
        model.begin(with: "a")
        model.toggleAll()
        #expect(model.requestDelete(chats))
        let confirmation = try #require(model.pendingDelete)

        await model.confirmDelete(confirmation)?.value

        // The chat that went is reported, so an open conversation on it still closes.
        #expect(changes == [ChatListBatchChanges(deletedGroupIds: ["a"])])
        #expect(model.isActive)
        #expect(model.selectedIds == ["b", "c"])
        #expect(model.alert?.title == L10n.string("Couldn't delete chat"))
        #expect(model.alert?.message == L10n.plural("%lld chats remain. Try again.", Int64(2)))
    }

    /// A chat can leave the Left view between the confirmation and the click — re-added to its
    /// group — and must then not be deleted.
    @MainActor
    @Test func confirmingADeleteSkipsChatsThatLeftTheViewSinceTheConfirmation() async throws {
        let runtime = leftChatsRuntime(groupIds: ["a", "b"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        let chats = ["a", "b"].map { selectionChat($0, selfMembership: .left) }
        model.updateVisibleChats(chats.map(\.id), query: ChatListSearchQuery.unfiltered(.left))
        model.begin(with: "a")
        model.toggle("b")
        #expect(model.requestDelete(chats))
        let confirmation = try #require(model.pendingDelete)

        runtime.chatListIdsByView[.left] = ["b"]
        await model.confirmDelete(confirmation)?.value

        #expect(runtime.locallyDeletedGroupIds == ["b"])
        #expect(!model.isActive)
    }

    /// Revalidation answers from the view, which may still list a chat re-added to its group while
    /// the dialog was open; the chat's current row is what stops the delete.
    @MainActor
    @Test func confirmingADeleteSkipsChatsRejoinedSinceTheConfirmation() async throws {
        let runtime = leftChatsRuntime(groupIds: ["a", "b"])
        var changes: [ChatListBatchChanges] = []
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime) { change in
            changes.append(change)
        }
        let chats = ["a", "b"].map { selectionChat($0, selfMembership: .left) }
        model.updateVisibleChats(chats.map(\.id), query: ChatListSearchQuery.unfiltered(.left))
        model.begin(with: "a")
        model.toggle("b")
        #expect(model.requestDelete(chats))
        let confirmation = try #require(model.pendingDelete)

        // `leftChatsRuntime` pins the Left view's ids, so "a" still passes revalidation.
        var rejoined = messageGroup(selfMembership: .member)
        rejoined.groupIdHex = "a"
        runtime.installGroupDetailsRecord(GroupDetailsFfi(group: rejoined, members: []))
        await model.confirmDelete(confirmation)?.value

        #expect(runtime.locallyDeletedGroupIds == ["b"])
        #expect(changes == [ChatListBatchChanges(deletedGroupIds: ["b"])])
        #expect(model.alert == nil)
        #expect(!model.isActive)
    }

    @MainActor
    @Test func endingSelectionForgetsAPendingDelete() async throws {
        let runtime = leftChatsRuntime(groupIds: ["a"])
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        model.updateVisibleChats(["a"], query: ChatListSearchQuery.unfiltered(.left))
        model.begin(with: "a")
        #expect(model.requestDelete([selectionChat("a", selfMembership: .left)]))

        model.end()

        #expect(model.pendingDelete == nil)
        #expect(runtime.deleteGroupLocalCallCount == 0)
    }
}

// MARK: - Fixtures

/// Groups this account has left, listed in MDK's Left view.
@MainActor
private func leftChatsRuntime(groupIds: [String]) -> FakeMarmotRuntime {
    let runtime = selectionRuntime(groupIds: groupIds, selfMembership: .left)
    runtime.chatListIdsByView[.left] = groupIds
    return runtime
}

private struct ChatListSelectionTestError: Error {}

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
    stepDownIds: Set<String> = [],
    selfMembership: SelfMembershipFfi = .member
) -> FakeMarmotRuntime {
    let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
    for groupIdHex in groupIds {
        var group = messageGroup(selfMembership: selfMembership)
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
