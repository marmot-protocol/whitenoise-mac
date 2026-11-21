import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// NIP-22 comments (kind 1111) from other clients. Since 0.18.0 MDK projects a recognised comment's
/// parent as its reply target and quote, as for a chat reply, so the app draws it as an ordinary
/// reply, one level deep. MDK recognises a comment by a numeric `k` tag; the app uses the same rule.
struct CommentReplyTests {
    private static let parentId = String(repeating: "a", count: 64)
    private static let commentId = String(repeating: "c", count: 64)
    private static let commentTags = [["E", parentId], ["K", "9"], ["e", parentId], ["k", "9"]]

    private static func comment(tags: [[String]] = commentTags) -> TimelineMessageRecordFfi {
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: parentId, sender: "alice", plaintext: "Lunch at noon?",
            contentTokens: emptyMarkdownDocument(), kind: 9, mediaJson: nil, media: [],
            agentTextStreamJson: nil, deleted: false, invalidationStatus: nil)
        return timelineMessage(
            id: commentId, groupIdHex: "group", sender: "bob", plaintext: "Agreed", kind: 1111,
            tags: tags.map { MessageTagFfi(values: $0) }, recordedAt: 2,
            replyToMessageIdHex: parentId, replyPreview: preview)
    }

    private static func items(_ record: TimelineMessageRecordFfi) -> [MessageItem] {
        MessageItem.timeline(
            from: TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            activeAccountIdHex: "self",
            senderProfiles: ["alice": ChatPeerProfile(accountIdHex: "alice", displayName: "Alice", pictureURL: nil)])
    }

    /// A comment reads as a chat bubble quoting the parent MDK names, and its quote opens that parent.
    @Test func aCommentReadsAsAReplyQuotingItsParent() throws {
        let item = try #require(Self.items(Self.comment()).first)

        #expect(item.presentation == .chat)
        #expect(item.body == "Agreed")
        #expect(item.replyTargetIdHex == Self.parentId)
        #expect(item.replyContext?.targetMessageId == Self.parentId)
        #expect(item.replyContext?.senderName == "Alice")
        #expect(item.replyContext?.body == "Lunch at noon?")
    }

    /// A kind-1111 event without a numeric `k` tag is app-defined, as MDK treats it: no bubble, no
    /// Edit (MDK would refuse it), and search leaves it out.
    @Test func aKind1111WithoutANumericKTagStaysAnAppDefinedEvent() throws {
        let unmarked = Self.comment(tags: [["e", Self.parentId], ["k", "nine"]])

        let item = try #require(Self.items(unmarked).first)

        #expect(item.presentation == .unsupported)
        #expect(!item.canEdit)
        #expect(ConversationSearchCorpus.entry(for: unmarked) == nil)
    }

    /// Search finds a comment like any message on screen.
    @Test func searchFindsAComment() {
        #expect(ConversationSearchCorpus.entry(for: Self.comment()) != nil)
    }

    /// MDK keeps comments out of read tracking, so a comment is never the read-marker target: one
    /// after an unread message must not mark that message read.
    @Test func aCommentIsNeverAReadMarkerTarget() throws {
        let item = try #require(Self.items(Self.comment()).first)

        #expect(!item.countsAsReadActivity(inAuthoritativeGroup: true))
    }

    /// An author's edit of their comment applies live, as MDK accepts edits to recognised comments.
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
