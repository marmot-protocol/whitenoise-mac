import Foundation

/// Custom emoji reactions this device is still sending, drawn on their message at once.
///
/// An ordinary emoji reaction is one local call, so the conversation window carries it almost as
/// soon as it is picked. A custom one first uploads its image to the chat's media server, which
/// takes seconds; without this the chip only appeared after that round trip. As on iOS, the pick
/// shows straight away and the window's own reaction takes over once it carries one.
nonisolated enum PendingCustomEmojiReactions {
    /// `reactions` with each pending emoji the account does not hold yet counted in as its own.
    /// One the window already lists as the account's is left alone, so nothing is counted twice
    /// while the send finishes.
    static func merge(_ reactions: [MessageReaction], pending: [CustomEmojiSendable]) -> [MessageReaction] {
        var merged = reactions
        for emoji in pending {
            let token = emoji.token
            if let index = merged.firstIndex(where: { $0.emoji == token }) {
                let existing = merged[index]
                guard !existing.isOwn else { continue }
                merged[index] = MessageReaction(
                    emoji: token, count: existing.count + 1, isOwn: true, senders: existing.senders,
                    reactionMessageIdHex: existing.reactionMessageIdHex)
            } else {
                merged.append(MessageReaction(emoji: token, count: 1, isOwn: true))
            }
        }
        return merged
    }
}
