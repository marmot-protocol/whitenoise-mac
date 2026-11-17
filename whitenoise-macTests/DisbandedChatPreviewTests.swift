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

    private let spanish = Locale(identifier: AppLanguage.spanish.rawValue)

    /// An ended group with no last message on its row is not "No messages yet": the disband left a
    /// system row in the timeline, and the group may have had messages before it.
    @Test func endedGroupWithoutAPreviewReadsAsTheDisbandRow() {
        let chat = groupChat(preview: "", lifecycle: .ended)

        #expect(chat.previewNotice(locale: english) == "Group ended")
        #expect(chat.previewNotice(locale: english) == GroupLifecycle.disbandedSystemText(locale: english))
    }

    /// The reported bug: an ended group whose row still carries an earlier message says the group
    /// ended rather than showing that message, so every account's row reads the same.
    @Test func endedGroupReplacesItsLastMessage() {
        let chat = groupChat(preview: "Alice: see you Monday", lifecycle: .ended)

        #expect(chat.previewNotice(locale: english) == "Group ended")
    }

    /// The row as MDK really sends it for an ended group: the disband's system row never reaches
    /// the chat list, so the last message is whatever eligible row came before it — here a member
    /// addition. The lifecycle alone has to turn the line into "Group ended".
    @Test func disbandedRowWithAnEarlierMembershipChangeReadsAsEnded() {
        let row = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                groupSystem: groupSystemEvent(
                    systemType: "member_added",
                    text: "Alice added Bob",
                    actorAccountIdHex: String(repeating: "a", count: 64),
                    subjectAccountIdHex: String(repeating: "b", count: 64)
                ),
                messageIdHex: "added",
                sender: String(repeating: "a", count: 64),
                senderDisplayName: "Alice",
                plaintext: "Alice added Bob",
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
            conversationKind: .group,
            lifecycleState: .disbanded
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.lifecycle == .ended)
        #expect(!chat.preview.isEmpty)
        #expect(chat.previewNotice(locale: english) == "Group ended")
    }

    /// A group still ending has no disband row yet, so it keeps its last message; the "Ending"
    /// badge carries the rest.
    @Test func endingGroupKeepsItsLastMessage() {
        let chat = groupChat(preview: "Alice: see you Monday", lifecycle: .ending)

        #expect(chat.previewNotice(locale: english) == nil)
        #expect(chat.preview == "Alice: see you Monday")
    }

    /// Only the terminal state has a disband row to point at; a group still ending, or never ended,
    /// keeps the neutral placeholder.
    @Test func groupsThatHaveNotEndedKeepTheNeutralPlaceholder() {
        #expect(groupChat(preview: "", lifecycle: .ending).previewNotice(locale: english) == "No messages yet")
        #expect(groupChat(preview: "", lifecycle: .active).previewNotice(locale: english) == "No messages yet")
    }

    /// A removal still outranks everything else on the line, ended group or not.
    @Test func removalFromAnEndedGroupStillReportsTheRemoval() {
        let chat = groupChat(preview: "", lifecycle: .ended, membership: .removed)

        #expect(chat.previewNotice(locale: english) == "You were removed from this group")
    }

    /// The removal outranks "Group ended" even when the row still carries an earlier message.
    @Test func removalFromAnEndedGroupWithMessagesStillReportsTheRemoval() {
        let chat = groupChat(preview: "Alice: see you Monday", lifecycle: .ended, membership: .removed)

        #expect(chat.previewNotice(locale: english) == "You were removed from this group")
    }

    /// The line follows the requested locale rather than being baked in at mapping time, whether
    /// or not the row carries a message.
    @Test func endedNoticeFollowsTheRequestedLocale() {
        for preview in ["", "Alice: see you Monday"] {
            let chat = groupChat(preview: preview, lifecycle: .ended)
            let localized = chat.previewNotice(locale: spanish)

            #expect(localized == L10n.string("Group ended", locale: spanish))
            #expect(localized != chat.previewNotice(locale: english))
        }
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
