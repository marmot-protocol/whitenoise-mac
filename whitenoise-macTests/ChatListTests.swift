//
//  ChatListTests.swift
//  whitenoise-macTests
//
//  The sidebar: chat-row projection and enrichment, ordering, pinning, archiving,
//  filters, chat restoration and message search.
//
//  Split out of `whitenoise_macTests.swift` verbatim: every test body below is the
//  one that lived in that file, moved rather than rewritten.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

struct ChatListTests: WorkspaceTestSupport {
    @MainActor
    @Test func settingANicknameRelabelsChatRowsAndTheLiveTimelineWithoutTouchingOtherRows() async throws {
        let account = desktopAccount()
        let contact = String(repeating: "2", count: 64)
        let other = String(repeating: "3", count: 64)
        let directMessage = ChatItem(
            id: "dm",
            title: "Alice",
            subtitle: "Direct message",
            preview: "Hello",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            avatarSeed: contact,
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true
        )
        let otherDirectMessage = ChatItem(
            id: "dm-other",
            title: "Bob",
            subtitle: "Direct message",
            preview: "Hi",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            avatarSeed: other,
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true
        )
        let group = ChatItem(
            id: "group",
            title: "Book club",
            subtitle: "Group message",
            preview: "Hey",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_002),
            avatarSeed: "group",
            pictureURL: nil,
            unreadCount: 0
        )
        let fromContact = MessageItem(
            id: "m1",
            groupIdHex: "dm",
            senderAccountIdHex: contact,
            senderName: "Alice",
            body: "Hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            timelineAt: 1_700_000_000,
            isOutgoing: false
        )
        let fromOther = MessageItem(
            id: "m2",
            groupIdHex: "dm",
            senderAccountIdHex: other,
            senderName: "Bob",
            body: "Hi",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            timelineAt: 1_700_000_001,
            isOutgoing: false,
            replyContext: MessageReplyContext(targetMessageId: "m1", senderName: "Alice", body: "Hello")
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nickname-projection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = WorkspaceState(
            accounts: [AccountItem(summary: account)],
            chatsByAccount: [account.label: [group, otherDirectMessage, directMessage]],
            messagesByChat: ["dm": [fromContact, fromOther]],
            contactNicknameStore: ContactNicknameFileStore(directoryURL: directory),
            clientFactory: { FakeMarmotRuntime(accounts: [account]) }
        )
        state.activeAccountId = account.label
        state.selection = .chat("dm")

        state.setContactNickname("Mum", forContactAccountIdHex: contact)

        let renamed = try #require(state.chatItem(accountId: account.label, chatId: "dm"))
        #expect(renamed.title == "Mum")
        #expect(renamed.publishedTitle == "Alice")
        #expect(state.chatItem(accountId: account.label, chatId: "dm-other") == otherDirectMessage)
        #expect(state.chatItem(accountId: account.label, chatId: "group") == group)
        #expect(state.timelineMessage(groupIdHex: "dm", messageId: "m1")?.senderName == "Mum")
        #expect(state.timelineMessage(groupIdHex: "dm", messageId: "m1")?.publishedSenderName == "Alice")
        #expect(state.timelineMessage(groupIdHex: "dm", messageId: "m2")?.senderName == "Bob")
        #expect(state.timelineMessage(groupIdHex: "dm", messageId: "m2")?.publishedSenderName == nil)
        // The quote of the relabeled sender follows without waiting for a reprojection.
        #expect(state.timelineMessage(groupIdHex: "dm", messageId: "m2")?.replyContext?.senderName == "Mum")
        #expect(state.filteredChats(matching: "mum").map(\.id) == ["dm"])
        #expect(state.filteredChats(matching: "alice").map(\.id) == ["dm"])

        state.setContactNickname("   ", forContactAccountIdHex: contact)

        let restored = try #require(state.chatItem(accountId: account.label, chatId: "dm"))
        #expect(restored.title == "Alice")
        #expect(restored.publishedTitle == nil)
        #expect(state.timelineMessage(groupIdHex: "dm", messageId: "m1")?.senderName == "Alice")
        #expect(state.timelineMessage(groupIdHex: "dm", messageId: "m2")?.replyContext?.senderName == "Alice")
        #expect(state.contactNickname(forContactAccountIdHex: contact) == nil)
    }

    /// A rename has to reach the "Name: message" line of every chat that person last spoke in —
    /// including groups, which carry no nicknamed title to relabel — and it has to land on the
    /// gesture rather than waiting for that chat's next message.
    @MainActor
    @Test func settingANicknameReattributesChatRowPreviews() async throws {
        let account = desktopAccount()
        let contact = String(repeating: "2", count: 64)
        let other = String(repeating: "3", count: 64)
        func row(id: String, title: String, sender: String, senderName: String, body: String) -> ChatItem {
            ChatItem(
                id: id,
                title: title,
                subtitle: "Group message",
                preview: "\(isolated(senderName)): \(body)",
                previewAttribution: ChatPreviewAttribution(
                    senderAccountIdHex: sender,
                    publishedSenderName: senderName,
                    body: body
                ),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                avatarSeed: id,
                pictureURL: nil,
                unreadCount: 0
            )
        }
        let group = row(id: "group", title: "Book club", sender: contact, senderName: "Alice", body: "Hey")
        let otherGroup = row(id: "other-group", title: "Climbing", sender: other, senderName: "Bob", body: "Yo")
        let archived = row(id: "archived", title: "Old crew", sender: contact, senderName: "Alice", body: "Bye")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nickname-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = WorkspaceState(
            accounts: [AccountItem(summary: account)],
            chatsByAccount: [account.label: [group, otherGroup]],
            contactNicknameStore: ContactNicknameFileStore(directoryURL: directory),
            clientFactory: { FakeMarmotRuntime(accounts: [account]) }
        )
        state.activeAccountId = account.label
        state.setArchivedChats([archived], forAccountId: account.label)

        state.setContactNickname("Mum", forContactAccountIdHex: contact)

        #expect(state.chatItem(accountId: account.label, chatId: "group")?.preview == "\(isolated("Mum")): Hey")
        let relabeledArchive = state.archivedChatItem(accountId: account.label, chatId: "archived")
        #expect(relabeledArchive?.preview == "\(isolated("Mum")): Bye")
        // Another contact's row must not churn — the chat-list generation and the memoized
        // sidebar filter both key off these values.
        #expect(state.chatItem(accountId: account.label, chatId: "other-group") == otherGroup)

        state.setContactNickname(nil, forContactAccountIdHex: contact)

        #expect(state.chatItem(accountId: account.label, chatId: "group") == group)
        #expect(state.archivedChatItem(accountId: account.label, chatId: "archived") == archived)
    }

    /// The nickname also has to be folded in when the row is *projected*, not just patched onto
    /// rows already on screen — otherwise the next message in that chat brings the published name
    /// back.
    @MainActor
    @Test func projectedChatRowAttributesItsLastSenderByNickname() async throws {
        let account = desktopAccount()
        let contact = String(repeating: "2", count: 64)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nickname-projection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ContactNicknameFileStore(directoryURL: directory)
        let state = WorkspaceState(
            accounts: [AccountItem(summary: account)],
            contactNicknameStore: store,
            clientFactory: { FakeMarmotRuntime(accounts: [account]) }
        )
        state.activeAccountId = account.label
        let activeAccount = try #require(state.activeAccount)

        let peerRow = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Book club",
            groupName: "Book club",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: contact,
                senderDisplayName: "Alice",
                plaintext: "Hey",
                contentTokens: emptyMarkdownDocument(),
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

        #expect(state.baseChatItem(from: peerRow, account: activeAccount).preview == "\(isolated("Alice")): Hey")

        state.setContactNickname("Mum", forContactAccountIdHex: contact)

        let projected = state.baseChatItem(from: peerRow, account: activeAccount)
        #expect(projected.preview == "\(isolated("Mum")): Hey")
        #expect(projected.previewAttribution?.publishedSenderName == "Alice")
        // An account added *after* someone nicknamed it still has that entry on file. It must
        // never surface as your own name: the row still reads "You".
        try store.write([contact: "Mum", account.accountIdHex: "Me"], forOwnerAccountIdHex: account.accountIdHex)
        state.loadContactNicknames()
        let ownRow = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Book club",
            groupName: "Book club",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-2",
                sender: account.accountIdHex,
                senderDisplayName: "Desktop",
                plaintext: "On my way",
                contentTokens: emptyMarkdownDocument(),
                kind: 9,
                timelineAt: 1_700_000_001,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1_700_000_001,
            selfMembership: .member
        )

