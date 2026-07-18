//
//  PeerDisplayTextTests.swift
//  whitenoise-macTests
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

private let fsi = "\u{2068}"
private let pdi = "\u{2069}"
private let rtlOverride = "\u{202E}"
private let ltrIsolate = "\u{2066}"

private func isolated(_ text: String) -> String {
    fsi + text + pdi
}

@Suite(.serialized)
struct PeerDisplayTextTests {
    @Test func sanitizeStripsControlCharsAndLineSeparators() async throws {
        #expect(PeerDisplayText.sanitize("Alice\tBob") == "AliceBob")
        #expect(PeerDisplayText.sanitize("Alice\nBob") == "AliceBob")
        #expect(PeerDisplayText.sanitize("Alice\rBob") == "AliceBob")
        #expect(PeerDisplayText.sanitize("Alice\r\nBob") == "AliceBob")
        #expect(PeerDisplayText.sanitize("\u{0000}Alice") == "Alice")
        #expect(PeerDisplayText.sanitize("Alice\u{007F}") == "Alice")
        #expect(PeerDisplayText.sanitize("Alice\u{0080}Bob") == "AliceBob")
        #expect(PeerDisplayText.sanitize("Alice\u{2028}Bob") == "AliceBob")
        #expect(PeerDisplayText.sanitize("Alice\u{2029}Bob") == "AliceBob")
        #expect(PeerDisplayText.sanitize("Alice Bob") == "Alice Bob")

        let spoofedSender = "Trusted Admin\nSpoofed second line"
        let sanitized = try #require(PeerDisplayText.sanitize(spoofedSender))
        #expect(sanitized == "Trusted AdminSpoofed second line")
        #expect(!sanitized.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(!sanitized.unicodeScalars.contains { $0.properties.generalCategory == .lineSeparator })
        #expect(!sanitized.unicodeScalars.contains { $0.properties.generalCategory == .paragraphSeparator })
    }

    @Test func sanitizeStripsBidiAndFormatControls() async throws {
        let malicious = "\(rtlOverride)Alice\(ltrIsolate)"
        #expect(PeerDisplayText.sanitize(malicious) == "Alice")
        #expect(PeerDisplayText.sanitize("\(fsi)  Bob  \(pdi)") == "Bob")
        #expect(PeerDisplayText.sanitize("\u{200B}trimmed\u{200B}") == "trimmed")
        #expect(PeerDisplayText.sanitize(nil) == nil)
        #expect(PeerDisplayText.sanitize(rtlOverride) == nil)
    }

    @Test func templateFragmentWrapsSanitizedTextInFirstStrongIsolate() async throws {
        let wrapped = PeerDisplayText.templateFragment("\(rtlOverride)Carol\(pdi)")
        #expect(wrapped == isolated("Carol"))
        #expect(!wrapped.unicodeScalars.contains { $0.value == 0x202E })
        #expect(wrapped.hasPrefix(fsi))
        #expect(wrapped.hasSuffix(pdi))
    }

    @Test func newChatRecipientTitleSanitizesPeerControlledDisplayName() async throws {
        let recipient = NewChatRecipient(
            sourceQuery: "npub1recipient",
            memberRef: "npub1recipient",
            accountIdHex: "def456",
            npub: "npub1recipient",
            displayName: "\(rtlOverride)Trusted Admin\(ltrIsolate)",
            pictureURL: nil
        )

        #expect(recipient.displayName == "Trusted Admin")
        #expect(recipient.title == "Trusted Admin")
        #expect(!recipient.title.unicodeScalars.contains { $0.properties.generalCategory == .format })
    }

    @Test func chatListRowsSanitizePeerControlledTitlesAndPreviewSenderNames() async throws {
        let row = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "\(rtlOverride)Planning\(ltrIsolate)",
            groupName: "\(ltrIsolate)Planning\(rtlOverride)",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: "alice",
                senderDisplayName: "\(rtlOverride)Alice\(ltrIsolate)",
                plaintext: "Welcome in",
                contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
                kind: 9,
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
        #expect(chat.title == "Planning")
        #expect(chat.subtitle == "Planning")
        #expect(chat.preview == "\(isolated("Alice")): Welcome in")
        #expect(!chat.title.unicodeScalars.contains { $0.properties.generalCategory == .format })
        #expect(!chat.subtitle.unicodeScalars.contains { $0.properties.generalCategory == .format })
    }

