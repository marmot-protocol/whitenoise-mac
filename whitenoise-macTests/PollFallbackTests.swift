import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// A kind-1068 row MDK projected no tally for (a malformed poll) must say it is a poll instead of
/// rendering its bare question as though a peer had typed it.
@MainActor
struct PollFallbackTests {
    private static let pollKind: UInt64 = 1068

    @Test func aPollRendersAsANoticeNamingTheQuestion() throws {
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "poll",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Lunch on Friday?",
                    kind: Self.pollKind,
                    recordedAt: 1_700_000_000
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let message = try #require(MessageItem.timeline(from: page, activeAccountIdHex: "self").first)

        #expect(message.presentation == .poll)
        #expect(!message.presentation.isChatBubble)
        #expect(message.body.contains(String(format: L10n.string("📊 Poll: %@"), "Lunch on Friday?")))
        #expect(message.body.contains(L10n.string("This poll can’t be displayed.")))
    }

    @Test func aPollWithoutAQuestionStillSaysPoll() {
        #expect(MessageItem.pollLabel(question: "  \n ") == L10n.string("Poll"))
    }

    @Test func theChatListPreviewIsThePollLabelAlone() {
        let row = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "poll",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "Lunch on Friday?",
                contentTokens: emptyMarkdownDocument(),
                kind: Self.pollKind,
                timelineAt: 1_700_000_000,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1_700_000_000,
            selfMembership: .member
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.preview == String(format: L10n.string("📊 Poll: %@"), "Lunch on Friday?"))
    }
}
