//
//  DisbandedChatPreviewTests.swift
//  whitenoise-macTests
//
//  What an ended (disbanded) group says where its last message goes: in the timeline's system row
//  and in the chat-list row, which must read the same.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct DisbandedChatPreviewTests {
    private let english = Locale(identifier: "en")

    /// An ended group with no last message on its row is not "No messages yet": the disband left a
    /// system row in the timeline, and the group may have had messages before it.
    @Test func endedGroupWithoutAPreviewReadsAsTheDisbandRow() {
        let chat = groupChat(preview: "", lifecycle: .ended)

        #expect(chat.previewPlaceholder(locale: english) == "Group ended")
        #expect(chat.previewNotice(locale: english) == "Group ended")
        #expect(
            chat.previewPlaceholder(locale: english)
                == GroupLifecycle.disbandedSystemText(locale: english)
        )
    }

    /// The placeholder only fills an empty line: an ended group whose row still carries a message
    /// keeps showing it.
    @Test func endedGroupWithAPreviewKeepsItsLastMessage() {
        let chat = groupChat(preview: "Alice: see you Monday", lifecycle: .ended)

        #expect(chat.previewPlaceholder(locale: english) == nil)
        #expect(chat.previewNotice(locale: english) == nil)
    }

    /// Only the terminal state has a disband row to point at; a group still ending, or never ended,
    /// keeps the neutral placeholder.
    @Test func groupsThatHaveNotEndedKeepTheNeutralPlaceholder() {
        #expect(groupChat(preview: "", lifecycle: .ending).previewPlaceholder(locale: english) == "No messages yet")
        #expect(groupChat(preview: "", lifecycle: .active).previewPlaceholder(locale: english) == "No messages yet")
    }

    /// A removal still outranks everything else on the line, ended group or not.
    @Test func removalFromAnEndedGroupStillReportsTheRemoval() {
        let chat = groupChat(preview: "", lifecycle: .ended, membership: .removed)

        #expect(chat.previewNotice(locale: english) == "You were removed from this group")
    }

    /// The line follows the requested locale rather than being baked in at mapping time.
    @Test func endedPlaceholderFollowsTheRequestedLocale() {
        let chat = groupChat(preview: "", lifecycle: .ended)
        let spanish = chat.previewPlaceholder(locale: Locale(identifier: AppLanguage.spanish.rawValue))

        #expect(spanish == "Grupo terminado")
    }

    /// When MDK does put the disband's system row on the chat list, the row reads it in the
    /// timeline's localized wording, not MDK's English fallback text, resolved in the requested
    /// locale rather than baked in at mapping time.
    @Test func disbandSystemRowOnTheChatListUsesTheTimelineWording() {
        let row = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                groupSystem: groupSystemEvent(systemType: "group_disbanded", text: "Group disbanded"),
                messageIdHex: "disband",
                sender: "",
                senderDisplayName: nil,
                plaintext: "Group disbanded",
                contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
                kind: 1210,
                sticker: nil,
                timelineAt: 1_700_000_000,
                retentionSeconds: nil,
                retentionExpiresAt: nil,
                deleted: false,
                deletionSource: .unknown,
                attachmentKind: nil,
                attachmentCount: 0,
                deliveryState: .notApplicable
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1_700_000_000,
            selfMembership: .member,
            lifecycleState: .disbanded
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.preview.isEmpty)
        #expect(chat.previewAttribution == nil)
        #expect(chat.previewNotice(locale: english) == "Group ended")
        // Resolved at render time, so the same mapped row follows a language switch.
        #expect(chat.previewNotice(locale: Locale(identifier: AppLanguage.spanish.rawValue)) == "Grupo terminado")
    }

    /// The timeline's disband row reads in the same words the chat-list row uses.
    @MainActor
    @Test func timelineDisbandRowUsesTheSameWordingAsTheChatRow() {
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "disband",
                    groupIdHex: "group",
                    sender: "",
                    plaintext: "",
                    kind: 1210,
                    recordedAt: 1_700_000_000,
                    groupSystem: groupSystemEvent(
                        systemType: "group_disbanded",
                        text: "Group disbanded",
                        actorAccountIdHex: String(repeating: "a", count: 64)
                    )
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self", senderProfiles: [:])

        #expect(messages.map(\.body) == [GroupLifecycle.disbandedSystemText()])
    }

    private func groupChat(
        preview: String,
        lifecycle: GroupLifecycle,
        membership: ChatSelfMembership = .member
    ) -> ChatItem {
        ChatItem(
            id: "group",
            title: "Planning",
            subtitle: "",
            preview: preview,
            updatedAt: nil,
            avatarSeed: "seed",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: false,
            pendingConfirmation: false,
            selfMembership: membership,
            lifecycle: lifecycle
        )
    }
}
