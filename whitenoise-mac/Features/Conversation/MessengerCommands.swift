import AppKit
import SwiftUI

/// Commands are published by the main messenger scene. Capture the owning account and revalidate
/// it against the live workspace at invocation, including after a command starts an async task.
struct MessengerCommandContext {
    let workspace: WorkspaceState
    let accountID: String
    var selectedConversation: () -> ConversationViewModel? = { nil }

    let isMessengerWindowTarget: () -> Bool

    var isAvailable: Bool {
        workspace.showsMessengerChrome && workspace.activeAccountId == accountID && isMessengerWindowTarget()
    }

    static func acceptsCommandsInKeyWindow() -> Bool {
        acceptsCommands(
            keyWindow: NSApp.keyWindow,
            messengerWindow: ConversationWindowIdentity.window,
            modalWindow: NSApp.modalWindow
        )
    }

    static func acceptsCommands(keyWindow: NSWindow?, messengerWindow: NSWindow?, modalWindow: NSWindow?) -> Bool {
        guard let keyWindow else { return false }
        return keyWindow === messengerWindow && keyWindow.attachedSheet == nil && modalWindow == nil
    }

    func activeChat(matching chatID: String) -> ChatItem? {
        guard isAvailable, let chat = workspace.selectedChat, chat.id == chatID else { return nil }
        return chat
    }

    func newChat() {
        guard isAvailable, !workspace.isNewChatComposerVisible else { return }
        workspace.showNewChat()
    }

    func searchAllMessages() {
        guard isAvailable else { return }
        workspace.presentGlobalMessageSearch()
    }
}

extension FocusedValues {
    @Entry var messengerCommands: MessengerCommandContext?
    @Entry var sidebarSearchFocus: SidebarSearchFocus?
}

struct SidebarSearchFocus {
    let request: () -> Void
}

struct MessengerCommands: Commands {
    @FocusedValue(\.messengerCommands) private var messenger
    @FocusedValue(\.conversationSearch) private var conversation
    @FocusedValue(\.sidebarSearchFocus) private var sidebarSearchFocus
    let locale: Locale
    let endingGroupIDs: Set<String>

    private var canUseMessenger: Bool { messenger?.isAvailable == true }
    private var canUseConversation: Bool {
        guard let conversation, let messenger, conversation.accountID == messenger.accountID else { return false }
        return messenger.activeChat(matching: conversation.chatID) != nil
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.string("New Chat…", locale: locale)) {
                messenger?.newChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!canUseMessenger || messenger?.workspace.isNewChatComposerVisible == true)
        }
        CommandGroup(after: .textEditing) {
            Menu(L10n.string("Find", locale: locale)) {
                Button(L10n.string("Find in Conversation…", locale: locale)) {
                    guard canUseConversation else { return }
                    conversation?.open()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!canUseConversation)

                Button(L10n.string("Find Next", locale: locale)) {
                    guard canUseConversation else { return }
                    conversation?.model.goToOlderMatch()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!canUseConversation || conversation?.model.canStep != true)

                Button(L10n.string("Find Previous", locale: locale)) {
                    guard canUseConversation else { return }
                    conversation?.model.goToNewerMatch()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!canUseConversation || conversation?.model.canStep != true)

                Divider()

                Button(L10n.string("Search All Messages…", locale: locale)) {
                    messenger?.searchAllMessages()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!canUseMessenger)

                Button(L10n.string("Focus Sidebar Search", locale: locale)) {
                    guard canUseMessenger, messenger?.workspace.isChatListVisible == true else { return }
                    sidebarSearchFocus?.request()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(
                    !canUseMessenger || messenger?.workspace.isChatListVisible != true || sidebarSearchFocus == nil)
            }
        }
        SidebarCommands()
        CommandMenu(L10n.string("Conversation", locale: locale)) {
            if let messenger, let conversation, conversation.accountID == messenger.accountID,
                let chat = messenger.activeChat(matching: conversation.chatID)
            {
                ConversationMenuItems(
                    messenger: messenger,
                    conversation: messenger.selectedConversation(),
                    chat: chat,
                    locale: locale,
                    endingGroupIDs: endingGroupIDs
                )
            } else {
                Button(L10n.string("Mute", locale: locale)) {}.disabled(true)
                Button(L10n.string("Archive", locale: locale)) {}.disabled(true)
                Button(L10n.string("Mark as Unread", locale: locale)) {}.disabled(true)
                Button(L10n.string("Show Chat Info", locale: locale)) {}.disabled(true)
            }
        }
    }
}

