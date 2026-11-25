import AppKit
import Foundation
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

struct MainWindowSurfacesTests: WorkspaceTestSupport {

    // MARK: - #1037: Chat list filters, click/selection routing, and profile switcher

    @Test func chatListRowClickPolicyPreservesOpenChatAndBatchSelectionContracts() {
        #expect(
            ChatListRowClickPolicy.action(
                modifiers: [],
                isBatchSelectionActive: false,
                openChatId: "open-chat"
            ) == .openChat
        )

        #expect(
            ChatListRowClickPolicy.action(
                modifiers: [.command],
                isBatchSelectionActive: false,
                openChatId: "open-chat"
            ) == .beginSelection
        )

        #expect(
            ChatListRowClickPolicy.action(
                modifiers: [.shift],
                isBatchSelectionActive: false,
                openChatId: "open-chat"
            ) == .extendSelection(defaultAnchor: "open-chat")
        )

        #expect(
            ChatListRowClickPolicy.action(
                modifiers: [],
                isBatchSelectionActive: true,
                openChatId: "open-chat"
            ) == .toggleSelection
        )

        #expect(
            ChatListRowClickPolicy.action(
                modifiers: [.shift],
                isBatchSelectionActive: true,
                openChatId: "open-chat"
            ) == .extendSelection(defaultAnchor: "open-chat")
        )
    }

    @Test func nativeListSelectionRejectsBatchSelectionModifiersAndNil() {
        #expect(
            !ChatListRowClickPolicy.shouldApplyNativeListSelection(
                newId: "other-chat",
                currentOpenChatId: "open-chat",
                isBatchSelectionActive: true
            )
        )
        #expect(
            !ChatListRowClickPolicy.shouldApplyNativeListSelection(
                newId: "other-chat",
                currentOpenChatId: "open-chat",
                isBatchSelectionActive: false,
                modifiers: [.command]
            )
        )
        #expect(
            !ChatListRowClickPolicy.shouldApplyNativeListSelection(
                newId: "other-chat",
                currentOpenChatId: "open-chat",
                isBatchSelectionActive: false,
                modifiers: [.shift]
            )
        )
        #expect(
            !ChatListRowClickPolicy.shouldApplyNativeListSelection(
                newId: nil,
                currentOpenChatId: "open-chat",
                isBatchSelectionActive: false
            )
        )
        #expect(
            !ChatListRowClickPolicy.shouldApplyNativeListSelection(
                newId: "open-chat",
                currentOpenChatId: "open-chat",
                isBatchSelectionActive: false
            )
        )
        #expect(
            ChatListRowClickPolicy.shouldApplyNativeListSelection(
                newId: "other-chat",
                currentOpenChatId: "open-chat",
                isBatchSelectionActive: false
            )
        )
    }

    @Test func profileSwitcherAttentionSummaryExcludesActiveAccountAndClampsOverflow() {
        let active = AccountItem(summary: desktopAccount())
        let secondary = AccountItem(
            summary: AccountSummaryFfi(
                label: "bob",
                accountIdHex: String(repeating: "b", count: 64),
                localSigning: true,
                externalSigning: false,
                signedOut: false,
                running: true,
                unlinked: false
            )
        )
        let third = AccountItem(
            summary: AccountSummaryFfi(
                label: "carol",
                accountIdHex: String(repeating: "c", count: 64),
                localSigning: true,
                externalSigning: false,
                signedOut: false,
                running: true,
                unlinked: false
            )
        )

        let countsByHex: [String: Int] = [
            active.accountIdHex: 12,
            secondary.accountIdHex: 4,
            third.accountIdHex: 3,
        ]
        let summary = SidebarProfileAttentionSummary.compute(
            signedInAccounts: [active, secondary, third],
            activeAccountId: active.id,
            unreadCountForAccountIdHex: { countsByHex[$0] }
        )

        #expect(summary.backgroundUnreadCount == 7)
        #expect(summary.unreadCount(for: active) == 12)
        #expect(summary.unreadCount(for: secondary) == 4)
        #expect(summary.unreadCount(for: third) == 3)

        #expect(SidebarAccountMenuFormatting.menuTitle(displayName: "Alice", unreadCount: 0) == "Alice")
        #expect(SidebarAccountMenuFormatting.menuTitle(displayName: "Bob", unreadCount: 4) == "Bob (4)")
        #expect(SidebarAccountMenuFormatting.menuTitle(displayName: "Carol", unreadCount: 142) == "Carol (99+)")
    }

    // MARK: - #1038: Conversation toolbar action safety and permission gating

    @MainActor
    @Test func messengerCommandContextRejectsStaleAccountOrChat() {
        let workspace = WorkspaceState.preview()
        guard let activeAccountId = workspace.activeAccountId,
            let selectedChat = workspace.selectedChat
        else {
            Issue.record("Expected preview workspace to have an active account and selected chat")
            return
        }

        let currentContext = MessengerCommandContext(
            workspace: workspace,
            accountID: activeAccountId,
            isMessengerWindowTarget: { true }
        )
        #expect(currentContext.activeChat(matching: selectedChat.id)?.id == selectedChat.id)
        #expect(currentContext.activeChat(matching: "different-chat") == nil)

        let staleAccountContext = MessengerCommandContext(
            workspace: workspace,
            accountID: "stale-account",
            isMessengerWindowTarget: { true }
        )
        #expect(staleAccountContext.activeChat(matching: selectedChat.id) == nil)
    }

    @Test func setGroupImageVisibilityRequiresActiveGroupWithComposerAccess() {
        let activeGroup = ChatItem(
            id: "g1",
            title: "Design",
            subtitle: "3 members",
            preview: "Hi",
            updatedAt: nil,
            avatarSeed: "g1",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: false
        )
        let directChat = ChatItem(
            id: "dm1",
            title: "Alice",
            subtitle: "Direct message",
            preview: "Hi",
            updatedAt: nil,
            avatarSeed: "dm1",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true
        )
        let pendingGroup = ChatItem(
            id: "g2",
            title: "Invite",
            subtitle: "2 members",
            preview: "",
            updatedAt: nil,
            avatarSeed: "g2",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: false,
            pendingConfirmation: true
        )
        let leftGroup = ChatItem(
            id: "g3",
            title: "Old",
            subtitle: "2 members",
            preview: "",
            updatedAt: nil,
            avatarSeed: "g3",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: false,
            selfMembership: .left
        )

        let adminMetadata = ConversationMetadata(memberCount: 3, disappearingMessageSecs: 0, isSelfAdmin: true)
        let memberMetadata = ConversationMetadata(memberCount: 3, disappearingMessageSecs: 0, isSelfAdmin: false)

        #expect(ConversationToolbarEligibility.canSetGroupImage(for: activeGroup, metadata: adminMetadata))
        #expect(!ConversationToolbarEligibility.canSetGroupImage(for: activeGroup, metadata: memberMetadata))
        #expect(!ConversationToolbarEligibility.canSetGroupImage(for: directChat, metadata: adminMetadata))
        #expect(!ConversationToolbarEligibility.canSetGroupImage(for: pendingGroup, metadata: adminMetadata))
        #expect(!ConversationToolbarEligibility.canSetGroupImage(for: leftGroup, metadata: adminMetadata))
    }

    @MainActor
    @Test func composerAutoFocusPreservesSidebarTableFocusForArrowNavigation() {
        let sidebarTable = NSTableView()
        let transcriptTable = NSTableView()
        transcriptTable.setAccessibilityIdentifier("conversation.transcript")

        #expect(!ChatListRowClickPolicy.shouldFocusComposerOnChatOpen(firstResponder: sidebarTable))
        #expect(ChatListRowClickPolicy.shouldFocusComposerOnChatOpen(firstResponder: transcriptTable))
        #expect(ChatListRowClickPolicy.shouldFocusComposerOnChatOpen(firstResponder: nil))
    }

    // MARK: - #1112: Persistent notices, security warnings, and empty states

    @Test func deviceWarningSummaryReflectsEachPersistentWarning() {
        let clean = AccountDeviceWarningSummary.from(
            compromiseItems: [],
            deviceGroupStalled: false,
            keyPackageRefreshOverdue: false
        )
        #expect(!clean.hasWarnings)

        let stalled = AccountDeviceWarningSummary.from(
            compromiseItems: [],
            deviceGroupStalled: true,
            keyPackageRefreshOverdue: false
        )
        #expect(stalled.hasWarnings)
        #expect(stalled.isDeviceGroupStalled)

        let overdue = AccountDeviceWarningSummary.from(
            compromiseItems: [],
            deviceGroupStalled: false,
            keyPackageRefreshOverdue: true
        )
        #expect(overdue.hasWarnings)
        #expect(overdue.isKeyPackageRefreshOverdue)
    }

    @MainActor
    @Test func renderingNoticesNeverAutoAcknowledgesHistoryOrSecurityWarnings() {
        let historyNotices = HistoryNoticesViewModel.preview(notices: [
            HistoryNoticeFfi(noticeId: "loss-1", cause: .deliveryLoss, groupIdHex: nil, parkedAtMs: nil)
        ])
        let deviceLinking = DeviceLinkingViewModel.preview(
            compromiseItems: [
                CompromiseWarningItemFfi(
                    reason: .rejectedSignIn,
                    slotIdHex: String(repeating: "a", count: 64),
                    keyPackageRefHex: nil,
                    occurredAt: 1_700_000_000
                )
            ]
        )

        assertNonZeroLayout(AccountHistoryNoticesView(model: historyNotices), width: 300)
        assertNonZeroLayout(
            AccountDeviceWarningsBanner(model: deviceLinking, onOpenDevicesSettings: {}),
            width: 300
        )

        #expect(historyNotices.accountNotices.map(\.noticeId) == ["loss-1"])
        #expect(deviceLinking.compromiseItems.count == 1)
    }

    @MainActor
    @Test func compactSecurityBannerBoundsHeightWithManyCompromiseRecords() {
        let manyRecords = (0..<12).map { index in
            "Unrecognized sign-in record #\(index) with detailed audit context that would otherwise crowd the sidebar."
        }
        let banner = AccountDeviceWarningsBannerContent(
            summary: AccountDeviceWarningSummary(
                compromiseMessages: manyRecords,
                isDeviceGroupStalled: true,
                isKeyPackageRefreshOverdue: true
            ),
            onReview: {}
        )
        let host = NSHostingView(rootView: banner.frame(width: 260))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
        #expect(host.fittingSize.height < 180)
    }

    @MainActor
    @Test func mainWindowSurfacesLayoutCleanlyAtDesktopAndNarrowWidths() {
        let workspace = WorkspaceState.preview()
        let session = SessionState()

        assertNonZeroLayout(
            SidebarProfileSwitcherView(
                signedInAccounts: workspace.signedInAccounts,
                activeAccount: workspace.activeAccount,
                isAccountMutationInProgress: false,
                attentionModel: nil,
                onSelectAccount: { _ in },
                onAddProfile: {},
                onOpenSettings: {}
            )
            .environment(workspace),
            width: 240
        )
        assertNonZeroLayout(
            ConversationToolbarIdentity(
                chat: ChatItem.samples[0],
                metadata: ConversationMetadata(memberCount: 4, disappearingMessageSecs: 86_400, isSelfAdmin: true),
                isCatchingUp: false
            )
            .environment(workspace),
            width: 220
        )
        assertNonZeroLayout(OfflineNoticeBand(), width: 420)
        assertNonZeroLayout(
            BackgroundStatusBannerContent(status: "Relay unavailable", onDismiss: {}),
            width: 420
        )
        assertNonZeroLayout(
            PendingGroupInviteComposerNotice(chat: ChatItem.samples[0])
                .environment(workspace)
                .environment(session),
            width: 460
        )
        assertNonZeroLayout(MembershipEndedComposerNotice(membership: .left), width: 460)
        assertNonZeroLayout(GroupLifecycleComposerNotice(lifecycle: .ended), width: 460)
        assertNonZeroLayout(
            BlockedLeaveNotice(canCancel: true, isCancelling: false, failure: nil, onCancel: {}),
            width: 460
        )
        assertNonZeroLayout(BlockedConversationComposerNotice(), width: 460)
        assertNonZeroLayout(
            WNEmptyStateView(
                title: L10n.string("No matching chats"),
                systemImage: "magnifyingglass"
            ),
            width: 260
        )
    }

    @MainActor
    private func assertNonZeroLayout<Content: View>(_ view: Content, width: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
    }
}
