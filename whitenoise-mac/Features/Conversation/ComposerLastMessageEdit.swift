import Foundation

/// A key the composer's text view hands up for message editing: Up in an empty composer edits
/// the user's latest message (as in Slack and IRC clients), and Escape abandons an edit.
nonisolated enum ComposerEditCommand: Equatable {
    case editLastMessage
    case cancelEdit
}

/// Which message Up in an empty composer opens for editing.
enum ComposerLastMessageEdit {
    /// The newest of the user's own messages that can be edited, or nil when there is none.
    ///
    /// `messages` is the loaded transcript, oldest first. When the window does not reach the
    /// conversation's newest message (`hasMoreAfter`) its last own message is not the user's
    /// latest, so nothing is offered rather than reopening something old.
    static func target(in messages: [MessageItem], paging: TimelinePagingState) -> MessageItem? {
        guard !paging.hasMoreAfter else { return nil }
        return messages.last { $0.isOutgoing && $0.canEdit }
    }
}
