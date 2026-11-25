import AppKit
import MarmotKit
import SwiftUI

/// Commands are published by the main messenger scene. Capture the owning account and revalidate
/// it against the live workspace at invocation, including after a command starts an async task.
struct MessengerCommandContext {
    let workspace: WorkspaceState
    let accountID: String
    var selectedConversation: () -> ConversationViewModel? = { nil }
    var onSearchAllMessages: () -> Void = {}

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
        onSearchAllMessages()
    }
}

/// Pure eligibility and routing policy for Edit › Find commands (K01, K04, N09, #1042, #1043).
/// Kept out of the SwiftUI `Commands` body so unit tests can assert enablement and direction
/// directly without driving AppKit menus.
@MainActor
enum ConversationFindCommandPolicy {
    static func canUseConversation(
        messenger: MessengerCommandContext?,
        conversation: ConversationSearchCommand?
    ) -> Bool {
        guard let conversation, let messenger, conversation.accountID == messenger.accountID else {
            return false
        }
        // Details now live in a native trailing `.inspector` beside the transcript rather than
        // overlaying it, so Find (`⌘F` / `⌘G` / `⇧⌘G` / `⌘E`) stays available while Chat Info is open.
        return messenger.activeChat(matching: conversation.chatID) != nil
    }

    static func canFindNext(
        messenger: MessengerCommandContext?,
        conversation: ConversationSearchCommand?
    ) -> Bool {
        canUseConversation(messenger: messenger, conversation: conversation)
            && conversation?.model.canGoToNewerMatch == true
    }

    static func canFindPrevious(
        messenger: MessengerCommandContext?,
        conversation: ConversationSearchCommand?
    ) -> Bool {
        canUseConversation(messenger: messenger, conversation: conversation)
            && conversation?.model.canGoToOlderMatch == true
    }

    static func selectedQueryForFind(
        messenger: MessengerCommandContext?,
        conversation: ConversationSearchCommand?
    ) -> String? {
        guard canUseConversation(messenger: messenger, conversation: conversation), let conversation else {
            return nil
        }
        return conversation.selectedText ?? conversation.selectedTextForFind()
    }

    static func findNext(
        messenger: MessengerCommandContext?,
        conversation: ConversationSearchCommand?
    ) {
        guard canFindNext(messenger: messenger, conversation: conversation) else { return }
        conversation?.model.goToNewerMatch()
    }

    static func findPrevious(
        messenger: MessengerCommandContext?,
        conversation: ConversationSearchCommand?
    ) {
        guard canFindPrevious(messenger: messenger, conversation: conversation) else { return }
        conversation?.model.goToOlderMatch()
    }

    static func useSelectionForFind(
        messenger: MessengerCommandContext?,
        conversation: ConversationSearchCommand?
    ) {
        guard canUseConversation(messenger: messenger, conversation: conversation),
            let conversation,
            let query = conversation.selectedTextForFind() ?? conversation.selectedText
        else { return }
        conversation.useSelectionForFind(query)
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
        ConversationFindCommandPolicy.canUseConversation(messenger: messenger, conversation: conversation)
    }
    private var canFindNext: Bool {
        ConversationFindCommandPolicy.canFindNext(messenger: messenger, conversation: conversation)
    }
    private var canFindPrevious: Bool {
        ConversationFindCommandPolicy.canFindPrevious(messenger: messenger, conversation: conversation)
    }
    private var canUseSelectionForFind: Bool {
        ConversationFindCommandPolicy.selectedQueryForFind(messenger: messenger, conversation: conversation) != nil
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
                    ConversationFindCommandPolicy.findNext(messenger: messenger, conversation: conversation)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!canFindNext)

                Button(L10n.string("Find Previous", locale: locale)) {
                    ConversationFindCommandPolicy.findPrevious(messenger: messenger, conversation: conversation)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!canFindPrevious)

                Button(L10n.string("Use Selection for Find", locale: locale)) {
                    ConversationFindCommandPolicy.useSelectionForFind(
                        messenger: messenger,
                        conversation: conversation
                    )
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!canUseSelectionForFind)

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
        InspectorCommands()
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

struct ConversationMenuItems: View {
    let messenger: MessengerCommandContext
    let conversation: ConversationViewModel?
    let chat: ChatItem
    let locale: Locale
    let endingGroupIDs: Set<String>
    var onSetGroupImage: (() -> Void)? = nil

    var body: some View {
        let workspace = messenger.workspace
        let actions = ChatMenuActions(workspace: workspace, chat: chat)
        let isArchived = workspace.archivedChatItem(accountId: messenger.accountID, chatId: chat.id) != nil
        let unreadAction = ConversationUnreadMenuAction.resolve(for: chat)

        let capabilities = conversation?.snapshot?.header.capabilities
        let metadata = workspace.conversationMetadataByChat[chat.id]
        if let onSetGroupImage,
            ConversationToolbarEligibility.canSetGroupImage(
                for: chat,
                capabilities: capabilities,
                metadata: metadata
            )
        {
            Button {
                guard let currentChat = messenger.activeChat(matching: chat.id),
                    ConversationToolbarEligibility.canSetGroupImage(
                        for: currentChat,
                        capabilities: conversation?.snapshot?.header.capabilities,
                        metadata: workspace.conversationMetadataByChat[currentChat.id]
                    )
                else { return }
                onSetGroupImage()
            } label: {
                Label(L10n.string("Set group image", locale: locale), systemImage: "photo.badge.plus")
            }

            Divider()
        }

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

        let isInspectorOpen = workspace.isGroupDetailsPresented || workspace.contactDetailsTarget != nil
        Button(L10n.string(isInspectorOpen ? "Hide Chat Info" : "Show Chat Info", locale: locale)) {
            if isInspectorOpen {
                workspace.closeGroupDetails()
            } else {
                Task {
                    guard isCurrent() else { return }
                    await workspace.showGroupDetails(for: chat)
                }
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
