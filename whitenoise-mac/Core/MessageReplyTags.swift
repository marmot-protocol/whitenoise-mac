import Foundation

/// The tags that make a message a reply, written the way MDK's own replies write them: an `e` row
/// and a `q` row, both naming the message being answered.
///
/// For sends that take raw tags rather than a reply target — media uploads (MarmotKit 0.16.0 keeps
/// the reply target named by these on a `send: true` upload) and custom-emoji messages. A malformed
/// or conflicting target is refused by MDK before anything uploads.
nonisolated enum MessageReplyTags {
    static let eventRef = "e"
    static let quoteRef = "q"

    static func tags(replyingTo targetMessageId: String?) -> [[String]] {
        guard let targetMessageId, !targetMessageId.isEmpty else { return [] }
        return [[eventRef, targetMessageId], [quoteRef, targetMessageId]]
    }
}
