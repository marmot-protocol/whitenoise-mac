import MarmotKit
import SwiftUI

/// Actions offered by the chat row context menu.
nonisolated enum ChatRowMenuAction: String, CaseIterable, Identifiable, Sendable {
    case markUnread
    case clearUnread
    case mute
    case unmute
    case pin
    case unpin
    case archive
    case unarchive
    case leave
    case deleteLocally
    case select

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .markUnread: "message.badge.fill"
        case .clearUnread: "message.fill"
        case .mute: "bell.slash.fill"
        case .unmute: "bell.fill"
        case .pin: "pin.fill"
        case .unpin: "pin.slash.fill"
        case .archive: "archivebox.fill"
        case .unarchive: "tray.and.arrow.up.fill"
        case .leave: "rectangle.portrait.and.arrow.right"
        case .deleteLocally: "trash.fill"
        case .select: "checkmark.circle"
        }
    }

    var titleKey: String {
        switch self {
        case .markUnread: "Mark as Unread"
        case .clearUnread: "Clear Unread Reminder"
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .pin: "Pin to Top"
        case .unpin: "Unpin"
        case .archive: "Archive"
        case .unarchive: "Unarchive"
        case .leave: "Leave Chat"
        case .deleteLocally: "Delete From This Device"
        case .select: "Select"
        }
    }
}

struct ChatRowMenuLabel: View {
    let action: ChatRowMenuAction

    var body: some View {
        Label(L10n.string(action.titleKey), systemImage: action.systemImage)
    }
}

#Preview("ChatRowMenuLabel") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(ChatRowMenuAction.allCases) { action in
            ChatRowMenuLabel(action: action)
                .labelStyle(.titleAndIcon)
        }
    }
    .padding()
}

/// Shared account and chat operations for the clicked row and the selected conversation.
struct ChatMenuActions {
    let workspace: WorkspaceState
    let chat: ChatItem

    var canChangePreferences: Bool { !workspace.isMutatingChatPreferences(chat) }
    var canArchive: Bool { workspace.archivingChatId == nil }

    func setArchived(_ archived: Bool) async {
        guard canArchive else { return }
        await workspace.setChatArchived(chat, archived: archived)
    }

    func canPerformDestructive(_ action: ChatDestructiveActions.Action, endingGroupIDs: Set<String>) -> Bool {
        switch action {
        case .leave:
            workspace.leavingChatId == nil
                && workspace.preparingChatLeaveId == nil
                && workspace.handingOffAdminChatId == nil
                && !endingGroupIDs.contains(chat.id)
        case .deleteLocally:
            !workspace.isDeletingGroupLocally
        }
    }

    func requestDeleteLocally(endingGroupIDs: Set<String>) {
        guard canPerformDestructive(.deleteLocally, endingGroupIDs: endingGroupIDs) else { return }
        workspace.requestChatLocalDelete(for: chat)
    }

    func requestLeave(endingGroupIDs: Set<String>) async {
        guard canPerformDestructive(.leave, endingGroupIDs: endingGroupIDs) else { return }
        await workspace.prepareChatLeave(for: chat)
    }

    /// Explicitly marks `chat` as read from the Conversation menu using `conversation`'s
    /// authoritative tail snapshot, advancing MDK's read position and clearing any manual unread
    /// reminder. Surfaces fetch and commit failures in the messenger's status banner.
    func markAsRead(conversation: ConversationViewModel) async {
        guard let client = workspace.client,
            let activeAccount = workspace.activeAccount,
            canChangePreferences
        else { return }
        let accountId = activeAccount.id
        workspace.mutatingChatPreferenceIds.insert(chat.id)
        defer { workspace.mutatingChatPreferenceIds.remove(chat.id) }
        do {
            if conversation.snapshot?.hasMoreAfter == true {
                await conversation.returnToLatest()
                guard workspace.activeAccountId == accountId else { return }
            }
            guard let snapshot = conversation.snapshot, !snapshot.hasMoreAfter else {
                let message: String? =
                    switch conversation.error {
                    case .unavailable(let text):
                        text
                    case .staleWindow:
                        UserFacingError.message(for: MarmotKitError.ConversationWindowStale)
                    case nil:
                        nil
                    }
                if let message {
                    workspace.setBackgroundStatus(message)
                }
                return
            }

            let marker = snapshot.latestReadableActivityMarker(inAuthoritativeGroup: chat.isAuthoritativeGroup)
            var updatedRow: ChatListRowFfi?
            if let marker {
                updatedRow = try await workspace.commitReadMarker(
                    marker,
                    groupIdHex: chat.id,
                    account: activeAccount,
                    client: client
                )
                guard workspace.activeAccountId == accountId else { return }
            }

            if chat.manuallyMarkedUnread {
                let row = try await FFIExecutor.run {
                    try client.setChatManuallyUnread(
                        accountRef: activeAccount.accountRef,
                        groupIdHex: chat.id,
                        manuallyUnread: false
                    )
                }
                guard workspace.activeAccountId == accountId else { return }
                updatedRow = row ?? updatedRow
            }

            if let updatedRow {
                await workspace.applyChatRow(updatedRow, account: activeAccount, shouldEnrich: false)
            } else {
                await workspace.reloadChats(forceFreshSnapshot: true)
            }
        } catch {
            guard workspace.activeAccountId == accountId else { return }
            workspace.setBackgroundStatus(UserFacingError.message(for: error))
        }
    }
}

struct ChatMuteMenu: View {
    let actions: ChatMenuActions
    let locale: Locale
    var showsRowIcon = false
    let isCurrent: () -> Bool

    var body: some View {
        Group {
            if actions.chat.muted {
                Button {
                    Task {
                        guard isCurrent() else { return }
                        await actions.workspace.clearChatMuted(actions.chat)
                    }
                } label: {
                    label(.unmute)
                }
            } else {
                Menu {
                    ForEach(ChatMuteDuration.allCases) { duration in
                        Button {
                            Task {
                                guard isCurrent() else { return }
                                await actions.workspace.setChatMuted(actions.chat, duration: duration.interval)
                            }
                        } label: {
                            Label(L10n.string(duration.titleKey, locale: locale), systemImage: duration.systemImage)
                        }
                    }
                } label: {
                    label(.mute)
                }
            }
        }
        .disabled(!actions.canChangePreferences)
    }

    @ViewBuilder
    private func label(_ action: ChatRowMenuAction) -> some View {
        if showsRowIcon {
            ChatRowMenuLabel(action: action)
        } else {
            Text(L10n.string(action.titleKey, locale: locale))
        }
    }
}

#Preview("Mute commands") {
    ChatMuteMenu(
        actions: ChatMenuActions(workspace: .preview(), chat: ChatItem.samples[0]),
        locale: .current, isCurrent: { true }
    )
}
