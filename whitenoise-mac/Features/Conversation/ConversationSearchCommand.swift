import SwiftUI

/// The transcript publishes its own search handlers, preserving its exclusions and scroll routing.
struct ConversationSearchCommand {
    let accountID: String
    let chatID: String
    let model: ConversationSearchViewModel
    let open: () -> Void
    /// Latest selected-text snapshot observed in the focused messenger window, refreshed on text
    /// selection changes so Edit › Find › Use Selection for Find (`⌘E`) updates its enabled state.
    var selectedText: String? = nil
    /// Live selected-text reader invoked when `⌘E` executes so the command always acts on the
    /// current responder selection.
    var selectedTextForFind: () -> String? = { nil }
    var useSelectionForFind: (String) -> Void = { _ in }
}

extension FocusedValues {
    @Entry var conversationSearch: ConversationSearchCommand?
}
