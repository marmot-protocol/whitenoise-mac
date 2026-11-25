import AppKit
import Foundation
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

struct MainWindowSurfacesTests: WorkspaceTestSupport {

    // MARK: - #1037: Chat list filters, click/selection routing, and profile switcher

    @Test func chatListFiltersExposeOnlyTheFiveRealFilters() {
        #expect(ChatListFilter.allCases == [.active, .unread, .invites, .archived, .left])
    }

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

    @Test func nativeListSelectionNeverOverridesBatchSelectionOrBlanksOpenChat() {
        #expect(
            !ChatListRowClickPolicy.shouldApplyNativeListSelection(
                newId: "other-chat",
                currentOpenChatId: "open-chat",
                isBatchSelectionActive: true
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

    @Test func conversationToolbarGuardRejectsStaleAccountOrChat() {
        let actionGuard = ConversationToolbarActionGuard(
            originAccountId: "acct-a",
            originChatId: "chat-1"
        )

        #expect(actionGuard.matches(activeAccountId: "acct-a", selectedChatId: "chat-1"))
        #expect(!actionGuard.matches(activeAccountId: "acct-b", selectedChatId: "chat-1"))
        #expect(!actionGuard.matches(activeAccountId: "acct-a", selectedChatId: "chat-2"))
        #expect(!actionGuard.matches(activeAccountId: nil, selectedChatId: "chat-1"))
        #expect(!actionGuard.matches(activeAccountId: "acct-a", selectedChatId: nil))
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

        #expect(ConversationToolbarActionGuard.canSetGroupImage(for: activeGroup))
        #expect(!ConversationToolbarActionGuard.canSetGroupImage(for: directChat))
        #expect(!ConversationToolbarActionGuard.canSetGroupImage(for: pendingGroup))
        #expect(!ConversationToolbarActionGuard.canSetGroupImage(for: leftGroup))
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

        hostForLayout(AccountHistoryNoticesView(model: historyNotices), width: 300)
        hostForLayout(
            AccountDeviceWarningsBanner(model: deviceLinking, onOpenDevicesSettings: {}),
            width: 300
        )

        #expect(historyNotices.accountNotices.map(\.noticeId) == ["loss-1"])
        #expect(deviceLinking.compromiseItems.count == 1)
    }

    @MainActor
    @Test func mainWindowSurfacesRenderCleanlyAtDesktopAndNarrowWidths() {
        let workspace = WorkspaceState.preview()
        let session = SessionState()

        hostForLayout(
            SidebarProfileSwitcherView(attentionModel: nil, onOpenSettings: {})
                .environment(workspace),
            width: 240
        )
        hostForLayout(
            ConversationToolbarIdentity(
                chat: ChatItem.samples[0],
                metadata: ConversationMetadata(memberCount: 4, disappearingMessageSecs: 86_400, isSelfAdmin: true),
                isCatchingUp: false
            ),
            width: 220
        )
        hostForLayout(
            ConversationToolbarIdentity(
                chat: ChatItem.samples[0],
                metadata: nil,
                isCatchingUp: true
            ),
            width: 220
        )
        hostForLayout(OfflineNoticeBand(), width: 420)
        hostForLayout(
            BackgroundStatusBannerContent(status: "Relay unavailable", onDismiss: {}),
            width: 420
        )
        hostForLayout(
            PendingGroupInviteComposerNotice(chat: ChatItem.samples[0])
                .environment(workspace)
                .environment(session),
            width: 460
        )
        hostForLayout(MembershipEndedComposerNotice(membership: .left), width: 460)
        hostForLayout(GroupLifecycleComposerNotice(lifecycle: .ended), width: 460)
        hostForLayout(
            BlockedLeaveNotice(canCancel: true, isCancelling: false, failure: nil, onCancel: {}),
            width: 460
        )
        hostForLayout(BlockedConversationComposerNotice(), width: 460)
        hostForLayout(
            WNEmptyStateView(
                title: L10n.string("No matching chats"),
                systemImage: "magnifyingglass"
            ),
            width: 260
        )
    }

    @MainActor
    private func hostForLayout<Content: View>(_ view: Content, width: CGFloat) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width >= 0)
        #expect(host.fittingSize.height >= 0)
    }
}