    @Test func timelineMappingStripsBidiFromPeerDisplayNames() async throws {
        let alice = String(repeating: "a", count: 64)
        let spoofedName = "\(rtlOverride)Trusted Admin\(ltrIsolate)"
        let profiles = [
            alice: ChatPeerProfile(accountIdHex: alice, displayName: spoofedName, pictureURL: nil)
        ]
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "chat-1",
                    groupIdHex: "group",
                    sender: alice,
                    plaintext: "hello",
                    recordedAt: 1_700_000_000
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self", senderProfiles: profiles)
        #expect(messages.count == 1)
        #expect(messages[0].senderName == "Trusted Admin")
        #expect(!messages[0].senderName.unicodeScalars.contains { $0.properties.generalCategory == .format })
    }

    @Test func timelineMappingSanitizesGroupRenameNamesAndIsolatesTemplateFragments() async throws {
        let alice = String(repeating: "a", count: 64)
        let profiles = [
            alice: ChatPeerProfile(accountIdHex: alice, displayName: "Alice", pictureURL: nil)
        ]
        let maliciousOld = "\(rtlOverride)Team One\(ltrIsolate)"
        let maliciousNew = "\(ltrIsolate)Team Two\(rtlOverride)"
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "group-renamed",
                    groupIdHex: "group",
                    sender: "",
                    plaintext: "",
                    kind: 1210,
                    recordedAt: 1_700_000_000,
                    groupSystem: groupSystemEvent(
                        systemType: "group_renamed",
                        text: "Group renamed",
                        actorAccountIdHex: alice,
                        name: maliciousNew,
                        oldName: maliciousOld
                    )
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self", senderProfiles: profiles)
        #expect(messages.count == 1)

        let body = messages[0].body
        let expectedBody =
            "\(isolated("Alice")) renamed the group from \"\(isolated("Team One"))\" "
            + "to \"\(isolated("Team Two"))\""
        #expect(body == expectedBody)
        #expect(!body.unicodeScalars.contains { $0.value == 0x202E })
        #expect(!body.unicodeScalars.contains { $0.value == 0x2066 })
        #expect(body.contains(isolated("Team One")))
        #expect(body.contains(isolated("Team Two")))
    }

    @Test func legacyGroupSystemPayloadTextIsSanitized() async throws {
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "legacy-system",
                    groupIdHex: "group",
                    sender: "",
                    plaintext: #"{"v":1,"system_type":"group_renamed","text":"\u202EGroup renamed\u2066"}"#,
                    kind: 1210,
                    recordedAt: 1_700_000_000
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        #expect(messages.count == 1)
        #expect(messages[0].body == "Group renamed")
        #expect(!messages[0].body.unicodeScalars.contains { $0.properties.generalCategory == .format })
    }
}

private func timelineMessage(
    id: String,
    groupIdHex: String,
    sender: String,
    plaintext: String,
    kind: UInt64 = 9,
    recordedAt: UInt64,
    groupSystem: GroupSystemEventFfi? = nil
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: id,
        sourceMessageIdHex: nil,
        direction: "inbound",
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
        kind: kind,
        tags: [],
        timelineAt: recordedAt,
        receivedAt: recordedAt,
        replyToMessageIdHex: nil,
        replyPreview: nil,
        mediaJson: nil,
        media: [],
        agentTextStreamJson: nil,
        groupSystem: groupSystem,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

private func groupSystemEvent(
    systemType: String,
    text: String,
    actorAccountIdHex: String? = nil,
    name: String? = nil,
    oldName: String? = nil
) -> GroupSystemEventFfi {
    GroupSystemEventFfi(
        systemType: systemType,
        text: text,
        actorAccountIdHex: actorAccountIdHex,
        subjectAccountIdHex: nil,
        name: name,
        oldName: oldName,
        oldRetentionSeconds: nil,
        newRetentionSeconds: nil
    )
}