/// Which read-state action the Conversation menu offers for the active chat.
enum ConversationUnreadMenuAction: Equatable {
    case markRead
    case clearUnreadReminder
    case markUnread

    var titleKey: String {
        switch self {
        case .markRead: "Mark as Read"
        case .clearUnreadReminder: ChatRowMenuAction.clearUnread.titleKey
        case .markUnread: ChatRowMenuAction.markUnread.titleKey
        }
    }

    static func resolve(for chat: ChatItem) -> Self {
        if chat.unreadCount > 0 {
            return .markRead
        }
        return chat.manuallyMarkedUnread ? .clearUnreadReminder : .markUnread
    }

    static func isEnabled(
        action: Self,
        canChangePreferences: Bool,
        hasConversationSnapshot: Bool
    ) -> Bool {
        guard canChangePreferences else { return false }
        switch action {
        case .markRead:
            return hasConversationSnapshot
        case .clearUnreadReminder, .markUnread:
            return true
        }
    }
}

private struct ConversationMenuItems: View {
    let messenger: MessengerCommandContext
    let conversation: ConversationViewModel?
    let chat: ChatItem
    let locale: Locale

    var body: some View {
        let workspace = messenger.workspace
        let actions = ChatMenuActions(workspace: workspace, chat: chat)
        let isArchived = workspace.archivedChatItem(accountId: messenger.accountID, chatId: chat.id) != nil
        let unreadAction = ConversationUnreadMenuAction.resolve(for: chat)

        ChatMuteMenu(actions: actions, locale: locale, isCurrent: isCurrent)

        Button(L10n.string(isArchived ? "Unarchive" : "Archive", locale: locale)) {
            Task {
                guard isCurrent() else { return }
                await actions.setArchived(!isArchived)
            }
        }
        .disabled(!actions.canArchive)

        Button(L10n.string(unreadAction.titleKey, locale: locale)) {
            Task {
                guard isCurrent() else { return }
                switch unreadAction {
                case .markRead:
                    guard let conversation else { return }
                    await actions.markAsRead(conversation: conversation)
                case .clearUnreadReminder:
                    await workspace.setChatManuallyUnread(chat, manuallyUnread: false)
                case .markUnread:
                    await workspace.setChatManuallyUnread(chat, manuallyUnread: true)
                }
            }
        }
        .disabled(
            !ConversationUnreadMenuAction.isEnabled(
                action: unreadAction,
                canChangePreferences: actions.canChangePreferences,
                hasConversationSnapshot: conversation?.snapshot != nil
            )
        )

        Button(L10n.string("Show Chat Info", locale: locale)) {
            Task {
                guard isCurrent() else { return }
                await workspace.showGroupDetails(for: chat)
            }
        }
        .disabled(workspace.isTimelineSelectionMode)

        if let destructive = ChatDestructiveActions.action(for: chat) {
            Divider()
            let item: ChatRowMenuAction = destructive == .leave ? .leave : .deleteLocally
            Button(L10n.string(item.titleKey, locale: locale), role: .destructive) {
                switch destructive {
                case .deleteLocally:
                    guard isCurrent() else { return }
                    actions.requestDeleteLocally(endingGroupIDs: endingGroupIDs)
                case .leave:
                    Task {
                        guard isCurrent() else { return }
                        await actions.requestLeave(endingGroupIDs: endingGroupIDs)
                    }
                }
            }
            .disabled(!actions.canPerformDestructive(destructive, endingGroupIDs: endingGroupIDs))
        }
    }

    let endingGroupIDs: Set<String>

    private func isCurrent() -> Bool {
        messenger.activeChat(matching: chat.id) != nil
    }
}

#Preview("Conversation menu commands") {
    let workspace = WorkspaceState.preview()
    if let accountID = workspace.activeAccountId, let chat = workspace.selectedChat {
        VStack {
            ConversationMenuItems(
                messenger: MessengerCommandContext(
                    workspace: workspace, accountID: accountID, isMessengerWindowTarget: { true }),
                conversation: nil, chat: chat, locale: .current, endingGroupIDs: []
            )
        }
        .padding()
    }
}
