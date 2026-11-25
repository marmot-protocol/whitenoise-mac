import SwiftUI

/// The transcript publishes its own search handlers, preserving its exclusions and scroll routing.
struct ConversationSearchCommand {
    let accountID: String
    let chatID: String
    let model: ConversationSearchViewModel
    let open: () -> Void
    let readableMessageIDs: () -> Set<String>
}

extension FocusedValues {
    @Entry var conversationSearch: ConversationSearchCommand?
}
