import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// NIP-22 thread messages (kind 1111) from other clients. MDK marks each one with `thread` and
/// projects its parent as the reply target and quote, as for a chat reply, so the app draws it as an
/// ordinary reply, one level deep. The app never reads the tags: since 0.19.0 a kind 1111 without
/// `thread` is a custom event, whatever it carries.
struct CommentReplyTests {
    private static let parentId = String(repeating: "a", count: 64)
    private static let commentId = String(repeating: "c", count: 64)
    private static let commentTags = [["E", parentId], ["K", "9"], ["e", parentId], ["k", "9"]]
    private static let placement = TimelineThreadRefFfi(rootMessageIdHex: parentId, parentMessageIdHex: parentId)

    private static func comment(
        thread: TimelineThreadRefFfi? = placement, sender: String = "bob"
    ) -> TimelineMessageRecordFfi {
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: parentId, sender: "alice", plaintext: "Lunch at noon?",
            contentTokens: emptyMarkdownDocument(), kind: 9, mediaJson: nil, media: [],
            deleted: false, invalidationStatus: nil)
        return timelineMessage(
            id: commentId, groupIdHex: "group", sender: sender, plaintext: "Agreed", kind: 1111,
            tags: commentTags.map { MessageTagFfi(values: $0) }, recordedAt: 2, thread: thread,
            replyToMessageIdHex: parentId, replyPreview: preview)
    }

    private static func items(_ record: TimelineMessageRecordFfi) -> [MessageItem] {
        MessageItem.timeline(
            from: TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            activeAccountIdHex: "self",
            senderProfiles: ["alice": ChatPeerProfile(accountIdHex: "alice", displayName: "Alice", pictureURL: nil)])
    }

    /// A thread message reads as a chat bubble quoting the parent MDK names, and its quote opens
    /// that parent.
    @Test func aCommentReadsAsAReplyQuotingItsParent() throws {
        let item = try #require(Self.items(Self.comment()).first)

        #expect(item.presentation == .chat)
        #expect(item.body == "Agreed")
        #expect(item.replyTargetIdHex == Self.parentId)
        #expect(item.replyContext?.targetMessageId == Self.parentId)
        #expect(item.replyContext?.senderName == "Alice")
        #expect(item.replyContext?.body == "Lunch at noon?")
    }

    /// A kind-1111 event MDK leaves without `thread` (no parent, or no NIP-22 marks at all) is
    /// app-defined, even with thread-shaped tags: no bubble, no Edit, and search leaves it out.
    /// An own event, so `canEdit` would hold for a bubble.
    @Test func aKind1111WithoutThreadPlacementStaysAnAppDefinedEvent() throws {
        let unmarked = Self.comment(thread: nil, sender: "self")

        let item = try #require(Self.items(unmarked).first)

        #expect(item.isOutgoing)
        #expect(item.presentation == .unsupported)
        #expect(!item.canEdit)
        #expect(ConversationSearchCorpus.entry(for: unmarked) == nil)
    }

    /// An author's retraction clears a thread message's tags; MDK keeps its `thread`, so the row
    /// stays its author's deleted bubble rather than turning into a centred notice.
    @Test func aRetractedCommentStaysItsAuthorsDeletedBubble() throws {
        let retracted = timelineMessage(
            id: Self.commentId, groupIdHex: "group", sender: "bob", plaintext: "", kind: 1111, tags: [],
            recordedAt: 2, thread: Self.placement, replyToMessageIdHex: Self.parentId, deleted: true)

        let item = try #require(Self.items(retracted).first)

        #expect(item.presentation == .chat)
        #expect(item.isDeleted)
        #expect(item.senderAccountIdHex == "bob")
    }

    /// An inline reply to a thread message quotes its text: the preview carries the target's
    /// `thread`, so the quote is a message, not an unsupported event.
    @Test func anInlineReplyQuotesAThreadMessage() throws {
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: Self.commentId, sender: "alice", plaintext: "Agreed",
            contentTokens: emptyMarkdownDocument(), kind: 1111, mediaJson: nil, media: [],
            replyToMessageIdHex: Self.parentId, thread: Self.placement, deleted: false, invalidationStatus: nil)
        let reply = timelineMessage(
            id: String(repeating: "d", count: 64), groupIdHex: "group", sender: "bob", plaintext: "Same",
            recordedAt: 3, replyToMessageIdHex: Self.commentId, replyPreview: preview)

        let item = try #require(Self.items(reply).first)

        #expect(item.replyContext?.targetMessageId == Self.commentId)
        #expect(item.replyContext?.body == "Agreed")
    }

    /// Search finds a thread message like any message on screen.
    @Test func searchFindsAComment() {
        #expect(ConversationSearchCorpus.entry(for: Self.comment()) != nil)
    }

    /// Since 0.19.0 MDK counts a thread message toward unread and accepts it as the read-marker
    /// target, so reading one marks the chat read up to it.
    @Test func aCommentIsAReadMarkerTarget() throws {
        let item = try #require(Self.items(Self.comment()).first)

        #expect(item.countsAsReadActivity(inAuthoritativeGroup: true))
    }

    /// An author's edit of their thread message applies live, as MDK accepts edits to them.
    @MainActor
    @Test func anAuthorsEditOfACommentAppliesLive() throws {
        let base = MessageItem(
            id: Self.commentId, senderAccountIdHex: "bob", senderName: "Bob", body: "Agreed",
            sentAt: Date(timeIntervalSince1970: 2), timelineAt: 2, timelineKind: 1111, isOutgoing: false)
        let edit = timelineMessage(
            id: "edit", groupIdHex: "group", sender: "bob", plaintext: "Agreed, see you there", kind: 1009,
            tags: [MessageTagFfi(values: ["e", Self.commentId])], recordedAt: 3)
        let store = MessageTimelineStore.loaded(with: [base])

        _ = store.applyProjection(
            upserts: [], removals: [], editMutations: MessageEditOverlay.mutations(from: [edit]),
            anchoredToNewest: true, windowLimit: 10)

        #expect(store.lookup[Self.commentId]?.wireBody == "Agreed, see you there")
    }
}