        #expect(
            state.baseChatItem(from: ownRow, account: activeAccount).preview
                == String(format: L10n.string("You: %@"), "On my way")
        )
        #expect(state.baseChatItem(from: peerRow, account: activeAccount).preview == "\(isolated("Mum")): Hey")
    }

    /// Every row's preview attribution resolves against the nickname map, and a chat-list snapshot
    /// projects hundreds of rows at once. The snapshot behind that lookup must be built once per
    /// nickname revision, not once per row.
    @MainActor
    @Test func projectingManyChatRowsBuildsTheNicknameSnapshotOnce() async throws {
        let account = desktopAccount()
        let contact = String(repeating: "2", count: 64)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nickname-cost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = WorkspaceState(
            accounts: [AccountItem(summary: account)],
            contactNicknameStore: ContactNicknameFileStore(directoryURL: directory),
            clientFactory: { FakeMarmotRuntime(accounts: [account]) }
        )
        state.activeAccountId = account.label
        let activeAccount = try #require(state.activeAccount)
        state.setContactNickname("Mum", forContactAccountIdHex: contact)

        let rows = (0..<200).map { index in
            ChatListRowFfi(
                groupIdHex: "group-\(index)",
                archived: false,
                pendingConfirmation: false,
                title: "Book club \(index)",
                groupName: "Book club \(index)",
                avatarUrl: nil,
                avatar: nil,
                lastMessage: ChatListMessagePreviewFfi(
                    messageIdHex: "message-\(index)",
                    sender: contact,
                    senderDisplayName: "Alice",
                    plaintext: "Hey",
                    contentTokens: emptyMarkdownDocument(),
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
        }

        let baseline = state.contactNicknameSnapshotBuildCount
        let projected = rows.map { state.baseChatItem(from: $0, account: activeAccount) }

        #expect(projected.allSatisfy { $0.preview == "\(isolated("Mum")): Hey" })
        #expect(state.contactNicknameSnapshotBuildCount == baseline)
    }

    @MainActor
    @Test func ownAccountsCannotBeNicknamed() async throws {
        let account = desktopAccount()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nickname-self-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactNicknameFileStore(directoryURL: directory)

        let state = WorkspaceState(
            accounts: [AccountItem(summary: account)],
            contactNicknameStore: store,
            clientFactory: { FakeMarmotRuntime(accounts: [account]) }
        )
        state.activeAccountId = account.label

        #expect(!state.canSetContactNickname(forContactAccountIdHex: account.accountIdHex))
        state.setContactNickname("Me", forContactAccountIdHex: account.accountIdHex)

        #expect(state.contactNickname(forContactAccountIdHex: account.accountIdHex) == nil)
        #expect(try store.loadAll().isEmpty)
    }

    @MainActor
    @Test func projectedChatRowTimestampUsesLastMessageTime() async throws {
        let lastMessageAt: UInt64 = 1_700_000_000
        let projectionRefreshedAt: UInt64 = 1_800_000_000
        let row = ChatListRowFfi(
            groupIdHex: "direct-group",
            archived: false,
            pendingConfirmation: false,
            title: "Alice",
            groupName: "",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "A prior message",
                contentTokens: emptyMarkdownDocument(),
                kind: 9,
                timelineAt: lastMessageAt,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: projectionRefreshedAt,
            selfMembership: .member
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.updatedAt == Date(timeIntervalSince1970: TimeInterval(lastMessageAt)))
    }

    @MainActor
    @Test func pendingInviteChatRowKeepsConversationSubtitle() async throws {
        let row = ChatListRowFfi(
            groupIdHex: "invited-group",
            archived: false,
            pendingConfirmation: true,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "Welcome in",
                contentTokens: emptyMarkdownDocument(),
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

        #expect(chat.pendingConfirmation)
        #expect(chat.subtitle == "Planning")
        #expect(chat.preview == "\(isolated("Alice")): Welcome in")
        #expect(chat.selfMembership == .member)
        #expect(!chat.isNoLongerMember)
    }

    /// A chat with no last message maps to an *empty* preview rather than a baked-in placeholder,
    /// which is the signal `ChatItem.previewPlaceholder(locale:)` reads to decide whether the row
    /// says "No messages yet" or explains an unanswered invite.
    @Test func chatRowWithoutMessagesMapsToAnEmptyPreview() async throws {
        let row = ChatListRowFfi(
            groupIdHex: "invited-group",
            archived: false,
            pendingConfirmation: true,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
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

        #expect(chat.preview.isEmpty)
        #expect(
            chat.previewPlaceholder(locale: Locale(identifier: "en"))
                == "You have been invited to a secure chat"
        )
    }

    @Test func pendingInviteChatCannotUseComposerUntilConfirmed() {
        let activeChat = ChatItem(
            id: "active-group",
            title: "Planning",
            subtitle: "Planning",
            preview: "No messages yet",
            updatedAt: nil,
            avatarSeed: "active-group",
            pictureURL: nil,
            unreadCount: 0,
            pendingConfirmation: false,
            selfMembership: .member
        )
        let pendingInvite = ChatItem(
            id: "pending-group",
            title: "Planning",
            subtitle: "Planning",
            preview: "Alice: Welcome in",
            updatedAt: nil,
            avatarSeed: "pending-group",
            pictureURL: nil,
            unreadCount: 0,
            pendingConfirmation: true,
            selfMembership: .member
        )
        let removedChat = ChatItem(
            id: "removed-group",
            title: "Planning",
            subtitle: "Planning",
            preview: "No messages yet",
            updatedAt: nil,
            avatarSeed: "removed-group",
            pictureURL: nil,
            unreadCount: 0,
            pendingConfirmation: false,
            selfMembership: .removed
        )

        #expect(activeChat.canUseComposer)
        #expect(!pendingInvite.canUseComposer)
        #expect(!removedChat.canUseComposer)
    }

    @MainActor
    @Test func chatRowMapsSelfMembershipVariantsIntoChatItem() async throws {
        let sender = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let variants: [(SelfMembershipFfi, ChatSelfMembership)] = [
            (.member, .member),
            (.left, .left),
            (.removed, .removed),
        ]

        for (ffiMembership, expected) in variants {
            let row = chatListRow(
                groupIdHex: "group",
                title: "Planning",
                preview: "hello",
                sender: sender,
                timelineAt: 1_700_000_000,
                selfMembership: ffiMembership
            )
            let chat = ChatItem(row: row, activeAccountIdHex: "self")

            #expect(chat.selfMembership == expected)
            #expect(chat.isNoLongerMember == (expected != .member))
        }
    }

    @MainActor
    @Test func selfMembershipPresentationLabelsDescribeEndedStates() async throws {
        #expect(ChatSelfMembership.member.sidebarBadgeLabel == nil)
        #expect(ChatSelfMembership.member.endedDescription == nil)
        #expect(ChatSelfMembership.left.sidebarBadgeLabel == "Left")
        #expect(ChatSelfMembership.left.endedDescription == "You left this group")
        #expect(ChatSelfMembership.removed.sidebarBadgeLabel == "Removed")
        #expect(ChatSelfMembership.removed.endedDescription == "You were removed from this group")
    }

    @MainActor
    @Test func chatListPreviewUsesSystemMessageText() async throws {
        let row = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: #"{"v":1,"system_type":"member_added","text":"Member added"}"#,
            sender: "",
            timelineAt: 1_700_000_000,
            kind: 1210
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.preview == "Member added")
    }

    @MainActor
    @Test func chatListUsesSubscriptionSnapshotAndTypedDeltas() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installChatListUpdates([
            .removeRow(trigger: .removed, groupIdHex: "group")
        ])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didApplyRemoval = await waitFor {
            state.activeChats.map(\.id) == ["direct-group"]
        }

        #expect(didApplyRemoval)
        #expect(runtime.chatListSubscriptionCount == 1)
    }

    @MainActor
    @Test func bootstrapEnrichesNonSelectedDirectChatWithBlockingListener() async throws {
        // Issue #281: the full-snapshot enrichment started by `applyChatRows` during
        // bootstrap/reload must survive listener startup. The listener reuses the snapshot's
        // subscription, so `nextUpdate()` blocks forever (no forced reconnect to run its own
        // snapshot/enrichment). A non-selected direct chat must still resolve to its peer
        // display name / avatar / isDirect instead of staying on its raw group-id fallback.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        // A more-recent message group is auto-selected on bootstrap, leaving the direct chat
        // non-selected so its enrichment is driven only by the full-snapshot pass.
        runtime.installDirectGroup(
            directGroup(),
            alongside: [messageGroup()],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "group-latest",
                    groupIdHex: "group",
                    sender: aliceId,
                    plaintext: "Most recent group message.",
                    kind: 9,
                    recordedAt: 1_700_000_900
                )
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        let didEnrichDirectChat = await waitFor(attempts: 300) {
            state.activeChats.first { $0.id == "direct-group" }?.title == "Alice Actual"
        }

        let directChat = state.activeChats.first { $0.id == "direct-group" }
        if !didEnrichDirectChat {
            Issue.record(
                """
                Expected non-selected direct chat to be enriched by the full-snapshot pass. \
                title=\(directChat?.title ?? "nil") isDirect=\(directChat?.isDirect ?? false) \
                pictureURL=\(directChat?.pictureURL ?? "nil") selection=\(String(describing: state.selection))
                """
            )
        }
        #expect(didEnrichDirectChat)
        #expect(directChat?.isDirect == true)
        #expect(directChat?.pictureURL == "https://example.com/alice.png")
        // The listener reuses the snapshot's subscription; no forced reconnect masks the bug.
        #expect(runtime.chatListSubscriptionCount == 1)
        // The direct chat must not have been auto-selected (older than the group chat).
        #expect(state.selection == .chat("group"))
    }

    @MainActor
    @Test func concurrentReloadChatsForSameAccountCoalesces() async throws {
        // Issue #210: reloadChats() is reachable from independently-spawned Tasks. Two overlapping
        // same-account reloads must share one in-flight subscription/snapshot pass instead of
        // duplicating FFI work and churn-cancelling the chat-list listener the first reload started.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didHydrateChats = await waitFor {
            state.activeChats.count == 2
        }
        #expect(didHydrateChats)

        let subscriptionBaseline = runtime.chatListSubscriptionCount
        runtime.chatListSubscriptionDelayNanoseconds = 100_000_000

        async let firstReload: Void = state.reloadChats()
        let didStartFirstReload = await waitFor {
            runtime.chatListSubscriptionCount == subscriptionBaseline + 1
        }
        #expect(didStartFirstReload)

        async let secondReload: Void = state.reloadChats()
        _ = await (firstReload, secondReload)

        #expect(runtime.chatListSubscriptionCount == subscriptionBaseline + 1)
        #expect(state.isRefreshing == false)
        #expect(state.activeChats.count == 2)
    }

    @MainActor
    @Test func forcedReloadChatsStartsFreshSnapshotInsteadOfCoalescing() async throws {
        // Post-mutation reloads must not await a same-account reload whose snapshot may have been
        // started before the mutation. They force a new generation while ordinary overlapping
        // reloads still coalesce.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didHydrateChats = await waitFor {
            state.activeChats.count == 2
        }
        #expect(didHydrateChats)

        let subscriptionBaseline = runtime.chatListSubscriptionCount
        runtime.chatListSubscriptionDelayNanoseconds = 100_000_000

        async let firstReload: Void = state.reloadChats()
        let didStartFirstReload = await waitFor {
            runtime.chatListSubscriptionCount == subscriptionBaseline + 1
        }
        #expect(didStartFirstReload)

        async let forcedReload: Void = state.reloadChats(forceFreshSnapshot: true)
        let didStartForcedReload = await waitFor {
            runtime.chatListSubscriptionCount == subscriptionBaseline + 2
        }
        #expect(didStartForcedReload)

        _ = await (firstReload, forcedReload)

        #expect(runtime.chatListSubscriptionCount == subscriptionBaseline + 2)
        #expect(state.isRefreshing == false)
        #expect(state.activeChats.count == 2)
    }

    @MainActor
    @Test func cancellingSuspendedChatReloadClearsSpinnerOwnership() async throws {
        // Teardown paths cancel reload ownership while the task may be suspended in FFI. The stale
        // task must not re-own the spinner when it unwinds after cancellation.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didHydrateChats = await waitFor {
            state.activeChats.count == 2
        }
        #expect(didHydrateChats)

        let subscriptionBaseline = runtime.chatListSubscriptionCount
        runtime.chatListSubscriptionDelayNanoseconds = 100_000_000

        async let reload: Void = state.reloadChats()
        let didSuspendReload = await waitFor {
            state.isRefreshing && runtime.chatListSubscriptionCount == subscriptionBaseline + 1
        }
        #expect(didSuspendReload)

        state.cancelChatListReload()
        #expect(state.isRefreshing == false)
        _ = await reload

        #expect(runtime.chatListSubscriptionCount == subscriptionBaseline + 1)
        #expect(state.isRefreshing == false)
    }

    @MainActor
    @Test func subscriptionSnapshotsRunOffMainThread() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didHydrateChats = await waitFor {
            state.activeChats.count == 2
        }
        #expect(didHydrateChats)
        runtime.clearSyncCallThreadRecords()

        runtime.chatListStreamEndsAfterUpdates = true
        let chatListSubscriptionBaseline = runtime.chatListSubscriptionCount
        await state.reloadChats()
        let didReconnectChatList = await waitFor {
            runtime.chatListSubscriptionCount >= chatListSubscriptionBaseline + 2
        }
        #expect(didReconnectChatList)
        let didRecordChatListSnapshots = await waitFor {
            runtime.syncCallThreadRecord("chatListSubscription.snapshot").count >= 2
        }
        #expect(didRecordChatListSnapshots)

        let targetChat = try #require(
            state.activeChats.first { chat in
                state.messagesByChat[chat.id] == nil
            }
        )
        state.selection = .chat(targetChat.id)
        runtime.timelineStreamEndsAfterUpdates = true
        let timelineSubscriptionBaseline = runtime.timelineSubscriptionCount
        await state.loadMessages(groupIdHex: targetChat.id)
        let didReconnectTimeline = await waitFor {
            runtime.timelineSubscriptionCount >= timelineSubscriptionBaseline + 2
        }
        #expect(didReconnectTimeline)
        let didRecordTimelineSnapshots = await waitFor {
            runtime.syncCallThreadRecord("timelineMessagesSubscription.snapshot").count >= 2
        }
        #expect(didRecordTimelineSnapshots)
        runtime.chatListStreamEndsAfterUpdates = false
        runtime.timelineStreamEndsAfterUpdates = false

        let chatListSnapshotThreads = runtime.syncCallThreadRecord("chatListSubscription.snapshot")
        let timelineSnapshotThreads = runtime.syncCallThreadRecord("timelineMessagesSubscription.snapshot")
        #expect(chatListSnapshotThreads.count >= 2)
        #expect(chatListSnapshotThreads.allSatisfy { !$0 })
        #expect(timelineSnapshotThreads.count >= 2)
        #expect(timelineSnapshotThreads.allSatisfy { !$0 })
    }

    @MainActor
    @Test func chatRestorationPreferenceDefaultsOffAndClearsLocalTargets() throws {
        let suiteName = "whitenoise-macTests.chat-restoration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistedStore = UserDefaultsChatRestorationStore(defaults: defaults)
        #expect(!persistedStore.isEnabled)
        persistedStore.setTarget(groupIdHex: "GROUP", forOwnerAccountIdHex: "ACCOUNT")
        #expect(persistedStore.targetGroupId(forOwnerAccountIdHex: "account") == nil)

        persistedStore.setEnabled(true)
        persistedStore.setTarget(groupIdHex: " GROUP ", forOwnerAccountIdHex: " ACCOUNT ")
        #expect(persistedStore.targetGroupId(forOwnerAccountIdHex: "account") == "group")

        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "account"
        )
        let chat = chatListOrderingTestItem(id: "group", title: "General", updatedAt: 100)
        let store = InMemoryChatRestorationStore()
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [chat]],
            chatRestorationStore: store
        )
        state.activeAccountId = account.id
        state.selection = .chat(chat.id)

        #expect(!state.restoreLastSelectedChat)
        #expect(store.targetsByAccount.isEmpty)

        state.setRestoreLastSelectedChat(true)
        #expect(state.restoreLastSelectedChat)
        #expect(store.targetsByAccount[account.accountIdHex] == chat.id)

        state.setRestoreLastSelectedChat(false)
        #expect(!state.restoreLastSelectedChat)
        #expect(store.targetsByAccount.isEmpty)

        state.setRestoreLastSelectedChat(true)
        #expect(store.targetsByAccount[account.accountIdHex] == chat.id)
        state.resetToNewInstallState(storageRootPath: TestStorageRoot.isolated.resolvedPath())
        #expect(store.targetsByAccount.isEmpty)
    }

    @MainActor
    @Test func bootstrapRestoresSavedChatOnlyAfterChatSnapshotIsReady() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "group-old",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Saved group message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "group"
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "direct-new",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Newer direct message",
                    kind: 9,
                    recordedAt: 1_700_000_100
                )
            ],
            groupIdHex: "direct-group"
        )
        runtime.chatListSubscriptionDelayNanoseconds = 100_000_000
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [account.accountIdHex: "group"]
        )
        let state = WorkspaceState(
            chatRestorationStore: store,
            clientFactory: { runtime }
        )

        async let bootstrap: Void = state.bootstrap()
        let didStartChatListLoad = await waitFor {
            runtime.chatListSubscriptionCount == 1
        }
        #expect(didStartChatListLoad)
        #expect(state.selection == nil)
        #expect(state.activeChats.isEmpty)

        await bootstrap
        let didRestoreSavedChat = await waitFor {
            state.selection == .chat("group")
                && state.messagesByChat["group"]?.map(\.id) == ["group-old"]
        }

        #expect(didRestoreSavedChat)
        #expect(runtime.timelineSubscriptionCount == 1)
    }

    @MainActor
    @Test func bootstrapFallsBackWhenSavedChatMembershipEnded() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(selfMembership: .removed), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "removed-old",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Removed group message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "group"
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "direct-new",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Newest direct message",
                    kind: 9,
                    recordedAt: 1_700_000_100
                )
            ],
            groupIdHex: "direct-group"
        )
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [account.accountIdHex: "group"]
        )
        let state = WorkspaceState(
            chatRestorationStore: store,
            clientFactory: { runtime }
        )

        await state.bootstrap()

        #expect(state.selection == .chat("direct-group"))
        #expect(store.targetsByAccount[account.accountIdHex] == "direct-group")
    }

    @MainActor
    @Test func unavailableSavedChatFallsBackToMostRecentChat() async {
        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let mostRecentChat = chatListOrderingTestItem(
            id: "direct-group",
            title: "Direct Chat",
            updatedAt: 200
        )
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [account.accountIdHex: "unavailable-group"]
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [mostRecentChat]],
            chatRestorationStore: store
        )
        state.activeAccountId = account.id
        state.selection = nil

        await state.selectInitialChatIfNeeded()

        #expect(state.selection == .chat(mostRecentChat.id))
        #expect(store.targetsByAccount[account.accountIdHex] == mostRecentChat.id)
    }

    @MainActor
    @Test func bootstrapNeverRestoresAnotherAccountsSavedChat() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let otherAccountIdHex = "1111111111111111111111111111111111111111111111111111111111111111"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "group-old",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Older group message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "group"
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "direct-new",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Newest direct message",
                    kind: 9,
                    recordedAt: 1_700_000_100
                )
            ],
            groupIdHex: "direct-group"
        )
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [otherAccountIdHex: "group"]
        )
        let state = WorkspaceState(
            chatRestorationStore: store,
            clientFactory: { runtime }
        )

        await state.bootstrap()

        #expect(state.selection == .chat("direct-group"))
        #expect(store.targetsByAccount[account.accountIdHex] == "direct-group")
        #expect(store.targetsByAccount[otherAccountIdHex] == "group")
    }

    @MainActor
    @Test func accountSwitchOpensTheChatRememberedForTheAccountBeingSwitchedTo() async throws {
        // The memory was per account in storage but only ever read at launch, so a switch fell back
        // to the new account's newest row — and then persisted *that* as the account's last chat,
        // erasing the real one. One hop was enough to make the whole setting look account-blind.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let first = AccountItem(
            id: "First Account",
            accountRef: "First Account",
            displayName: "First Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111"
        )
        let second = AccountItem(
            id: "Second Account",
            accountRef: "Second Account",
            displayName: "Second Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222"
        )
        let firstRemembered = chatListOrderingTestItem(id: "first-older", title: "First Older", updatedAt: 100)
        let firstNewest = chatListOrderingTestItem(id: "first-newer", title: "First Newer", updatedAt: 300)
        let secondRemembered = chatListOrderingTestItem(id: "second-older", title: "Second Older", updatedAt: 150)
        let secondNewest = chatListOrderingTestItem(id: "second-newer", title: "Second Newer", updatedAt: 350)
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [
                first.accountIdHex: firstRemembered.id,
                second.accountIdHex: secondRemembered.id,
            ]
        )
        let state = WorkspaceState(accounts: [first, second], chatRestorationStore: store)
        // Loaded after init: a fixture whose rows are already cached lets the initializer select one,
        // which would persist it and overwrite the very memory under test.
        state.setChats([firstNewest, firstRemembered], forAccountId: first.id)
        state.setChats([secondNewest, secondRemembered], forAccountId: second.id)
        state.activeAccountId = first.id
        state.selection = .chat(firstRemembered.id)

        state.selectAccount(second)

        #expect(state.activeAccountId == second.id)
        #expect(state.selection == .chat(secondRemembered.id))
        #expect(store.targetsByAccount[first.accountIdHex] == firstRemembered.id)

        state.selectAccount(first)

        #expect(state.selection == .chat(firstRemembered.id))
        #expect(store.targetsByAccount[second.accountIdHex] == secondRemembered.id)
    }

    @MainActor
    @Test func accountSwitchWithoutCachedRowsDefersRestorationToTheFreshSnapshot() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let first = AccountItem(
            id: "First Account",
            accountRef: "First Account",
            displayName: "First Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111"
        )
        let second = AccountItem(
            id: "Second Account",
            accountRef: "Second Account",
            displayName: "Second Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222"
        )
        let firstChat = chatListOrderingTestItem(id: "first-chat", title: "First Chat", updatedAt: 100)
        let secondRemembered = chatListOrderingTestItem(id: "second-older", title: "Second Older", updatedAt: 150)
        let secondNewest = chatListOrderingTestItem(id: "second-newer", title: "Second Newer", updatedAt: 350)
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [second.accountIdHex: secondRemembered.id]
        )
        let state = WorkspaceState(accounts: [first, second], chatRestorationStore: store)
        state.setChats([firstChat], forAccountId: first.id)
        state.activeAccountId = first.id
        state.selection = .chat(firstChat.id)

        state.selectAccount(second)

        // The second account's rows have never been loaded in this process, so the switch lands on
        // nothing rather than on a stand-in row: selecting one would persist through `selection` and
        // destroy the memory before the snapshot could honor it.
        #expect(state.selection == nil)
        #expect(store.targetsByAccount[second.accountIdHex] == secondRemembered.id)

        state.setChats([secondNewest, secondRemembered], forAccountId: second.id)
        await state.selectInitialChatIfNeeded()

        #expect(state.selection == .chat(secondRemembered.id))
    }

    @MainActor
    @Test func accountSwitchNeverAdoptsAnotherAccountsRememberedChat() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let first = AccountItem(
            id: "First Account",
            accountRef: "First Account",
            displayName: "First Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111"
        )
        let second = AccountItem(
            id: "Second Account",
            accountRef: "Second Account",
            displayName: "Second Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222"
        )
        // Both accounts are members of the same group, which is the only way a global last-chat
        // memory could ever resolve for the wrong identity.
        let shared = chatListOrderingTestItem(id: "shared-group", title: "Shared", updatedAt: 100)
        let secondOwn = chatListOrderingTestItem(id: "second-own", title: "Second Own", updatedAt: 350)
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [first.accountIdHex: shared.id]
        )
        let state = WorkspaceState(accounts: [first, second], chatRestorationStore: store)
        state.setChats([shared], forAccountId: first.id)
        state.setChats([secondOwn, shared], forAccountId: second.id)
        state.activeAccountId = first.id
        state.selection = .chat(shared.id)

        state.selectAccount(second)

        #expect(state.selection == .chat(secondOwn.id))
        #expect(store.targetsByAccount[first.accountIdHex] == shared.id)
        #expect(store.targetsByAccount[second.accountIdHex] == secondOwn.id)
    }

    @MainActor
    @Test func archivingTheRememberedChatStopsRestoringItWithoutForgettingIt() async throws {
        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let remembered = chatListOrderingTestItem(id: "archived-group", title: "Archived", updatedAt: 100)
        let newest = chatListOrderingTestItem(id: "active-group", title: "Active", updatedAt: 300)
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [account.accountIdHex: remembered.id]
        )
        let state = WorkspaceState(accounts: [account], chatRestorationStore: store)
        state.activeAccountId = account.id
        state.setChats([newest], forAccountId: account.id)
        state.setArchivedChats([remembered], forAccountId: account.id)
        state.selection = nil

        // Every switch resets the sidebar to the active filter, so reopening an archived
        // conversation would show a transcript with no row beside it.
        #expect(state.rememberedChat(forAccount: account) == nil)

        await state.selectInitialChatIfNeeded()

        // The stand-in gets selected, but must not be written over the memory: unarchiving has to
        // bring the conversation back, unlike one that has genuinely left the account's list.
        #expect(state.selection == .chat(newest.id))
        #expect(store.targetsByAccount[account.accountIdHex] == remembered.id)
        // The suspension lasts exactly as long as that one automatic selection.
        #expect(!state.isPreservingRememberedChat)
        state.selectChat(newest)
        #expect(store.targetsByAccount[account.accountIdHex] == newest.id)
    }

    @MainActor
    @Test func returningToTheChatsFromSettingsKeepsAnArchivedRememberedChat() async throws {
        // The rail avatar is the way back from Settings, and it picks a conversation for the user —
        // so it needs the same protection as the post-snapshot pass, or a settings-anchored account
        // switch would quietly forget an archived memory on the way out.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let remembered = chatListOrderingTestItem(id: "archived-group", title: "Archived", updatedAt: 100)
        let newest = chatListOrderingTestItem(id: "active-group", title: "Active", updatedAt: 300)
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [account.accountIdHex: remembered.id]
        )
        let state = WorkspaceState(accounts: [account], chatRestorationStore: store)
        state.activeAccountId = account.id
        state.setChats([newest], forAccountId: account.id)
        state.setArchivedChats([remembered], forAccountId: account.id)
        state.showSettings(.overview)

        state.selectAccount(account)

        #expect(state.selection == .chat(newest.id))
        #expect(store.targetsByAccount[account.accountIdHex] == remembered.id)
    }

    @MainActor
    @Test func completedSnapshotWithNoChatsForgetsTheRememberedChat() async throws {
        // Emptiness used to stand in for "the list has not loaded", which let a dead memory outlive
        // the snapshot that disproved it. What makes a list authoritative is the caller — this one
        // runs directly after `applyChatRows` — not whether it happens to have rows.
        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [account.accountIdHex: "deleted-group"]
        )
        let state = WorkspaceState(accounts: [account], chatRestorationStore: store)
        state.activeAccountId = account.id
        state.setChats([], forAccountId: account.id)
        state.selection = nil

        await state.selectInitialChatIfNeeded()

        #expect(state.selection == nil)
        #expect(store.targetsByAccount[account.accountIdHex] == nil)
    }

    @MainActor
    @Test func railTapBeforeTheSnapshotLandsNeverForgetsTheRememberedChat() async throws {
        // The rail can be tapped while the account's rows are still whatever was cached earlier in
        // the process. Deciding a memory is dead from that list would destroy it just before the
        // fresh snapshot arrives to honor it.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let store = InMemoryChatRestorationStore(
            isEnabled: true,
            targetsByAccount: [account.accountIdHex: "not-loaded-yet"]
        )
        let state = WorkspaceState(accounts: [account], chatRestorationStore: store)
        state.activeAccountId = account.id
        state.showSettings(.overview)

        state.selectAccount(account)

        // Nothing to land on yet, so the tap leaves Settings without a conversation — and, crucially,
        // with the memory intact for `selectInitialChatIfNeeded()` to honor.
        #expect(state.selection == nil)
        #expect(store.targetsByAccount[account.accountIdHex] == "not-loaded-yet")

        state.setChats(
            [chatListOrderingTestItem(id: "not-loaded-yet", title: "Late", updatedAt: 100)], forAccountId: account.id)
        await state.selectInitialChatIfNeeded()

        #expect(state.selection == .chat("not-loaded-yet"))
    }

    @Test func globalMessageSearchTextNormalizesOrderedTokensAndBoundsSnippets() {
        let tokens = GlobalMessageSearchText.tokens(in: "  CAFÉ…shipped!  ")

        #expect(GlobalMessageSearchText.matches("The Café package shipped today", tokens: tokens))
        #expect(!GlobalMessageSearchText.matches("Shipped from the café", tokens: tokens))
        #expect(
            GlobalMessageSearchText.matches(
                "The Café package shipped today",
                tokens: GlobalMessageSearchText.tokens(in: "cafe\u{0301} shipped")
            )
        )
        #expect(GlobalMessageSearchText.tokens(in: " …!? ").isEmpty)

        let snippet = GlobalMessageSearchText.snippet(
            from: String(repeating: "prefix ", count: 80) + "Café shipped\nwith tracking",
            tokens: tokens
        )
        #expect(snippet.leading.hasPrefix("…"))
        #expect(snippet.match == "Café")
        #expect(!snippet.trailing.contains("\n"))
        #expect((snippet.leading + snippet.match + snippet.trailing).count <= 195)

        let longToken = String(repeating: "x", count: 500)
        let longSnippet = GlobalMessageSearchText.snippet(
            from: "before \(longToken) after",
            tokens: [longToken]
        )
        #expect(longSnippet.match.count == 96)
        #expect(longSnippet.trailing.hasPrefix("…"))
        #expect((longSnippet.leading + longSnippet.match + longSnippet.trailing).count <= 291)
    }

    @Test func globalMessageSearchProjectsResolvedVisibleTimelineHistory() throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let sender = String(repeating: "a", count: 64)
        var olderRows: [TimelineMessageRecordFfi] = []
        olderRows.reserveCapacity(420)
        for index in 0..<420 {
            let record = timelineMessage(
                id: String(format: "%064x", index + 1),
                groupIdHex: "group",
                sender: sender,
                plaintext: index == 3 ? "The Café package shipped today" : "unrelated \(index)",
                recordedAt: UInt64(index + 1)
            )
            olderRows.append(record)
        }
        let resolvedEdit = timelineMessage(
            id: String(repeating: "e", count: 64),
            groupIdHex: "group",
            sender: sender,
            plaintext: "The café edit shipped successfully",
            recordedAt: 500
        )
        let deleted = timelineMessage(
            id: String(repeating: "d", count: 64),
            groupIdHex: "group",
            sender: sender,
            plaintext: "The café deletion shipped",
            recordedAt: 501,
            deleted: true
        )
        let invalidated = timelineMessage(
            id: String(repeating: "c", count: 64),
            groupIdHex: "group",
            sender: sender,
            plaintext: "The café invalidation shipped",
            recordedAt: 502,
            invalidationStatus: "LosingBranch"
        )
        let systemRow = timelineMessage(
            id: String(repeating: "b", count: 64),
            groupIdHex: "group",
            sender: sender,
            plaintext: "The café system event shipped",
            kind: 1210,
            recordedAt: 503
        )
        runtime.installTimelinePage(
            TimelinePageFfi(
                messages: olderRows + [resolvedEdit, deleted, invalidated, systemRow],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            groupIdHex: "group"
        )
        runtime.installTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: String(repeating: "f", count: 64),
                        groupIdHex: "hidden-group",
                        sender: sender,
                        plaintext: "The café hidden chat shipped",
                        recordedAt: 600
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            groupIdHex: "hidden-group"
        )

        let results = try GlobalMessageSearchEngine.search(
            client: runtime,
            accountRef: "Desktop Account",
            localAccountId: desktopAccount().accountIdHex,
            localDisplayName: "Desktop Account",
            scopes: [GlobalMessageSearchScope(groupId: "group", title: "Test Group")],
            query: "cafe\u{0301} shipped",
            checkCancellation: {}
        )

        #expect(results.map(\.messageId) == [resolvedEdit.messageIdHex, olderRows[3].messageIdHex])
        #expect(results.allSatisfy { $0.groupId == "group" && $0.chatTitle == "Test Group" })
        #expect(results.first?.snippet.match.lowercased() == "café")
        #expect(runtime.timelineMessageQueries.count == 3)
    }

    @MainActor
    @Test func globalMessageSearchDebouncesAndCancelsSupersededQueriesOffMain() async throws {
        let state = WorkspaceState.preview()
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        state.client = runtime
        let chat = try #require(state.activeChats.first)
        let sender = try #require(state.activeAccount).accountIdHex
        runtime.timelineMessagesHandler = { query in
            TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: String(repeating: "a", count: 64),
                        groupIdHex: query.groupIdHex ?? chat.id,
                        sender: sender,
                        plaintext: "fresh result",
                        recordedAt: 10
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        state.presentGlobalMessageSearch()
        state.globalMessageSearchQuery = "superseded"
        state.scheduleGlobalMessageSearch()
        state.globalMessageSearchQuery = "fresh"
        state.scheduleGlobalMessageSearch()

        #expect(await waitFor { !state.isSearchingAllMessages && !state.globalMessageSearchResults.isEmpty })
        #expect(state.globalMessageSearchResults.allSatisfy { $0.snippet.match == "fresh" })
        #expect(runtime.timelineMessageQueries.count == state.activeChats.count)
        #expect(runtime.syncCallThreadRecord("timelineMessages").allSatisfy { !$0 })
        state.dismissGlobalMessageSearch()
    }

    @Test func sidebarMessageSearchKeepsTheNewestMatchFromEveryChat() throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let sender = desktopAccount().accountIdHex
        runtime.timelineMessagesHandler = { query in
            let groupId = query.groupIdHex ?? "group"
            let messages = (0..<75).map { index in
                timelineMessage(
                    id: String(format: "%064x", index + (groupId == "first" ? 1 : 1_000)),
                    groupIdHex: groupId,
                    sender: sender,
                    plaintext: "shared needle \(index)",
                    recordedAt: UInt64(index + (groupId == "first" ? 1 : 1_000))
                )
            }
            return TimelinePageFfi(messages: messages, hasMoreBefore: false, hasMoreAfter: false)
        }

        let results = try GlobalMessageSearchEngine.searchLatestByChat(
            client: runtime,
            accountRef: "Desktop Account",
            localAccountId: sender,
            localDisplayName: "Desktop Account",
            scopes: [
                GlobalMessageSearchScope(groupId: "first", title: "First"),
                GlobalMessageSearchScope(groupId: "second", title: "Second"),
            ],
            query: "shared needle",
            checkCancellation: {}
        )

        #expect(results.map(\.groupId) == ["second", "first"])
        #expect(results.map(\.timelineAt) == [1_074, 75])
        #expect(runtime.timelineMessageQueries.count == 2)
    }

    @MainActor
    @Test func sidebarSearchFiltersToAHistoryOnlyMatchWithoutPresentingASheet() async throws {
        let state = WorkspaceState.preview()
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        state.client = runtime
        let query = "fullhistoryneedle616"
        let sender = try #require(state.activeAccount).accountIdHex
        let target = try #require(state.activeChats.last)
        #expect(
            !state.activeChats.contains {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.preview.localizedCaseInsensitiveContains(query)
            })
        runtime.timelineMessagesHandler = { timelineQuery in
            let groupId = timelineQuery.groupIdHex ?? "group"
            return TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: String(repeating: "6", count: 64),
                        groupIdHex: groupId,
                        sender: sender,
                        plaintext: groupId == target.id
                            ? "A buried message contains \(query)"
                            : "An unrelated message",
                        recordedAt: 10
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        state.searchText = query
        state.scheduleSidebarMessageSearch()

        #expect(!state.isGlobalMessageSearchPresented)
        #expect(
            await waitFor {
                !state.isSearchingSidebarMessages && !state.sidebarMessageSearchResultsByGroupId.isEmpty
            })
        #expect(state.sidebarSearchFilteredChats(state.activeChats).map(\.id) == [target.id])
        #expect(state.sidebarMessageSearchResult(for: target)?.snippet.match == query)
        #expect(state.globalMessageSearchQuery.isEmpty)
    }

    @MainActor
    @Test func globalMessageSearchDropsStaleInFlightGenerationAndAccountResults() async throws {
        let state = WorkspaceState.preview()
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        state.client = runtime
        let firstQueryEntered = DispatchSemaphore(value: 0)
        let releaseFirstQuery = DispatchSemaphore(value: 0)
        let calls = AtomicCounter()
        let sender = try #require(state.activeAccount).accountIdHex
        runtime.timelineMessagesHandler = { query in
            let call = calls.increment()
            if call == 1 {
                firstQueryEntered.signal()
                _ = releaseFirstQuery.wait(timeout: .now() + 5)
            }
            return TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: String(format: "%064x", call),
                        groupIdHex: query.groupIdHex ?? "group",
                        sender: sender,
                        plaintext: call == 1 ? "stale result" : "current result",
                        recordedAt: UInt64(call)
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        state.presentGlobalMessageSearch()
        state.globalMessageSearchQuery = "stale"
        state.scheduleGlobalMessageSearch()
        #expect(await waitForSemaphore(firstQueryEntered, timeout: .now() + 2) == .success)

        state.globalMessageSearchQuery = "current"
        state.scheduleGlobalMessageSearch()
        releaseFirstQuery.signal()

        #expect(
            await waitFor(attempts: 300) {
                !state.isSearchingAllMessages && !state.globalMessageSearchResults.isEmpty
            })
        #expect(state.globalMessageSearchResults.allSatisfy { $0.snippet.match == "current" })
        #expect(!state.globalMessageSearchResults.contains { $0.snippet.leading.contains("stale") })

        let nextAccount = try #require(state.accounts.dropFirst().first)
        state.prepareForActiveAccountSwitch(to: nextAccount, preservingMessageCacheFor: nil)
        #expect(!state.isGlobalMessageSearchPresented)
        #expect(state.globalMessageSearchQuery.isEmpty)
        #expect(state.globalMessageSearchResults.isEmpty)
        #expect(!state.isSearchingAllMessages)
    }

    @MainActor
    @Test func globalMessageSearchNavigationLoadsAndCentersTargetsBeyondTwelvePages() async throws {
        let state = WorkspaceState.preview()
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        state.client = runtime
        let targetChat = try #require(state.activeChats.last)
        let sender = try #require(state.activeAccount).accountIdHex
        var records: [TimelineMessageRecordFfi] = []
        records.reserveCapacity(1_650)
        for index in 0..<1_650 {
            let record = timelineMessage(
                id: String(format: "%064x", index + 1),
                groupIdHex: targetChat.id,
                sender: sender,
                plaintext: "message \(index)",
                recordedAt: UInt64(index + 1)
            )
            records.append(record)
        }
        runtime.installTimelinePage(
            TimelinePageFfi(messages: records, hasMoreBefore: false, hasMoreAfter: false),
            groupIdHex: targetChat.id
        )
        let target = records[25]
        let result = GlobalMessageSearchResult(
            messageId: target.messageIdHex,
            groupId: targetChat.id,
            chatTitle: targetChat.title,
            senderName: "Desktop Account",
            timelineAt: target.timelineAt,
            snippet: GlobalMessageSearchSnippet(leading: "", match: "message", trailing: " 25")
        )

        await state.openGlobalMessageSearchResult(result)

        #expect(state.selectedChat?.id == targetChat.id)
        #expect(state.selectedTimelineContainsMessage(target.messageIdHex))
        #expect(state.pendingMessageNavigation?.messageId == target.messageIdHex)
        #expect(runtime.lastTimelineSubscription?.paginateBackwardsCount ?? 0 > 12)
    }

    @MainActor
    @Test func globalMessageSearchInvalidatesResultsWhenAVisibleChatIsDeleted() throws {
        let state = WorkspaceState.preview()
        let account = try #require(state.activeAccount)
        let deletedChat = try #require(state.activeChats.last)
        state.presentGlobalMessageSearch()
        state.globalMessageSearchQuery = "message"
        state.globalMessageSearchResults = [
            GlobalMessageSearchResult(
                messageId: String(repeating: "a", count: 64),
                groupId: deletedChat.id,
                chatTitle: deletedChat.title,
                senderName: account.displayName,
                timelineAt: 10,
                snippet: GlobalMessageSearchSnippet(leading: "", match: "message", trailing: "")
            )
        ]

        state.removeChat(groupIdHex: deletedChat.id, account: account)

        #expect(!state.activeChats.contains { $0.id == deletedChat.id })
        #expect(state.globalMessageSearchResults.isEmpty)
        #expect(state.globalMessageSearchQuery == "message")
        state.dismissGlobalMessageSearch()
    }

    @Test func globalMessageSearchStopsWhenHistoryCursorDoesNotAdvance() throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let sender = desktopAccount().accountIdHex
        let record = timelineMessage(
            id: String(repeating: "a", count: 64),
            groupIdHex: "group",
            sender: sender,
            plaintext: "matching message",
            recordedAt: 10
        )
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [record], hasMoreBefore: true, hasMoreAfter: false)
        }

        let results = try GlobalMessageSearchEngine.search(
            client: runtime,
            accountRef: "Desktop Account",
            localAccountId: sender,
            localDisplayName: "Desktop Account",
            scopes: [GlobalMessageSearchScope(groupId: "group", title: "Test Group")],
            query: "matching",
            checkCancellation: {}
        )

        #expect(results.map(\.messageId) == [record.messageIdHex])
        #expect(runtime.timelineMessageQueries.count == 2)
    }

    @Test func globalMessageSearchLargeHistoryKeepsWorkAndResultsBounded() throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let sender = desktopAccount().accountIdHex
        var records: [TimelineMessageRecordFfi] = []
        records.reserveCapacity(10_000)
        for index in 0..<10_000 {
            let record = timelineMessage(
                id: String(format: "%064x", index + 1),
                groupIdHex: "group",
                sender: sender,
                plaintext: "common searchable message \(index)",
                recordedAt: UInt64(index + 1)
            )
            records.append(record)
        }
        runtime.installTimelinePage(
            TimelinePageFfi(messages: records, hasMoreBefore: false, hasMoreAfter: false),
            groupIdHex: "group"
        )

        let results = try GlobalMessageSearchEngine.search(
            client: runtime,
            accountRef: "Desktop Account",
            localAccountId: sender,
            localDisplayName: "Desktop Account",
            scopes: [GlobalMessageSearchScope(groupId: "group", title: "Large Group")],
            query: "common searchable",
            checkCancellation: {}
        )

        #expect(results.count == GlobalMessageSearchEngine.resultLimit)
        #expect(results.first?.timelineAt == 10_000)
        #expect(results.last?.timelineAt == 9_951)
        #expect(runtime.timelineMessageQueries.count == 1)
    }

    @MainActor
    @Test func directChatUsesOtherMemberProfileForTitleAndAvatar() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let group = AppGroupRecordFfi(
            groupIdHex: "direct-group",
            endpoint: "",
            name: "",
            description: "",
            admins: [],
            relays: ["wss://relay.example"],
            nostrGroupIdHex: "",
            avatarUrl: nil,
            avatarDim: nil,
            avatarThumbhash: nil,
            imageHashHex: nil,
            encryptedMedia: encryptedMediaComponent(),
            disappearingMessageSecs: 0,
            archived: false,
            pendingConfirmation: false,
            selfMembership: .member,
            welcomerAccountIdHex: nil,
            viaWelcomeMessageIdHex: nil
        )
        runtime.installDirectGroup(
            group,
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didHydrateDirectPeer = await waitFor {
            state.activeChats.first?.title == "Alice Actual"
        }

        #expect(didHydrateDirectPeer)
        #expect(state.activeChats.first?.title == "Alice Actual")
        #expect(state.activeChats.first?.subtitle == "Direct message")
        #expect(state.activeChats.first?.avatarSeed == "alice1234567890alice1234567890alice1234567890alice1234567890")
        #expect(state.activeChats.first?.pictureURL == "https://example.com/alice.png")
        #expect(state.activeChats.first?.isDirect == true)
        #expect(runtime.refreshedProfileIds == [account.accountIdHex])
    }

    @MainActor
    @Test func namedGroupWithOneOtherMemberKeepsItsNameThroughEnrichment() async throws {
        // Regression: naming a chat with a single other member left it titled with that member's
        // name. Chat-list enrichment resolves a direct peer for any two-person roster, and the peer
        // projection outranked the group name — so "Book club" came back as "Alice Actual". mdk
        // classifies a named conversation as a group whatever its member count, and the name the
        // user typed is what the row has to say.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-named-group-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory)

        // A record left from an era when this conversation was a nameless two-person chat. Naming it
        // makes the record wrong, so enrichment has to drop it — otherwise clearing the name later
        // would put Alice back in the title.
        try store.write(
            ["book-club": RememberedDirectPeer(accountIdHex: aliceId, displayName: "Alice Actual", pictureURL: nil)],
            forAccountId: account.label
        )

        var namedGroup = messageGroup()
        namedGroup.groupIdHex = "book-club"
        namedGroup.name = "Book club"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            namedGroup,
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(directPeerMemoryStore: store, clientFactory: { runtime })

        await state.bootstrap()
        // The roster fetch is the enrichment pass this test is about, so wait for it rather than
        // for a title change — with the fix there is no change to observe.
        let didEnrich = await waitFor { (runtime.groupDetailsCallCounts["book-club"] ?? 0) >= 1 }
        #expect(didEnrich)
        // Bounded negative check: the buggy path retitles the row from the peer profile.
        let didRetitleFromPeer = await waitFor { state.activeChats.first?.title == "Alice Actual" }
        #expect(!didRetitleFromPeer)

        let chat = try #require(state.activeChats.first)
        #expect(chat.title == "Book club")
        #expect(chat.isDirect == false)
        #expect(chat.subtitle == "Book club")
        #expect(chat.avatarSeed == "book-club")
        #expect(chat.pictureURL == nil)
        // No peer was recorded either: a remembered peer for a named group would resurface as its
        // title the moment the roster emptied out.
        let accountId = try #require(state.activeAccountId)
        #expect(try store.loadAll()[accountId]?["book-club"] == nil)
        #expect(!runtime.refreshedProfileIds.contains(aliceId))
    }

    @MainActor
    @Test func newLastMessageChatRowPreservesDirectChatMetadataWithoutReenrichment() async throws {
        // Regression for #40/#251: a `.newLastMessage` single-row delta is metadata-invariant,
        // so it takes the `shouldEnrich: false` fast path (no per-row FFI fan-out). The
        // already-resolved direct-chat metadata (title/avatar/isDirect) must be preserved while
        // the fresh last-message preview is applied — verify the row still shows the resolved
        // peer profile without re-querying group details.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        // Deliver an incremental row update (the buggy path) carrying a fresh last message.
        let updatedRow = chatListRow(
            groupIdHex: "direct-group",
            title: "",
            preview: "See you soon.",
            sender: aliceId,
            timelineAt: 1_700_000_500
        )
        runtime.installChatListUpdates([
            .row(trigger: .newLastMessage, row: updatedRow)
        ])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didPreserveMetadata = await waitFor(attempts: 300) {
            state.activeChats.first?.title == "Alice Actual"
                && state.activeChats.first?.preview == "See you soon."
        }

        if !didPreserveMetadata {
            let chat = state.activeChats.first
            Issue.record(
                """
                Expected direct-chat metadata preservation. \
                title=\(chat?.title ?? "nil") preview=\(chat?.preview ?? "nil") \
                pictureURL=\(chat?.pictureURL ?? "nil") \
                detailsCalls=\(runtime.groupDetailsCallCounts["direct-group"] ?? 0)
                """
            )
        }
        #expect(didPreserveMetadata)
        #expect(state.activeChats.first?.isDirect == true)
        #expect(state.activeChats.first?.pictureURL == "https://example.com/alice.png")
        // The incremental row reuses the initial membership lookup for non-membership triggers;
        // it must not re-query group details just to refresh the last-message preview (#9).
        #expect((runtime.groupDetailsCallCounts["direct-group"] ?? 0) == 1)
    }

    @MainActor
    @Test func directChatKeepsDepartedPeerNameAfterTheOnlyOtherMemberLeaves() async throws {
        // MDK's roster only reports *current* members, so once the only other side of a DM leaves
        // there is nobody left to name the conversation and MDK projects the shortened group id as
        // its title. The chat must keep naming the peer it was a DM with — even on a fresh launch
        // whose runtime no longer knows that peer at all.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let aliceProfile = UserProfileMetadataFfi(
            name: "alice",
            displayName: "Alice Actual",
            about: nil,
            picture: "https://example.com/alice.png",
            nip05: nil,
            lud16: nil
        )
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-direct-peer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory)

        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: aliceProfile
        )
        let state = WorkspaceState(directPeerMemoryStore: store, clientFactory: { runtime })

        await state.bootstrap()
        let didResolvePeer = await waitFor { state.activeChats.first?.title == "Alice Actual" }
        #expect(didResolvePeer)
        let accountId = try #require(state.activeAccountId)
        #expect(try store.loadAll()[accountId]?["direct-group"]?.accountIdHex == aliceId)

        // Alice leaves. A fresh launch sees a roster holding only this account, and this runtime
        // cannot resolve her profile either — the recorded copy is the only thing left.
        let departedRuntime = FakeMarmotRuntime(accounts: [account])
        departedRuntime.installGroupDetails(
            GroupDetailsFfi(
                group: directGroup(),
                members: [soleRemainingSelfMember(accountIdHex: account.accountIdHex)]
            )
        )
        departedRuntime.accountIdsMissingProfiles.insert(aliceId)
        let relaunched = WorkspaceState(directPeerMemoryStore: store, clientFactory: { departedRuntime })

        await relaunched.bootstrap()
        let didKeepDepartedPeer = await waitFor { relaunched.activeChats.first?.title == "Alice Actual" }

        if !didKeepDepartedPeer {
            Issue.record("Expected the departed peer's name. title=\(relaunched.activeChats.first?.title ?? "nil")")
        }
        #expect(didKeepDepartedPeer)
        #expect(relaunched.activeChats.first?.avatarSeed == aliceId)
        #expect(relaunched.activeChats.first?.pictureURL == "https://example.com/alice.png")
        #expect(relaunched.activeChats.first?.isDirect == true)
    }

    @MainActor
    @Test func departedDirectPeerIsRecoveredFromTheTranscriptWhenNothingWasRecorded() async throws {
        // Every DM whose peer left before this device ever recorded them — including all of them
        // on the build that introduces the record — has nothing stored. Their messages outlive
        // their membership, so the transcript still says who this chat was with.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            GroupDetailsFfi(
                group: directGroup(),
                members: [soleRemainingSelfMember(accountIdHex: account.accountIdHex)]
            )
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "from-alice",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "See you around.",
                    kind: 9,
                    recordedAt: 1_700_000_100
                ),
                appMessage(
                    id: "from-self",
                    direction: "sent",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Bye!",
                    kind: 9,
                    recordedAt: 1_700_000_200
                ),
            ],
            groupIdHex: "direct-group"
        )
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        // `FakeMarmotRuntime.storageRootPath` is already isolated per test, so this injection is
        // about naming the directory the assertions below reason over, not about isolation.
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-direct-peer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let state = WorkspaceState(
            directPeerMemoryStore: DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        // The newest message is this account's own, so this only passes by paging back for the
        // newest message that is not.
        let didRecoverPeer = await waitFor { state.activeChats.first?.title == "Alice Actual" }

        if !didRecoverPeer {
            Issue.record(
                "Expected the peer recovered from the transcript. title=\(state.activeChats.first?.title ?? "nil")"
            )
        }
        #expect(didRecoverPeer)
        #expect(state.activeChats.first?.avatarSeed == aliceId)
        #expect(state.activeChats.first?.isDirect == true)
    }

    @MainActor
    @Test func noteToSelfChatRecoversNoPeerAndScansItsTranscriptOnlyOnce() async throws {
        // A note-to-self chat legitimately has no other member and no other sender. It must keep
        // its own identity, and the fruitless scan must not repeat on every chat-list delta.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            GroupDetailsFfi(
                group: directGroup(),
                members: [soleRemainingSelfMember(accountIdHex: account.accountIdHex)]
            )
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "self-note",
                    direction: "sent",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Remember the milk.",
                    kind: 9,
                    recordedAt: 1_700_000_100
                )
            ],
            groupIdHex: "direct-group"
        )
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-direct-peer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let state = WorkspaceState(
            directPeerMemoryStore: DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let didEnrich = await waitFor { (runtime.groupDetailsCallCounts["direct-group"] ?? 0) >= 1 }
        let didScan = await waitFor { state.unrecoverableDirectPeerGroupIds.contains("direct-group") }

        #expect(didEnrich)
        #expect(didScan)
        #expect(state.activeChats.first?.avatarSeed == "direct-group")
        let accountId = try #require(state.activeAccountId)
        #expect(state.rememberedDirectPeer(groupIdHex: "direct-group", accountId: accountId) == nil)
    }

    @MainActor
    @Test func departedDirectPeerPrefersTheirCurrentProfileOverTheRecordedCopy() async throws {
        // A departed peer's profile outlives their membership, so a fresh lookup must still win;
        // the recorded name is only the offline fallback.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-direct-peer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory)

        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(directPeerMemoryStore: store, clientFactory: { runtime })
        await state.bootstrap()
        let didResolvePeer = await waitFor { state.activeChats.first?.title == "Alice Actual" }
        #expect(didResolvePeer)

        let departedRuntime = FakeMarmotRuntime(accounts: [account])
        departedRuntime.installGroupDetails(
            GroupDetailsFfi(
                group: directGroup(),
                members: [soleRemainingSelfMember(accountIdHex: account.accountIdHex)]
            )
        )
        departedRuntime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Renamed",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let relaunched = WorkspaceState(directPeerMemoryStore: store, clientFactory: { departedRuntime })

        await relaunched.bootstrap()
        let didUseCurrentProfile = await waitFor { relaunched.activeChats.first?.title == "Alice Renamed" }

        #expect(didUseCurrentProfile)
    }

    @MainActor
    @Test func namedGroupKeepsItsOwnNameAfterEveryOtherMemberLeaves() async throws {
        // A named group is not a DM. Its name is still the right title once it empties out, so the
        // peer remembered from when it happened to hold two people must not hijack it.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-direct-peer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory)

        let runtime = FakeMarmotRuntime(accounts: [account])
        // The conversation is nameless while it holds two people — that is the only shape that is
        // titled from a peer, and so the only one that records one. It is named in the second phase
        // below, which is the sequence a real group takes to get here.
        var namelessGroup = messageGroup()
        namelessGroup.name = ""
        runtime.installDirectGroup(
            namelessGroup,
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(directPeerMemoryStore: store, clientFactory: { runtime })
        await state.bootstrap()
        let didResolvePeer = await waitFor { state.activeChats.first?.title == "Alice Actual" }
        #expect(didResolvePeer)

        let departedRuntime = FakeMarmotRuntime(accounts: [account])
        departedRuntime.installGroupDetails(
            GroupDetailsFfi(
                group: messageGroup(),
                members: [soleRemainingSelfMember(accountIdHex: account.accountIdHex)]
            )
        )
        let relaunched = WorkspaceState(directPeerMemoryStore: store, clientFactory: { departedRuntime })

        await relaunched.bootstrap()
        // A correct outcome here is "nothing changes", so there is no positive witness to wait on:
        // let enrichment run to completion and assert the remembered peer never took the title.
        let didEnrich = await waitFor { (departedRuntime.groupDetailsCallCounts["group"] ?? 0) >= 1 }
        let didHijackTitle = await waitFor(attempts: 30) {
            relaunched.activeChats.first?.title == "Alice Actual"
        }

        #expect(didEnrich)
        #expect(!didHijackTitle)
        #expect(relaunched.activeChats.first?.title == "Test Group")
        #expect(relaunched.activeChats.first?.subtitle == "Test Group")
    }

    @MainActor
    @Test func directPeerMemoryIsDroppedOnceTheConversationHoldsSeveralOtherMembers() async throws {
        // Growing past two people makes a single peer the wrong description of the conversation,
        // so the record must go — otherwise it would resurface as the title when the group empties.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-direct-peer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory)

        let runtime = FakeMarmotRuntime(accounts: [account])
        // Nameless while it is a two-person chat: only that shape is titled from a peer, and so only
        // that shape records one for the growth below to drop.
        var namelessGroup = messageGroup()
        namelessGroup.name = ""
        runtime.installDirectGroup(
            namelessGroup,
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(directPeerMemoryStore: store, clientFactory: { runtime })
        await state.bootstrap()
        let didResolvePeer = await waitFor { state.activeChats.first?.title == "Alice Actual" }
        #expect(didResolvePeer)
        let accountId = try #require(state.activeAccountId)
        #expect(try store.loadAll()[accountId]?["group"]?.accountIdHex == aliceId)

        let grownRuntime = FakeMarmotRuntime(accounts: [account])
        grownRuntime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let regrouped = WorkspaceState(directPeerMemoryStore: store, clientFactory: { grownRuntime })

        await regrouped.bootstrap()
        let didForgetPeer = await waitFor { ((try? store.loadAll())?[accountId]?["group"]) == nil }

        #expect(didForgetPeer)
        #expect(regrouped.activeChats.first?.title == "Test Group")
    }

    @Test func directPeerMemoryStoreUsesOpaqueProtectedBackupExcludedPerAccountFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-direct-peer-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = DirectPeerMemoryFileStore(fileManager: fileManager, directoryURL: directory)
        let alice = RememberedDirectPeer(
            accountIdHex: "alice",
            displayName: "Alice",
            pictureURL: "https://example.com/alice.png"
        )
        let bob = RememberedDirectPeer(accountIdHex: "bob", displayName: nil, pictureURL: nil)

        try store.write(["direct-group": alice], forAccountId: "account-one")
        try store.write(["other-group": bob], forAccountId: "account-two")

        #expect(
            try store.loadAll()
                == [
                    "account-one": ["direct-group": alice],
                    "account-two": ["other-group": bob],
                ]
        )
        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExcludedFromBackupKey],
            options: [.skipsHiddenFiles]
        )
        #expect(files.count == 2)
        for file in files {
            #expect(file.pathExtension == "json")
            #expect(file.deletingPathExtension().lastPathComponent.count == 64)
            #expect(!file.lastPathComponent.contains("account-one"))
            #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }

        try store.remove(forAccountId: "account-one")
        #expect(try store.loadAll() == ["account-two": ["other-group": bob]])

        try store.removeAll()
        #expect(try store.loadAll().isEmpty)
    }

    @MainActor
    @Test func mentionRosterWarmUpFiresForDirectChatsWithAColdMemberCache() async throws {
        let summary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [summary])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: summary.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let account = AccountItem(
            id: summary.label,
            accountRef: summary.label,
            displayName: summary.label,
            accountIdHex: summary.accountIdHex
        )
        // Seed the chat in memory rather than via `bootstrap()`, so the member cache starts cold
        // and the warm-up is the only thing that can fill it.
        let direct = ChatItem(
            id: "direct-group",
            title: "Alice",
            subtitle: "Direct message",
            preview: "",
            updatedAt: nil,
            avatarSeed: aliceId,
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true,
            hasAuthoritativeConversationKind: true
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [direct]],
            clientFactory: { runtime }
        )
        state.activeAccountId = account.id
        state.selection = .chat(direct.id)
        state.client = runtime

        #expect(state.mentionRoster().isEmpty)
        state.ensureMentionRosterLoaded()
        let didWarmRoster = await waitFor { !state.mentionRoster().isEmpty }

        #expect(didWarmRoster)
        #expect(state.mentionRoster().map(\.displayName) == ["Alice"])
        #expect((runtime.groupDetailsCallCounts["direct-group"] ?? 0) == 1)
    }

    @MainActor
    @Test func chatListTriggerEnrichmentGatingMatchesMetadataInvariance() {
        // The enrichment gate must skip exactly the metadata-invariant triggers and enrich the
        // rest, so read-state-only deltas never pay for the per-row FFI fan-out (#251).
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })

        let metadataInvariant: [ChatListUpdateTriggerFfi] = [
            .newLastMessage, .lastMessageDeleted, .pendingConfirmationChanged, .unreadChanged,
        ]
        for trigger in metadataInvariant {
            #expect(!state.chatListTriggerRequiresEnrichment(trigger))
        }

        let metadataChanging: [ChatListUpdateTriggerFfi] = [
            .newGroup, .archiveChanged, .membershipChanged, .snapshotRefresh, .removed,
        ]
        for trigger in metadataChanging {
            #expect(state.chatListTriggerRequiresEnrichment(trigger))
        }
    }

    @Test func chatListOrderingUpdatesSingleRowWithoutResortingWholeList() {
        let newest = chatListOrderingTestItem(id: "newest", title: "Newest", updatedAt: 300)
        let middle = chatListOrderingTestItem(id: "middle", title: "Middle", preview: "old", updatedAt: 200)
        let oldest = chatListOrderingTestItem(id: "oldest", title: "Oldest", updatedAt: 100)

        let updatedMiddle = chatListOrderingTestItem(
            id: "middle",
            title: "Middle",
            preview: "new read-state preview",
            updatedAt: 200,
            unreadCount: 0
        )
        let updated = ChatListOrdering.upserting(updatedMiddle, into: [newest, middle, oldest])

        #expect(updated.map(\.id) == ["newest", "middle", "oldest"])
        #expect(updated[1].preview == "new read-state preview")
        #expect(updated[1].unreadCount == 0)
    }

    @Test func chatListOrderingMovesSingleRowWithBinaryInsertionWhenSortKeyChanges() {
        let newest = chatListOrderingTestItem(id: "newest", title: "Newest", updatedAt: 300)
        let middle = chatListOrderingTestItem(id: "middle", title: "Middle", updatedAt: 200)
        let oldest = chatListOrderingTestItem(id: "oldest", title: "Oldest", updatedAt: 100)

        let promotedOldest = chatListOrderingTestItem(id: "oldest", title: "Oldest", updatedAt: 400)
        let promoted = ChatListOrdering.upserting(promotedOldest, into: [newest, middle, oldest])
        #expect(promoted.map(\.id) == ["oldest", "newest", "middle"])

        let inserted = chatListOrderingTestItem(id: "inserted", title: "Inserted", updatedAt: 250)
        let withInserted = ChatListOrdering.upserting(inserted, into: [newest, middle, oldest])
        #expect(withInserted.map(\.id) == ["newest", "inserted", "middle", "oldest"])
    }

    @Test func chatListOrderingInsertsNilUpdatedAtRowsAfterDatedChats() {
        let newest = chatListOrderingTestItem(id: "newest", title: "Newest", updatedAt: 300)
        let oldest = chatListOrderingTestItem(id: "oldest", title: "Oldest", updatedAt: 100)
        let optimistic = chatListOrderingTestItem(id: "optimistic", title: "Alice", date: nil)

        let withOptimistic = ChatListOrdering.upserting(optimistic, into: [newest, oldest])

        #expect(withOptimistic.map(\.id) == ["newest", "oldest", "optimistic"])
    }

    @Test func chatListOrderingMovesSingleRowWhenTitleTieBreakerChanges() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let alpha = chatListOrderingTestItem(id: "alpha", title: "Alpha", date: timestamp)
        let bravo = chatListOrderingTestItem(id: "bravo", title: "Bravo", date: timestamp)
        let zulu = chatListOrderingTestItem(id: "zulu", title: "Zulu", date: timestamp)

        let renamedZulu = chatListOrderingTestItem(id: "zulu", title: "Beta", date: timestamp)
        let renamed = ChatListOrdering.upserting(renamedZulu, into: [alpha, bravo, zulu])

        #expect(renamed.map(\.id) == ["alpha", "zulu", "bravo"])
        #expect(renamed.map(\.title) == ["Alpha", "Beta", "Bravo"])
    }

    @Test func chatListOrderingStablyPartitionsPinnedChatsAcrossLiveUpserts() {
        let unpinnedNewest = chatListOrderingTestItem(id: "unpinned-newest", title: "Newest", updatedAt: 400)
        let pinnedNewest = chatListOrderingTestItem(id: "pinned-newest", title: "Pinned Newest", updatedAt: 300)
        let unpinnedOlder = chatListOrderingTestItem(id: "unpinned-older", title: "Older", updatedAt: 200)
        let pinnedOlder = chatListOrderingTestItem(id: "pinned-older", title: "Pinned Older", updatedAt: 100)
        let pinnedIds: Set<String> = [pinnedNewest.id, pinnedOlder.id]

        let sorted = ChatListOrdering.sorted(
            [unpinnedOlder, pinnedOlder, unpinnedNewest, pinnedNewest],
            pinnedChatIds: pinnedIds
        )
        #expect(sorted.map(\.id) == [pinnedNewest.id, pinnedOlder.id, unpinnedNewest.id, unpinnedOlder.id])

        let incomingUnpinned = chatListOrderingTestItem(
            id: unpinnedOlder.id,
            title: unpinnedOlder.title,
            preview: "new incoming message",
            updatedAt: 500
        )
        let afterUnpinnedUpdate = ChatListOrdering.upserting(
            incomingUnpinned,
            into: sorted,
            pinnedChatIds: pinnedIds
        )
        #expect(
            afterUnpinnedUpdate.map(\.id)
                == [pinnedNewest.id, pinnedOlder.id, unpinnedOlder.id, unpinnedNewest.id]
        )

        let incomingPinned = chatListOrderingTestItem(
            id: pinnedOlder.id,
            title: pinnedOlder.title,
            preview: "new pinned message",
            updatedAt: 600
        )
        let afterPinnedUpdate = ChatListOrdering.upserting(
            incomingPinned,
            into: afterUnpinnedUpdate,
            pinnedChatIds: pinnedIds
        )
        #expect(
            afterPinnedUpdate.map(\.id)
                == [pinnedOlder.id, pinnedNewest.id, unpinnedOlder.id, unpinnedNewest.id]
        )
    }

    @MainActor
    @Test func pinnedChatStateIsAccountScopedForSharedGroupIds() throws {
        let accounts = Array(AccountItem.samples.prefix(2))
        let firstAccount = try #require(accounts.first)
        let secondAccount = try #require(accounts.last)
        let firstChat = chatListOrderingTestItem(id: "shared-group", title: "First account", updatedAt: 100)
        let secondChat = chatListOrderingTestItem(id: "shared-group", title: "Second account", updatedAt: 100)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-pinned-account-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinnedChatFileStore(directoryURL: directory)
        let state = WorkspaceState(
            accounts: accounts,
            chatsByAccount: [
                firstAccount.id: [firstChat],
                secondAccount.id: [secondChat],
            ],
            pinnedChatStore: store,
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )

        state.activeAccountId = firstAccount.id
        state.setChatPinned(firstChat, pinned: true)

        #expect(state.isChatPinned(accountId: firstAccount.id, groupIdHex: firstChat.id))
        #expect(!state.isChatPinned(accountId: secondAccount.id, groupIdHex: secondChat.id))

        state.activeAccountId = secondAccount.id
        state.setChatPinned(secondChat, pinned: true)
        state.setChatPinned(secondChat, pinned: false)

        #expect(state.isChatPinned(accountId: firstAccount.id, groupIdHex: firstChat.id))
        #expect(!state.isChatPinned(accountId: secondAccount.id, groupIdHex: secondChat.id))
        #expect(try store.loadAll() == [firstAccount.id: [firstChat.id]])
    }

    @MainActor
    @Test func pinnedChatStateSurvivesProjectionRefreshAndLiveRowUpdate() async throws {
        let account = AccountItem.samples[0]
        let pinned = chatListOrderingTestItem(id: "pinned", title: "Pinned", updatedAt: 100)
        let unpinned = chatListOrderingTestItem(id: "unpinned", title: "Unpinned", updatedAt: 200)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-pinned-projection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [unpinned, pinned]],
            pinnedChatStore: PinnedChatFileStore(directoryURL: directory),
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.setChatPinned(pinned, pinned: true)

        await state.applyChatRows(
            [
                chatListRow(
                    groupIdHex: unpinned.id,
                    title: unpinned.title,
                    preview: "newer unpinned snapshot",
                    sender: "alice",
                    timelineAt: 500
                ),
                chatListRow(
                    groupIdHex: pinned.id,
                    title: pinned.title,
                    preview: "older pinned snapshot",
                    sender: "bob",
                    timelineAt: 300
                ),
            ],
            account: account
        )

        #expect(state.activeChats.map(\.id) == [pinned.id, unpinned.id])
        #expect(state.isChatPinned(pinned))

        await state.applyChatRow(
            chatListRow(
                groupIdHex: unpinned.id,
                title: unpinned.title,
                preview: "newest live message",
                sender: "alice",
                timelineAt: 700
            ),
            account: account,
            shouldEnrich: false
        )

        #expect(state.activeChats.map(\.id) == [pinned.id, unpinned.id])
        #expect(state.activeChats.last?.preview == "newest live message")
        #expect(state.isChatPinned(pinned))
    }

    @MainActor
    @Test func selectedChatObservationInvalidatesOnSelectedChatMetadataDelta() async throws {
        // Regression for #388: `selectedChat` resolves through ignored O(1) indexes, so it must
        // still read an observed token that live chat-list deltas bump. Otherwise the open
        // conversation keeps rendering a frozen ChatItem after renames/membership-ended flips.
        let account = AccountItem.samples[0]
        let selected = ChatItem(
            id: "selected-chat",
            title: "Original group",
            subtitle: "Group message",
            preview: "before",
            updatedAt: Date(timeIntervalSince1970: 100),
            avatarSeed: "selected-chat",
            pictureURL: nil,
            unreadCount: 0
        )
        let background = ChatItem(
            id: "background-chat",
            title: "Background group",
            subtitle: "Group message",
            preview: "background",
            updatedAt: Date(timeIntervalSince1970: 90),
            avatarSeed: "background-chat",
            pictureURL: nil,
            unreadCount: 0
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [selected, background]],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.selection = .chat(selected.id)

        #expect(state.selectedChat?.title == "Original group")
        #expect(state.selectedChat?.isNoLongerMember == false)

        let invalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.selectedChat?.title
            _ = state.selectedChat?.isNoLongerMember
        } onChange: {
            invalidated.markInvalidated()
        }

        state.upsertChat(
            ChatItem(
                id: selected.id,
                title: "Renamed group",
                subtitle: selected.subtitle,
                preview: "after",
                updatedAt: selected.updatedAt,
                avatarSeed: "renamed-avatar",
                pictureURL: selected.pictureURL,
                unreadCount: selected.unreadCount,
                unreadMentionCount: selected.unreadMentionCount,
                isDirect: selected.isDirect,
                pendingConfirmation: selected.pendingConfirmation,
                selfMembership: .removed
            ),
            forAccountId: account.id
        )

        #expect(invalidated.value)
        #expect(state.selectedChat?.title == "Renamed group")
        #expect(state.selectedChat?.avatarSeed == "renamed-avatar")
        #expect(state.selectedChat?.isNoLongerMember == true)
    }

    @MainActor
    @Test func filteredChatsObservationInvalidatesOnChatListDeltaAfterCacheHit() async throws {
        // Regression for #390: `filteredChats` is memoized through ignored cache state, but each
        // body pass still has to read the observed chat list. Otherwise a cache-hit pass drops the
        // sidebar's `chatsByAccount` subscription and background-chat updates do not repaint it.
        let account = AccountItem.samples[0]
        let selected = ChatItem(
            id: "selected-chat",
            title: "Selected group",
            subtitle: "Group message",
            preview: "selected preview",
            updatedAt: Date(timeIntervalSince1970: 100),
            avatarSeed: "selected-chat",
            pictureURL: nil,
            unreadCount: 0
        )
        let background = ChatItem(
            id: "background-chat",
            title: "Background group",
            subtitle: "Group message",
            preview: "old background",
            updatedAt: Date(timeIntervalSince1970: 90),
            avatarSeed: "background-chat",
            pictureURL: nil,
            unreadCount: 0
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [selected, background]],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.selection = .chat(selected.id)

        #expect(state.filteredChats.map(\.id) == [selected.id, background.id])

        let invalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.filteredChats.map(\.id)
        } onChange: {
            invalidated.markInvalidated()
        }

        state.upsertChat(
            ChatItem(
                id: background.id,
                title: background.title,
                subtitle: background.subtitle,
                preview: "new background",
                updatedAt: Date(timeIntervalSince1970: 200),
                avatarSeed: background.avatarSeed,
                pictureURL: background.pictureURL,
                unreadCount: 3
            ),
            forAccountId: account.id
        )

        #expect(invalidated.value)
        #expect(state.filteredChats.map(\.id) == [background.id, selected.id])
        #expect(state.filteredChats.first?.preview == "new background")
        #expect(state.filteredChats.first?.unreadCount == 3)
    }

    @MainActor
    @Test func workspaceChatIndexesAndFilterCachePerformanceGuard() async throws {
        let account = AccountItem.samples[0]
        let chats = performanceChatItems(count: 5_000)
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: chats],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.selection = .chat("perf-chat-4999")

        #expect(state.selectedChat?.id == "perf-chat-4999")
        #expect(state.chatIndex(accountId: account.id, chatId: "perf-chat-4999") == 4_999)

        let selectedLookupMilliseconds = measuredMilliseconds {
            for _ in 0..<50_000 {
                _ = state.selectedChat?.id
            }
        }

        state.searchText = "launch"
        #expect(state.filteredChats.count == 50)
        let cachedFilterMilliseconds = measuredMilliseconds {
            for _ in 0..<5_000 {
                _ = state.filteredChats.count
            }
        }

        let indexedUpsertMilliseconds = measuredMilliseconds {
            for offset in 0..<1_000 {
                let id = "perf-chat-\((offset * 37) % chats.count)"
                guard let current = state.chatItem(accountId: account.id, chatId: id) else {
                    Issue.record("Missing chat \(id)")
                    return
                }
                state.upsertChat(
                    ChatItem(
                        id: current.id,
                        title: current.title,
                        subtitle: current.subtitle,
                        preview: "updated preview \(offset)",
                        updatedAt: current.updatedAt,
                        avatarSeed: current.avatarSeed,
                        pictureURL: current.pictureURL,
                        unreadCount: current.unreadCount,
                        unreadMentionCount: current.unreadMentionCount,
                        isDirect: current.isDirect,
                        pendingConfirmation: current.pendingConfirmation
                    ),
                    forAccountId: account.id
                )
            }
        }

        print(
            "PERF chat_selected_lookup_ms=\(formatMilliseconds(selectedLookupMilliseconds)) lookups=50000 chats=5000"
        )
        print("PERF chat_filter_cached_ms=\(formatMilliseconds(cachedFilterMilliseconds)) hits=5000 chats=5000")
        print("PERF chat_indexed_upsert_ms=\(formatMilliseconds(indexedUpsertMilliseconds)) updates=1000 chats=5000")

        #expect(selectedLookupMilliseconds < 60 * performanceSlack)
        #expect(cachedFilterMilliseconds < 40 * performanceSlack)
        #expect(indexedUpsertMilliseconds < 500 * performanceSlack)
        #expect(state.selectedChat?.id == "perf-chat-4999")
    }

    @Test func readStateChatRowsPreserveResolvedMetadataWhenSkippingEnrichment() {
        let current = ChatItem(
            id: "direct-group",
            title: "Alice Actual",
            subtitle: "Direct message",
            preview: "old preview",
            updatedAt: Date(timeIntervalSince1970: 100),
            avatarSeed: "alice-id",
            pictureURL: "https://example.com/alice.png",
            unreadCount: 4,
            isDirect: true,
            pendingConfirmation: false
        )
        let readState = ChatItem(
            id: "direct-group",
            title: "direct-group",
            subtitle: "Group message",
            preview: "new read marker preview",
            updatedAt: Date(timeIntervalSince1970: 200),
            avatarSeed: "direct-group",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: false,
            pendingConfirmation: true,
            selfMembership: .removed
        )

        let merged = ChatListOrdering.preservingResolvedMetadata(in: readState, from: current)

        #expect(merged.title == "Alice Actual")
        #expect(merged.subtitle == "Direct message")
        #expect(merged.avatarSeed == "alice-id")
        #expect(merged.pictureURL == "https://example.com/alice.png")
        #expect(merged.isDirect)
        #expect(merged.preview == "new read marker preview")
        #expect(merged.updatedAt == Date(timeIntervalSince1970: 200))
        #expect(merged.unreadCount == 0)
        #expect(merged.pendingConfirmation)
        // Membership state rides the incoming row, like pendingConfirmation — it
        // is not part of the enrichment-resolved metadata being preserved.
        #expect(merged.selfMembership == .removed)
    }

    @MainActor
    @Test func readMarkerChatRowPreservesResolvedDirectMetadataWhenSkippingEnrichment() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "latest",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Latest message",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        let isActive = MutableFlag(false)
        let state = WorkspaceState(
            appActivityProvider: { isActive.value },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let didResolveDirectMetadata = await waitFor(attempts: 300) {
            state.activeChats.first?.title == "Alice Actual"
                && state.activeChats.first?.pictureURL == "https://example.com/alice.png"
                && state.activeChats.first?.isDirect == true
        }
        #expect(didResolveDirectMetadata)
        #expect(runtime.markedReadMessageIds.isEmpty)

        isActive.value = true
        await state.handleConversationVisibilityChange()

        #expect(runtime.markedReadMessageIds == ["latest"])
        #expect(state.activeChats.first?.title == "Alice Actual")
        #expect(state.activeChats.first?.subtitle == "Direct message")
        #expect(state.activeChats.first?.avatarSeed == aliceId)
        #expect(state.activeChats.first?.pictureURL == "https://example.com/alice.png")
        #expect(state.activeChats.first?.isDirect == true)
        #expect(state.activeChats.first?.preview == "\(isolated("Alice Actual")): Latest message")
    }

    @MainActor
    @Test func repeatedReadMarkerRowsWithMissingMetadataDoNotRepeatGroupDetailsLookups() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cached",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Actual",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        runtime.groupDetailsFailureGroupIds.insert("direct-group")
        runtime.installMessages(
            [
                appMessage(
                    id: "m1",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "first",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        runtime.installTimelineUpdates(
            [
                .projection(
                    update: RuntimeProjectionUpdateFfi(
                        accountIdHex: account.accountIdHex,
                        accountLabel: account.label,
                        update: TimelineProjectionUpdateFfi(
                            groupIdHex: "direct-group",
                            messages: [],
                            changes: [
                                .upsert(
                                    trigger: .newMessage,
                                    message: timelineMessage(
                                        id: "m2",
                                        groupIdHex: "direct-group",
                                        sender: account.accountIdHex,
                                        plaintext: "second",
                                        recordedAt: 1_700_000_020
                                    ))
                            ],
                            chatListRow: nil,
                            chatListTrigger: .newLastMessage
                        )
                    )),
                .projection(
                    update: RuntimeProjectionUpdateFfi(
                        accountIdHex: account.accountIdHex,
                        accountLabel: account.label,
                        update: TimelineProjectionUpdateFfi(
                            groupIdHex: "direct-group",
                            messages: [],
                            changes: [
                                .upsert(
                                    trigger: .newMessage,
                                    message: timelineMessage(
                                        id: "m3",
                                        groupIdHex: "direct-group",
                                        sender: account.accountIdHex,
                                        plaintext: "third",
                                        recordedAt: 1_700_000_030
                                    ))
                            ],
                            chatListRow: nil,
                            chatListTrigger: .newLastMessage
                        )
                    )),
            ], groupIdHex: "direct-group")
        runtime.timelineStreamEndsAfterUpdates = true
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let didMarkAllVisibleMessages = await waitFor(attempts: 300) {
            runtime.markedReadMessageIds == ["m1", "m2", "m3"]
        }

        #expect(didMarkAllVisibleMessages)
        #expect((runtime.groupDetailsCallCounts["direct-group"] ?? 0) <= 2)
    }

    // MARK: - Workspace generation counters (issue #182)

    @MainActor
    @Test func workspaceStaleResultGenerationCountersWrapAndRetainOwnership() {
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        state.newChatQuery = "alice@example.com"

        state.seedStaleResultGenerationsForTesting(UInt64.max)
        let wrappedGenerations = state.bumpStaleResultGenerationsForTesting()

        #expect(wrappedGenerations.newChatLookup == 0)
        #expect(wrappedGenerations.groupImageSearch == 0)
        #expect(wrappedGenerations.groupDetailsLoad == 0)

        let currentOwnership = state.ownsStaleResultGenerationsForTesting(
            generation: 0
        )
        #expect(currentOwnership.newChatLookup)
        #expect(currentOwnership.groupImageSearch)
        #expect(currentOwnership.groupDetailsLoad)

        let staleOwnership = state.ownsStaleResultGenerationsForTesting(
            generation: UInt64.max
        )
        #expect(!staleOwnership.newChatLookup)
        #expect(!staleOwnership.groupImageSearch)
        #expect(!staleOwnership.groupDetailsLoad)

        state.newChatQuery = "bob@example.com"
        let editedQueryOwnership = state.ownsStaleResultGenerationsForTesting(
            generation: 0
        )
        #expect(editedQueryOwnership.newChatLookup)
    }

    // MARK: - ChatListRowEnrichmentTracker (issue #40 ownership invariants)

    @Test func enrichmentTrackerStaleTaskAfterReloadDoesNotDropNewerTask() {
        // Regression for the adversarial review on PR #62: a per-group generation counter that
        // reset on `cancelAll()` (reload / account switch) reused token `1`, so an old canceled
        // task finishing afterwards matched the *new* task's reused token and dropped its slot.
        // Tokens are now process-monotonic and never reused, so this must not happen.
        var tracker = ChatListRowEnrichmentTracker()
        let group = "direct-group"

        // 1. Incremental update starts task A for the group.
        let tokenA = tracker.beginTask(forGroup: group)
        tracker.register(task: Task {}, forGroup: group, token: tokenA)
        #expect(tracker.currentToken(forGroup: group) == tokenA)

        // 2. A full snapshot / reload (or listener stop) cancels everything and clears state.
        tracker.cancelAll()
        #expect(tracker.trackedTaskCount == 0)
        #expect(tracker.currentToken(forGroup: group) == nil)

        // 3. A later incremental update starts task B for the same group. Its token must differ
        //    from A's — the sequence is not reset by `cancelAll()`.
        let tokenB = tracker.beginTask(forGroup: group)
        tracker.register(task: Task {}, forGroup: group, token: tokenB)
        #expect(tokenB != tokenA)
        #expect(tracker.currentToken(forGroup: group) == tokenB)

        // 4. The old canceled task A finally unwinds and runs its cleanup with its stale token.
        //    It must be a no-op: B still owns the slot.
        tracker.finishTask(forGroup: group, token: tokenA)
        #expect(tracker.currentToken(forGroup: group) == tokenB)
        #expect(tracker.trackedTaskCount == 1)

        // 5. When B itself finishes with its own token, the slot is released cleanly.
        tracker.finishTask(forGroup: group, token: tokenB)
        #expect(tracker.currentToken(forGroup: group) == nil)
        #expect(tracker.trackedTaskCount == 0)
    }

    @Test func enrichmentTrackerNewerUpdateSupersedesInFlightTask() {
        // A newer row update for the same group supersedes (coalesces) the in-flight one: the
        // older task's later cleanup must not drop the newer task's slot.
        var tracker = ChatListRowEnrichmentTracker()
        let group = "g"

        let first = tracker.beginTask(forGroup: group)
        tracker.register(task: Task {}, forGroup: group, token: first)
        let second = tracker.beginTask(forGroup: group)
        tracker.register(task: Task {}, forGroup: group, token: second)
        #expect(second != first)
        #expect(tracker.currentToken(forGroup: group) == second)

        // Stale older task cleanup is ignored; the newer task keeps the slot.
        tracker.finishTask(forGroup: group, token: first)
        #expect(tracker.currentToken(forGroup: group) == second)
        #expect(tracker.trackedTaskCount == 1)
    }

    @Test func enrichmentTrackerLateRegistrationForStaleTokenIsRejected() {
        // If a task's `register` lands after a newer `beginTask` for the same group (interleaving
        // on the main actor), the stale registration must not clobber the newer owner.
        var tracker = ChatListRowEnrichmentTracker()
        let group = "g"

        let stale = tracker.beginTask(forGroup: group)
        let current = tracker.beginTask(forGroup: group)
        // Late registration for the stale token is dropped.
        tracker.register(task: Task {}, forGroup: group, token: stale)
        tracker.register(task: Task {}, forGroup: group, token: current)
        #expect(tracker.currentToken(forGroup: group) == current)
        #expect(tracker.trackedTaskCount == 1)
    }

    @MainActor
    @Test func sidebarArchiveMovesChatToArchivedSection() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-pinned-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinnedChatStore = PinnedChatFileStore(directoryURL: directory)
        let state = WorkspaceState(pinnedChatStore: pinnedChatStore, clientFactory: { runtime })

        await state.bootstrap()
        let chat = try #require(state.activeChats.first { $0.id == "group" })
        let accountId = try #require(state.activeAccountId)
        state.setChatPinned(chat, pinned: true)
        #expect(state.activeChats.first?.id == chat.id)

        await state.setChatArchived(chat, archived: true)

        #expect(runtime.archivedGroup == ArchivedGroup(groupIdHex: "group", archived: true))
        #expect(state.activeChats.map(\.id) == ["direct-group"])
        #expect(state.archivedChats.count == 1)
        #expect(state.archivedChats.first?.id == chat.id)
        #expect(state.archivedChats.first?.subtitle == L10n.string("Archived"))
        #expect(state.isChatPinned(accountId: accountId, groupIdHex: chat.id))
        #expect(try pinnedChatStore.loadAll()[accountId] == [chat.id])

        let archivedChat = try #require(state.archivedChats.first)
        await state.setChatArchived(archivedChat, archived: false)

        #expect(runtime.archivedGroup == ArchivedGroup(groupIdHex: "group", archived: false))
        #expect(state.archivedChats.isEmpty)
        #expect(state.activeChats.count == 2)
        #expect(state.activeChats.first?.id == chat.id)
        #expect(state.isChatPinned(chat))
    }

    @MainActor
    @Test func hasNoChatsSeparatesAnEmptyActiveDrawerFromAnAccountWithNothingInIt() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let chat = try #require(state.activeChats.first)
        #expect(!state.hasNoChats)

        // Archiving can empty the active drawer while leaving something to select, which is
        // what keeps the empty detail pane on "Select a chat" instead of inviting a first
        // conversation the account has already had.
        await state.setChatArchived(chat, archived: true)
        #expect(!state.archivedChats.isEmpty)
        #expect(!state.hasNoChats)

        let accountId = try #require(state.activeAccountId)
        state.chatsByAccount[accountId] = []
        state.archivedChatsByAccount[accountId] = []
        #expect(state.hasNoChats)
    }

    @MainActor
    @Test func archivedChatSearchFiltersArchivedSection() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let chat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.setChatArchived(chat, archived: true)
        state.searchText = "missing"

        #expect(state.filteredArchivedChats.isEmpty)
        #expect(state.filteredChats.isEmpty)

        state.searchText = chat.title.prefix(3).description
        #expect(state.filteredArchivedChats.count == 1)
        #expect(state.filteredArchivedChats.first?.id == chat.id)
    }

    @MainActor
    @Test func archivedFilterCacheHitRetainsObservationDependency() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)
        await state.setChatArchived(chat, archived: true)

        _ = state.filteredArchivedChats(matching: "")
        let invalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.filteredArchivedChats(matching: "")
        } onChange: {
            invalidated.markInvalidated()
        }

        state.archivedChatsByAccount[account.label] = []
        #expect(invalidated.value)
    }

    @MainActor
    @Test func chatListFilterShowsArchivedChatsOnlyWhenSelected() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let chat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        #expect(state.chatListFilter == .active)
        #expect(state.filteredChats.count == 1)
        #expect(state.filteredArchivedChats.isEmpty)

        await state.setChatArchived(chat, archived: true)

        #expect(state.filteredChats.isEmpty)
        #expect(state.filteredArchivedChats.count == 1)

        state.chatListFilter = .archived
        #expect(state.filteredArchivedChats.count == 1)
        #expect(state.filteredChats.isEmpty)

        state.chatListFilter = .active
        #expect(state.filteredChats.isEmpty)
        #expect(state.filteredArchivedChats.count == 1)
    }

    @MainActor
    @Test func accountSwitchResetsSearchAndSelectsFirstChatForAccount() async throws {
        let state = WorkspaceState.preview()
        state.searchText = "relay"

        state.selectAccount(AccountItem.samples[1])

        #expect(state.searchText.isEmpty)
        #expect(state.activeAccountId == AccountItem.samples[1].id)
        #expect(state.selection == .chat("chat-nvk"))
    }
}
