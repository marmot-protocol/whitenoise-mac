import SwiftUI

/// The transcript publishes its own search handlers, preserving its exclusions and scroll routing.
struct ConversationSearchCommand {
    let accountID: String
    let chatID: String
    let model: ConversationSearchViewModel
    let open: () -> Void
    /// Monotonic token incremented on responder/selection changes so SwiftUI menu validation
    /// re-evaluates `selectedTextForFind()` without caching stale text across focus changes.
    var selectionRevision: Int = 0
    /// Live transcript-scoped selected-text reader invoked for both `⌘E` enablement and action.
    var selectedTextForFind: () -> String? = { nil }
    var useSelectionForFind: (String) -> Void = { _ in }
}

extension FocusedValues {
    @Entry var conversationSearch: ConversationSearchCommand?
}
