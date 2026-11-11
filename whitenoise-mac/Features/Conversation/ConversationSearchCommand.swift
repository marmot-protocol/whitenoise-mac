import SwiftUI

/// The selected conversation's "Find in Conversation" action. `ConversationView` publishes it as a
/// focused scene value, so the Navigate menu reaches the conversation on screen without going
/// through `WorkspaceState`, and finds nothing when no conversation is showing.
struct ConversationSearchCommand {
    let open: () -> Void
}

extension FocusedValues {
    @Entry var conversationSearch: ConversationSearchCommand?
}

/// Navigate ▸ Find in Conversation… (⌘F). A menu item rather than a shortcut on the header button,
/// so it is discoverable and owns ⌘F wherever focus sits in the window, the composer included.
struct FindInConversationMenuButton: View {
    @FocusedValue(\.conversationSearch) private var conversationSearch

    var body: some View {
        Button(L10n.string("Find in Conversation…")) {
            conversationSearch?.open()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(conversationSearch == nil)
    }
}

#Preview("Find in Conversation menu item") {
    FindInConversationMenuButton()
        .focusedSceneValue(\.conversationSearch, ConversationSearchCommand(open: {}))
        .padding()
}
