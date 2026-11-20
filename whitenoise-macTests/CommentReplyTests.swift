import MarmotKit
import Testing

@testable import whitenoise_mac

/// NIP-22 comments (kind 1111) from other clients. Since 0.18.0 MDK projects a comment's parent as
/// its reply target and quote, as for a chat reply, so the app draws it as an ordinary reply, one
/// level deep.
struct CommentReplyTests {
    private static let parentId = String(repeating: "a", count: 64)
    private static let commentId = String(repeating: "c", count: 64)

    private static func item(_ record: TimelineMessageRecordFfi) throws -> MessageItem {
        let page = TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false)
        let items = MessageItem.timeline(
            from: page, activeAccountIdHex: "self",
            senderProfiles: ["alice": ChatPeerProfile(accountIdHex: "alice", displayName: "Alice", pictureURL: nil)])
        return try #require(items.first)
    }

    /// A comment reads as a chat bubble quoting the parent MDK names, not as an unsupported row.
    @Test func aCommentReadsAsAReplyQuotingItsParent() throws {
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: Self.parentId, sender: "alice", plaintext: "Lunch at noon?",
            contentTokens: emptyMarkdownDocument(), kind: 9, mediaJson: nil, media: [],
            agentTextStreamJson: nil, deleted: false, invalidationStatus: nil)
        let comment = timelineMessage(
            id: Self.commentId, groupIdHex: "group", sender: "bob", plaintext: "Agreed", kind: 1111,
            tags: [["E", Self.parentId], ["K", "9"], ["e", Self.parentId], ["k", "9"]].map {
                MessageTagFfi(values: $0)
            },
            recordedAt: 2, replyToMessageIdHex: Self.parentId, replyPreview: preview)

        let item = try Self.item(comment)

        #expect(item.presentation == .chat)
        #expect(item.body == "Agreed")
        #expect(item.replyTargetIdHex == Self.parentId)
        #expect(item.replyContext?.senderName == "Alice")
        #expect(item.replyContext?.body == "Lunch at noon?")
    }
}
