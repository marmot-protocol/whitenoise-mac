//
//  whitenoise_macTests.swift
//  whitenoise-macTests
//
//  Created by Jeff Gardner on 26/05/2026.
//

import Darwin
import Testing
import Foundation
import MarmotKit
import SwiftUI
import UserNotifications
@testable import whitenoise_mac

struct whitenoise_macTests {

    @MainActor
    @Test func emptyRuntimeBootstrapsToOnboarding() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        #expect(state.phase == .onboarding)
        #expect(state.accounts.isEmpty)
        #expect(!state.showsMessengerChrome)
        #expect(!runtime.didStart)
    }

    @MainActor
    @Test func signUpCreatesAccountAndEntersMessengerShell() async throws {
        let created = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: created)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.signUp()

        #expect(state.phase == .ready)
        #expect(state.showsMessengerChrome)
        #expect(state.accounts.map(\.displayName) == ["Desktop Account"])
        #expect(state.accounts.first?.pictureURL == "https://example.com/avatar.png")
        #expect(state.activeAccountId == "Desktop Account")
    }

    @MainActor
    @Test func removeActiveAccountCallsRuntimeAndSelectsNextAccount() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.removeActiveAccount()

        #expect(runtime.removedAccountRefs == ["Desktop Account"])
        #expect(state.accounts.map(\.id) == ["Backup Account"])
        #expect(state.activeAccountId == "Backup Account")
        #expect(state.selection == .settings(.accounts))
    }

    @MainActor
    @Test func deleteAllDataResetsToNewInstallState() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showSettings(.privacySecurity)
        state.auditLogFiles = [
            AuditLogFileFfi(
                accountRef: primary.label,
                path: "/tmp/audit-1.jsonl",
                fileName: "audit-1.jsonl",
                sizeBytes: 128,
                modifiedAtMs: 1_700_000_000_000
            )
        ]
        state.auditLogUploadStatus = "Uploaded 1 audit log file."

        await state.deleteAllData()

        #expect(runtime.didDeleteAllLocalData)
        let accounts = try runtime.listAccounts()
        #expect(accounts.isEmpty)
        #expect(state.phase == .onboarding)
        #expect(state.accounts.isEmpty)
        #expect(state.activeAccountId == nil)
        #expect(state.selection == nil)
        #expect(state.auditLogFiles.isEmpty)
        #expect(state.auditLogUploadStatus == nil)
        #expect(!state.showsMessengerChrome)
        #expect(UserDefaults.standard.string(forKey: "whitenoise.mac.activeAccountId") == nil)
    }

    @MainActor
    @Test func bootstrappingStateDoesNotShowMessengerChrome() async throws {
        let state = WorkspaceState(clientFactory: {
            FakeMarmotRuntime(accounts: [])
        })

        #expect(state.phase == .bootstrapping)
        #expect(!state.showsMessengerChrome)
    }

    @MainActor
    @Test func chatSearchMatchesTitleSubtitleAndPreview() async throws {
        let chats = ChatItem.samples

        #expect(ChatFilter.filtered(chats, query: "relay").map(\.id) == ["chat-relays"])
        #expect(ChatFilter.filtered(chats, query: "desktop").map(\.id) == ["chat-design"])
        #expect(ChatFilter.filtered(chats, query: "direct").map(\.id) == ["chat-nvk"])
    }

    @MainActor
    @Test func chatListRelativeTimestampUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)

        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sameWeekNow = messageDate.addingTimeInterval(86_400)
        let expected = messageDate.formatted(
            Date.FormatStyle.dateTime.weekday(.abbreviated)
                .locale(Locale(identifier: AppLanguage.spanish.rawValue))
        )

        #expect(DisplayText.relativeTimestamp(for: messageDate, now: sameWeekNow) == expected)
    }

    @MainActor
    @Test func messageTimestampUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)

        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = messageDate.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: AppLanguage.spanish.rawValue))
        )

        #expect(DisplayText.messageTimestamp(for: messageDate) == expected)
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
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: projectionRefreshedAt
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.updatedAt == Date(timeIntervalSince1970: TimeInterval(lastMessageAt)))
    }

    @MainActor
    @Test func messageDisplayMetadataShowsTimeAndOnlyOutgoingStatus() async throws {
        let outgoing = MessageItem(
            id: "outgoing",
            senderName: "Jeff",
            body: "On my way",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: true
        )
        let incoming = MessageItem(
            id: "incoming",
            senderName: "NVK",
            body: "Synced here",
            sentAt: Date(timeIntervalSince1970: 1_800_000_060),
            isOutgoing: false
        )

        #expect(!outgoing.timeLabel.isEmpty)
        #expect(outgoing.statusLabel == "Sent")
        #expect(incoming.statusLabel == nil)
    }

    @MainActor
    @Test func timelineMappingClassifiesAgentAndGroupSystemRows() async throws {
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "stream-start",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: "",
                    kind: 1200,
                    tags: [
                        MessageTagFfi(values: ["stream", "abc"]),
                        MessageTagFfi(values: ["route", "quic"])
                    ],
                    recordedAt: 1_700_000_000
                ),
                timelineMessage(
                    id: "activity",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: #"{"v":1,"status":"thinking","text":"Thinking"}"#,
                    kind: 1201,
                    recordedAt: 1_700_000_001
                ),
                timelineMessage(
                    id: "operation",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: #"{"v":1,"event_type":"tool_call","status":"started","name":"search","preview":"glp-1"}"#,
                    kind: 1202,
                    recordedAt: 1_700_000_002
                ),
                timelineMessage(
                    id: "system",
                    groupIdHex: "group",
                    sender: "",
                    plaintext: #"{"v":1,"system_type":"group_renamed","text":"Group renamed"}"#,
                    kind: 1210,
                    recordedAt: 1_700_000_003
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: "self"
        )

        #expect(messages.map(\.presentation) == [
            .agentStreamStart,
            .agentActivity,
            .agentOperation,
            .groupSystem
        ])
        #expect(messages.map(\.body) == [
            "Agent started a live response",
            "Thinking",
            "glp-1",
            "Group renamed"
        ])
        #expect(messages.allSatisfy { !$0.supportsChatActions })
        #expect(messages.allSatisfy { $0.statusLabel == nil })
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
    @Test func loadingMessagesAttachesReactionsToTheirTargetMessage() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMessages([
            appMessage(
                id: "parent",
                groupIdHex: "group",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                plaintext: "The launch plan is ready.",
                kind: 9,
                recordedAt: 1_700_000_000
            ),
            appMessage(
                id: "reaction",
                direction: "outbound",
                groupIdHex: "group",
                sender: account.accountIdHex,
                plaintext: "👍",
                kind: 7,
                tags: [MessageTagFfi(values: ["e", "parent"])],
                recordedAt: 1_700_000_001
            )
        ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        #expect(state.messagesByChat["group"]?.count == 1)
        #expect(state.messagesByChat["group"]?.first?.body == "The launch plan is ready.")
        #expect(state.messagesByChat["group"]?.first?.reactions == [
            MessageReaction(emoji: "👍", count: 1, isOwn: true, ownReactionMessageId: "reaction")
        ])
    }

    @MainActor
    @Test func loadingMessagesOmitsDeletedReactions() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        runtime.installGroup(messageGroup())
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages([
            appMessage(
                id: "parent",
                groupIdHex: "group",
                sender: aliceId,
                plaintext: "The launch plan is ready.",
                kind: 9,
                recordedAt: 1_700_000_000
            ),
            appMessage(
                id: "reaction",
                direction: "outbound",
                groupIdHex: "group",
                sender: account.accountIdHex,
                plaintext: "👍",
                kind: 7,
                tags: [MessageTagFfi(values: ["e", "parent"])],
                recordedAt: 1_700_000_001
            ),
            appMessage(
                id: "delete-reaction",
                direction: "outbound",
                groupIdHex: "group",
                sender: account.accountIdHex,
                plaintext: "",
                kind: 5,
                tags: [MessageTagFfi(values: ["e", "reaction"])],
                recordedAt: 1_700_000_002
            )
        ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        #expect(state.messagesByChat["group"]?.count == 1)
        #expect(state.messagesByChat["group"]?.first?.reactions.isEmpty == true)
    }

    @MainActor
    @Test func loadingMessagesAddsReplyContextToReplyMessages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        runtime.installGroup(messageGroup())
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages([
            appMessage(
                id: "parent",
                groupIdHex: "group",
                sender: aliceId,
                plaintext: "The launch plan is ready.",
                kind: 9,
                recordedAt: 1_700_000_000
            ),
            appMessage(
                id: "reply",
                direction: "outbound",
                groupIdHex: "group",
                sender: account.accountIdHex,
                plaintext: "Looks good to me.",
                kind: 9,
                tags: [
                    MessageTagFfi(values: ["e", "parent"]),
                    MessageTagFfi(values: ["q", "parent"])
                ],
                recordedAt: 1_700_000_001
            )
        ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        let messages = state.messagesByChat["group"] ?? []
        #expect(messages.map(\.id) == ["parent", "reply"])
        #expect(messages.last?.replyContext == MessageReplyContext(
            targetMessageId: "parent",
            senderName: "Alice",
            body: "The launch plan is ready."
        ))
    }

    @MainActor
    @Test func timelineProjectionChangesUpdateVisibleMessages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        runtime.installMessages([
            appMessage(
                id: "stale",
                groupIdHex: "direct-group",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                plaintext: "This should disappear.",
                kind: 9,
                recordedAt: 1_700_000_000
            )
        ], groupIdHex: "direct-group")
        let projected = timelineMessage(
            id: "stream",
            groupIdHex: "direct-group",
            sender: account.accountIdHex,
            plaintext: "Streaming…",
            recordedAt: 1_700_000_010,
            agentTextStreamJson: #"{"stream_id":"stream"}"#
        )
        let streamingChatRow = chatListRow(
            groupIdHex: "direct-group",
            title: "Alice",
            preview: "Streaming…",
            sender: account.accountIdHex,
            timelineAt: 1_700_000_010
        )
        runtime.installTimelineUpdates([
            .projection(update: RuntimeProjectionUpdateFfi(
                accountIdHex: account.accountIdHex,
                accountLabel: account.label,
                update: TimelineProjectionUpdateFfi(
                    groupIdHex: "direct-group",
                    messages: [],
                    changes: [
                        .remove(messageIdHex: "stale", reason: .noLongerMatchesQuery),
                        .upsert(trigger: .agentStreamStarted, message: projected)
                    ],
                    chatListRow: streamingChatRow,
                    chatListTrigger: .newLastMessage
                )
            ))
        ], groupIdHex: "direct-group")
        runtime.installChatListUpdates([
            .row(trigger: .newLastMessage, row: streamingChatRow)
        ])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.map(\.id) == ["stream"]
        }

        #expect(didApplyProjection)
        #expect(state.messagesByChat["direct-group"]?.first?.body == "Streaming…")
        // The sidebar preview is driven by the chat-list subscription, not the timeline
        // window (covered by chatListUsesSubscriptionSnapshotAndTypedDeltas).
    }

    @MainActor
    @Test func selectedMessageIDsCacheStaysInSyncAcrossTimelineMutations() async throws {
        // Regression for #44: selectedMessageIDs is served from a cache maintained in
        // lockstep with messagesByChat. Verify the cached ids always equal the live
        // message ids before and after the timeline window is replaced via a projection.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        runtime.installMessages([
            appMessage(
                id: "m1",
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "First.",
                kind: 9,
                recordedAt: 1_700_000_000
            ),
            appMessage(
                id: "m2",
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Second.",
                kind: 9,
                recordedAt: 1_700_000_001
            )
        ], groupIdHex: "direct-group")
        let projected = timelineMessage(
            id: "stream",
            groupIdHex: "direct-group",
            sender: account.accountIdHex,
            plaintext: "Streaming…",
            recordedAt: 1_700_000_010,
            agentTextStreamJson: #"{"stream_id":"stream"}"#
        )
        let streamingChatRow = chatListRow(
            groupIdHex: "direct-group",
            title: "Alice",
            preview: "Streaming…",
            sender: account.accountIdHex,
            timelineAt: 1_700_000_010
        )
        runtime.installTimelineUpdates([
            .projection(update: RuntimeProjectionUpdateFfi(
                accountIdHex: account.accountIdHex,
                accountLabel: account.label,
                update: TimelineProjectionUpdateFfi(
                    groupIdHex: "direct-group",
                    messages: [],
                    changes: [
                        .remove(messageIdHex: "m1", reason: .noLongerMatchesQuery),
                        .upsert(trigger: .agentStreamStarted, message: projected)
                    ],
                    chatListRow: streamingChatRow,
                    chatListTrigger: .newLastMessage
                )
            ))
        ], groupIdHex: "direct-group")
        runtime.installChatListUpdates([
            .row(trigger: .newLastMessage, row: streamingChatRow)
        ])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")

        // Cache matches the live ids after initial load.
        #expect(state.selectedMessageIDs == state.selectedMessages.map(\.id))
        #expect(state.selectedMessageIDs == ["m1", "m2"])

        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.map(\.id) == ["m2", "stream"]
        }
        #expect(didApplyProjection)

        // Cache stays in sync after the projection mutates the window.
        #expect(state.selectedMessageIDs == state.selectedMessages.map(\.id))
        #expect(state.selectedMessageIDs == ["m2", "stream"])
    }

    @MainActor
    @Test func olderTimelineProjectionDeltaDoesNotMoveReadMarkerBackward() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        runtime.installMessages([
            appMessage(
                id: "older",
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Earlier message",
                kind: 9,
                recordedAt: 1_700_000_000
            ),
            appMessage(
                id: "latest",
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Latest message",
                kind: 9,
                recordedAt: 1_700_000_010
            )
        ], groupIdHex: "direct-group")
        let reprojectedOlder = timelineMessage(
            id: "older",
            groupIdHex: "direct-group",
            sender: aliceId,
            plaintext: "Earlier message edited by projection",
            recordedAt: 1_700_000_000
        )
        runtime.installTimelineUpdates([
            .projection(update: RuntimeProjectionUpdateFfi(
                accountIdHex: account.accountIdHex,
                accountLabel: account.label,
                update: TimelineProjectionUpdateFfi(
                    groupIdHex: "direct-group",
                    messages: [],
                    changes: [
                        .upsert(trigger: .reactionAdded, message: reprojectedOlder)
                    ],
                    chatListRow: nil,
                    chatListTrigger: .unreadChanged
                )
            ))
        ], groupIdHex: "direct-group")
        let state = WorkspaceState(appActivityProvider: { true }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.first(where: { $0.id == "older" })?.body == "Earlier message edited by projection"
        }

        #expect(didApplyProjection)
        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func selectedChatDoesNotMarkReadWhileAppIsInactive() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        runtime.installMessages([
            appMessage(
                id: "latest",
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Latest message",
                kind: 9,
                recordedAt: 1_700_000_010
            )
        ], groupIdHex: "direct-group")
        // App is backgrounded: a selected chat must NOT advance the read marker just
        // because a message is visible in the timeline window.
        let state = WorkspaceState(appActivityProvider: { false }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")

        #expect(state.messagesByChat["direct-group"]?.count == 1)
        #expect(runtime.markedReadMessageIds.isEmpty)
    }

    @MainActor
    @Test func regainingFocusFlushesDeferredReadMarking() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        runtime.installMessages([
            appMessage(
                id: "latest",
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Latest message",
                kind: 9,
                recordedAt: 1_700_000_010
            )
        ], groupIdHex: "direct-group")
        // Start inactive so the initial open defers marking, then flip to active and
        // simulate the app regaining focus.
        var isActive = false
        let state = WorkspaceState(appActivityProvider: { isActive }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(runtime.markedReadMessageIds.isEmpty)

        isActive = true
        await state.handleAppActivationChange()

        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func chatListUsesSubscriptionSnapshotAndTypedDeltas() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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
    @Test func bootstrapSelectsMostRecentChatAndLoadsTimeline() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages([
            appMessage(
                id: "group-old",
                groupIdHex: "group",
                sender: account.accountIdHex,
                plaintext: "Older group message",
                kind: 9,
                recordedAt: 1_700_000_000
            )
        ], groupIdHex: "group")
        runtime.installMessages([
            appMessage(
                id: "direct-new",
                groupIdHex: "direct-group",
                sender: account.accountIdHex,
                plaintext: "Newest direct message",
                kind: 9,
                recordedAt: 1_700_000_100
            )
        ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didLoadMostRecent = await waitFor {
            state.selection == .chat("direct-group")
                && state.messagesByChat["direct-group"]?.map(\.id) == ["direct-new"]
        }

        #expect(didLoadMostRecent)
        #expect(runtime.timelineSubscriptionCount == 1)
    }

    @MainActor
    @Test func selectingChatsKeepsOnlyCurrentTranscriptInMemory() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages([
            appMessage(
                id: "group-message",
                groupIdHex: "group",
                sender: account.accountIdHex,
                plaintext: "Group cache candidate",
                kind: 9,
                recordedAt: 1_700_000_000
            )
        ], groupIdHex: "group")
        runtime.installMessages([
            appMessage(
                id: "direct-message",
                groupIdHex: "direct-group",
                sender: account.accountIdHex,
                plaintext: "Direct cache candidate",
                kind: 9,
                recordedAt: 1_700_000_010
            )
        ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let group = state.activeChats.first(where: { $0.id == "group" }),
              let direct = state.activeChats.first(where: { $0.id == "direct-group" })
        else {
            Issue.record("Expected both test chats")
            return
        }

        state.selectChat(group)
        let didLoadGroup = await waitFor {
            state.messagesByChat["group"]?.map(\.id) == ["group-message"]
        }
        #expect(didLoadGroup)
        #expect(Set(state.messagesByChat.keys) == ["group"])

        state.selectChat(direct)
        let didLoadDirect = await waitFor {
            state.messagesByChat["direct-group"]?.map(\.id) == ["direct-message"]
        }
        #expect(didLoadDirect)
        #expect(Set(state.messagesByChat.keys) == ["direct-group"])
    }

    @MainActor
    @Test func selectingUncachedChatTracksInitialTimelineLoadUntilSnapshotApplies() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages([
            appMessage(
                id: "group-message",
                groupIdHex: "group",
                sender: account.accountIdHex,
                plaintext: "Group history should not look empty while loading",
                kind: 9,
                recordedAt: 1_700_000_000
            )
        ], groupIdHex: "group")
        runtime.installMessages([
            appMessage(
                id: "direct-message",
                groupIdHex: "direct-group",
                sender: account.accountIdHex,
                plaintext: "Most recent chat loads during bootstrap",
                kind: 9,
                recordedAt: 1_700_000_010
            )
        ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.selection == .chat("direct-group"))
        #expect(state.messagesByChat["group"] == nil)
        guard let group = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected group chat")
            return
        }

        runtime.timelineSubscriptionDelayNanoseconds = 50_000_000
        state.selectChat(group)

        #expect(state.selectedTimelineIsLoadingInitialPage)
        #expect(state.selectedMessages.isEmpty)
        #expect(state.messagesByChat["group"] == nil)

        let didLoadGroup = await waitFor {
            state.messagesByChat["group"]?.map(\.id) == ["group-message"]
        }
        #expect(didLoadGroup)
        #expect(!state.selectedTimelineIsLoadingInitialPage)
        #expect(state.selectedMessages.map(\.id) == ["group-message"])
    }

    @MainActor
    @Test func initialTimelineLoadClearsWhenRuntimeIsUnavailable() async throws {
        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let chat = ChatItem(
            id: "group",
            title: "General",
            subtitle: "Group chat",
            preview: "",
            updatedAt: nil,
            avatarSeed: "group",
            pictureURL: nil,
            unreadCount: 0
        )
        UserDefaults.standard.set(account.id, forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [chat]],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )

        state.selectChat(chat)

        #expect(state.selectedTimelineIsLoadingInitialPage)
        await state.loadMessages(groupIdHex: chat.id)
        #expect(!state.selectedTimelineIsLoadingInitialPage)
        #expect(state.messagesByChat["group"] == nil)
    }

    @MainActor
    @Test func loadingOlderMessagesExtendsWindowViaSubscription() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.count == 100)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-005")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        await state.loadOlderMessages(groupIdHex: "direct-group")

        let loadedIds = state.messagesByChat["direct-group"]?.map(\.id) ?? []
        #expect(loadedIds.count == 105)
        #expect(loadedIds.first == "message-000")
        #expect(loadedIds.last == "message-104")
        #expect(!state.selectedTimelinePaging.hasMoreBefore)
        #expect(runtime.lastTimelineSubscription?.paginateBackwardsCount == 1)
        #expect(runtime.timelineSubscriptionCount == 1)
    }

    @MainActor
    @Test func loadingOlderMessagesStopsPaginatingAtOldest() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<101).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")

        // The subscription owns the cursor: the first scroll-up reaches the oldest message,
        // and the second is a no-op (guarded by hasMoreBefore), so it never re-paginates.
        #expect(runtime.lastTimelineSubscription?.paginateBackwardsCount == 1)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-000")
        #expect(state.messagesByChat["direct-group"]?.count == 101)
        #expect(!state.selectedTimelinePaging.hasMoreBefore)
    }

    @MainActor
    @Test func timelineWindowCapsScrollbackAndPagesForwardAgain() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<450).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")

        // The runtime caps the materialized window at MAX_TIMELINE_LIMIT (200); scrolling
        // back trims the newest rows, so the window slides instead of growing unbounded.
        #expect(state.messagesByChat["direct-group"]?.count == 200)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-050")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "message-249")
        #expect(state.selectedTimelinePaging.hasMoreBefore)
        #expect(state.selectedTimelinePaging.hasMoreAfter)

        await state.loadNewerMessages(groupIdHex: "direct-group")

        // Paging forward slides the window toward the head, trimming the oldest rows.
        #expect(state.messagesByChat["direct-group"]?.count == 200)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-150")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "message-349")
        #expect(state.selectedTimelinePaging.hasMoreBefore)
        #expect(state.selectedTimelinePaging.hasMoreAfter)
        #expect(runtime.lastTimelineSubscription?.paginateForwardsCount == 1)
    }

    @Test func newerTimelinePagingRestoresAnchorInsteadOfScrollingToBottom() {
        let historicalPaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: true,
            isLoadingBefore: false,
            isLoadingAfter: false
        )
        let liveEdgePaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: false,
            isLoadingBefore: false,
            isLoadingAfter: false
        )

        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-150", "message-249", "message-349"],
            newMessageIsOutgoing: false,
            paging: historicalPaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: "message-249",
            newMessageId: "message-349",
            isPinnedToBottom: false
        ) == .restorePendingAppendAnchor("message-249"))
        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-350", "message-449"],
            newMessageIsOutgoing: false,
            paging: historicalPaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: "message-249",
            newMessageId: "message-449",
            isPinnedToBottom: false
        ) == .clearPendingAppendAnchor)
        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-350", "message-449"],
            newMessageIsOutgoing: false,
            paging: historicalPaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: nil,
            newMessageId: "message-449",
            isPinnedToBottom: true
        ) == .none)
        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-350", "message-449"],
            newMessageIsOutgoing: false,
            paging: liveEdgePaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: nil,
            newMessageId: "message-449",
            isPinnedToBottom: true
        ) == .scrollToBottom)
    }

    @Test func newestMessageAutoScrollUsesBottomProximityNotOlderHistoryAvailability() {
        let longLiveEdgePaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: false,
            isLoadingBefore: false,
            isLoadingAfter: false
        )
        let detachedHistoryPaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: true,
            isLoadingBefore: false,
            isLoadingAfter: false
        )

        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-001", "message-101"],
            newMessageIsOutgoing: false,
            paging: longLiveEdgePaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: nil,
            newMessageId: "message-101",
            isPinnedToBottom: true
        ) == .scrollToBottom)
        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-001", "message-101"],
            newMessageIsOutgoing: false,
            paging: longLiveEdgePaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: nil,
            newMessageId: "message-101",
            isPinnedToBottom: false
        ) == .none)
        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-001", "message-101"],
            newMessageIsOutgoing: true,
            paging: longLiveEdgePaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: nil,
            newMessageId: "message-101",
            isPinnedToBottom: false
        ) == .scrollToBottom)
        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-001", "message-101"],
            newMessageIsOutgoing: false,
            paging: detachedHistoryPaging,
            pendingPrependAnchorId: nil,
            pendingAppendAnchorId: nil,
            newMessageId: "message-101",
            isPinnedToBottom: true
        ) == .none)
        #expect(timelineNewestMessageScrollAction(
            messageIDs: ["message-001", "message-101"],
            newMessageIsOutgoing: false,
            paging: longLiveEdgePaging,
            pendingPrependAnchorId: "message-000",
            pendingAppendAnchorId: nil,
            newMessageId: "message-101",
            isPinnedToBottom: true
        ) == .none)
    }

    @MainActor
    @Test func latestSubscriptionPageDoesNotReplaceHistoricalTimelineWindow() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.timelineUpdateDelayNanoseconds = 300_000_000
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        let baseTime: UInt64 = 1_700_000_000
        let messages = (0..<450).map { index in
            appMessage(
                id: String(format: "message-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Message \(index)",
                kind: 9,
                recordedAt: baseTime + UInt64(index)
            )
        }
        runtime.installMessages(messages, groupIdHex: "direct-group")
        runtime.installTimelineUpdates([
            .page(page: TimelinePageFfi(
                messages: (350..<450).map { index in
                    timelineMessage(
                        id: String(format: "message-%03d", index),
                        groupIdHex: "direct-group",
                        sender: aliceId,
                        plaintext: "Live latest \(index)",
                        recordedAt: baseTime + UInt64(index)
                    )
                },
                hasMoreBefore: true,
                hasMoreAfter: false
            ))
        ], groupIdHex: "direct-group")
        let state = WorkspaceState(appActivityProvider: { true }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let loadedIds = state.messagesByChat["direct-group"]?.map(\.id) ?? []
        #expect(loadedIds.count == 200)
        #expect(loadedIds.first == "message-050")
        #expect(loadedIds.last == "message-249")
        #expect(state.selectedTimelinePaging.hasMoreAfter)
        #expect(runtime.markedReadMessageIds == ["message-449"])
    }

    @MainActor
    @Test func projectionUpdateOnlyMutatesVisibleHistoricalMessages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.timelineUpdateDelayNanoseconds = 300_000_000
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<450).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let visibleUpdate = timelineMessage(
            id: "message-120",
            groupIdHex: "direct-group",
            sender: aliceId,
            plaintext: "Visible message updated by projection",
            recordedAt: baseTime + 120
        )
        let offscreenLatest = timelineMessage(
            id: "message-500",
            groupIdHex: "direct-group",
            sender: aliceId,
            plaintext: "Offscreen latest message",
            recordedAt: baseTime + 500
        )
        runtime.installTimelineUpdates([
            .projection(update: RuntimeProjectionUpdateFfi(
                accountIdHex: account.accountIdHex,
                accountLabel: account.label,
                update: TimelineProjectionUpdateFfi(
                    groupIdHex: "direct-group",
                    messages: [visibleUpdate, offscreenLatest],
                    changes: [
                        .upsert(trigger: .reactionAdded, message: visibleUpdate),
                        .upsert(trigger: .newMessage, message: offscreenLatest)
                    ],
                    chatListRow: chatListRow(
                        groupIdHex: "direct-group",
                        title: "Alice",
                        preview: "Offscreen latest message",
                        sender: aliceId,
                        timelineAt: baseTime + 500
                    ),
                    chatListTrigger: .newLastMessage
                )
            ))
        ], groupIdHex: "direct-group")
        let state = WorkspaceState(appActivityProvider: { true }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let loadedMessages = state.messagesByChat["direct-group"] ?? []
        #expect(loadedMessages.count == 200)
        #expect(loadedMessages.map(\.id).first == "message-050")
        #expect(loadedMessages.map(\.id).last == "message-249")
        #expect(loadedMessages.first(where: { $0.id == "message-120" })?.body == "Visible message updated by projection")
        #expect(!loadedMessages.contains { $0.id == "message-500" })
        #expect(state.selectedTimelinePaging.hasMoreAfter)
        #expect(runtime.markedReadMessageIds == ["message-449"])
    }

    @MainActor
    @Test func timelinePagingUsesLocalProfileDataWithoutRefreshingProfiles() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.accountIdsMissingProfiles.insert(bobId)
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: nil,
                displayName: nil,
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: bobId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        runtime.clearRefreshedProfileIds()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")

        #expect(runtime.refreshedProfileIds.isEmpty)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-000")
    }

    @MainActor
    @Test func messageActionsDoNotRestartLiveSubscriptions() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let chatListSubscriptionCount = runtime.chatListSubscriptionCount
        let timelineSubscriptionCount = runtime.timelineSubscriptionCount

        await state.react(to: message, emoji: "👍")
        await state.deleteMessage(message)

        #expect(runtime.chatListSubscriptionCount == chatListSubscriptionCount)
        #expect(runtime.timelineSubscriptionCount == timelineSubscriptionCount)
    }

    @MainActor
    @Test func replyingToMessageSendsDraftAsReplyAndClearsReplyTarget() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.startReply(to: MessageItem(
            id: "parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        ))
        state.draftText = "Looks good to me."
        await state.sendDraft()

        #expect(runtime.repliedMessage == SentReply(
            groupIdHex: "direct-group",
            targetMessageId: "parent",
            text: "Looks good to me."
        ))
        #expect(state.replyDraftContext == nil)
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func messageActionsPublishReactionAndDelete() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )

        await state.bootstrap()
        await state.react(to: message, emoji: "👍")
        await state.deleteMessage(message)

        #expect(runtime.reactedMessage == SentReaction(
            groupIdHex: "direct-group",
            targetMessageId: "parent",
            emoji: "👍"
        ))
        #expect(runtime.deletedMessage == DeletedMessage(
            groupIdHex: "direct-group",
            targetMessageId: "parent"
        ))
    }

    @MainActor
    @Test func messageActionsRemoveOwnReactionByDeletingReactionEvent() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        let state = WorkspaceState(clientFactory: { runtime })
        let ownReaction = MessageReaction(
            emoji: "👍",
            count: 1,
            isOwn: true,
            ownReactionMessageId: "reaction-event"
        )
        let message = MessageItem(
            id: "parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            reactions: [ownReaction]
        )

        await state.bootstrap()
        await state.removeReaction(ownReaction, from: message)

        #expect(runtime.deletedMessage == DeletedMessage(
            groupIdHex: "direct-group",
            targetMessageId: "reaction-event"
        ))
        #expect(runtime.reactedMessage == nil)
    }

    @Test func reactionRemovalCapabilityFollowsReactionEventId() throws {
        let ownSummaryWithoutEventId = MessageReaction(
            emoji: "👍",
            count: 1,
            isOwn: true
        )
        let userReactionWithEventId = MessageReaction(
            emoji: "👍",
            count: 1,
            isOwn: false,
            ownReactionMessageId: "reaction-event"
        )

        #expect(!ownSummaryWithoutEventId.canRemoveOwnReaction)
        #expect(userReactionWithEventId.canRemoveOwnReaction)
    }

    @MainActor
    @Test func copyingMessageTextUsesConfiguredClipboardWriter() async throws {
        var copiedText = ""
        let state = WorkspaceState(copyTextHandler: { copiedText = $0 })

        state.copyText(of: MessageItem(
            id: "message",
            senderName: "Alice",
            body: "Copy this",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        ))

        #expect(copiedText == "Copy this")
    }

    @MainActor
    @Test func copyingPlainSettingsTextUsesConfiguredClipboardWriter() async throws {
        var copiedText = ""
        let state = WorkspaceState(copyTextHandler: { copiedText = $0 })

        state.copyText("public-key-value")

        #expect(copiedText == "public-key-value")
    }

    @Test func conversationTranscriptExportEncodesTimelineEventFieldsInOrder() throws {
        let firstId = String(repeating: "1", count: 64)
        let secondId = String(repeating: "2", count: 64)
        let records = [
            timelineMessage(
                id: secondId,
                groupIdHex: "group",
                sender: String(repeating: "a", count: 64),
                plaintext: "final answer",
                kind: 9,
                tags: [MessageTagFfi(values: ["stream", "abcd"])],
                recordedAt: 2,
                agentTextStreamJson: #"{"status":"finalized"}"#
            ),
            timelineMessage(
                id: firstId,
                groupIdHex: "group",
                sender: String(repeating: "b", count: 64),
                plaintext: "started",
                kind: 1311,
                tags: [MessageTagFfi(values: ["stream", "abcd"])],
                recordedAt: 1,
                agentTextStreamJson: #"{"status":"started"}"#
            )
        ]

        let document = ConversationTranscriptExport.makeDocument(
            groupIdHex: "group",
            groupName: "Hermes 2",
            messages: records,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(document.eventCount == 2)
        #expect(document.events.map(\.messageIdHex) == [firstId, secondId])
        #expect(document.events[0].kind == 1311)
        #expect(document.events[1].content == "final answer")
        #expect(document.events[1].agentTextStreamJson == #"{"status":"finalized"}"#)

        let data = try ConversationTranscriptExport.encodeJSON(document)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["group_name"] as? String == "Hermes 2")
        #expect((json["events"] as? [[String: Any]])?.count == 2)
    }

    @MainActor
    @Test func directChatUsesOtherMemberProfileForTitleAndAvatar() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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
            encryptedMedia: encryptedMediaComponent(),
            archived: false,
            pendingConfirmation: false,
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
        #expect(runtime.refreshedProfileIds.isEmpty)
    }

    @MainActor
    @Test func groupImageSearchSelectionUpdatesGroupAvatarUrl() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let imageSearchClient = FakeGroupImageSearchClient(results: [
            GroupImageSearchResult(
                id: "image-1",
                title: "Aurora",
                imageURL: "https://example.com/aurora.jpg",
                thumbnailURL: "https://example.com/aurora-thumb.jpg",
                creator: "Open Photographer",
                license: "by",
                attribution: nil,
                sourceURL: "https://example.com/aurora",
                width: 1024,
                height: 680
            )
        ])
        let state = WorkspaceState(
            groupImageSearchClient: imageSearchClient,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        state.showGroupImagePicker(for: groupChat)
        await state.searchGroupImages()
        guard let result = state.groupImageResults.first else {
            Issue.record("Expected an image result")
            return
        }
        await state.setGroupImage(result)

        let imageSearchQueries = await imageSearchClient.queries
        #expect(imageSearchQueries == ["Test Group"])
        #expect(runtime.updatedGroupAvatar == UpdatedGroupAvatar(
            groupIdHex: "group",
            url: "https://example.com/aurora.jpg",
            dim: "1024x680",
            thumbhash: nil
        ))
        #expect(!state.isGroupImagePickerPresented)
        #expect(state.activeChats.first?.pictureURL == "https://example.com/aurora.jpg")
    }

    @MainActor
    @Test func groupImagePickerDismissesWhenSelectionClears() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        state.showGroupImagePicker(for: groupChat)
        state.selection = nil

        #expect(state.selectedChat == nil)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func groupImagePickerDismissesWhenSelectedChatIsRemoved() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        state.showGroupImagePicker(for: groupChat)
        runtime.installChatListUpdates([
            .removeRow(trigger: .removed, groupIdHex: groupChat.id)
        ])
        await state.reloadChats()
        let didRemoveSelectedChat = await waitFor {
            state.activeChats.isEmpty && state.selectedChat == nil
        }

        #expect(didRemoveSelectedChat)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func groupImagePickerDismissesWhenRemovedChatAutoReselectsNextChat() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected a group chat")
            return
        }

        state.selectChat(groupChat)
        state.showGroupImagePicker(for: groupChat)
        runtime.installChatListUpdates([
            .removeRow(trigger: .removed, groupIdHex: groupChat.id)
        ])
        await state.reloadChats()
        let didReselectNextChat = await waitFor {
            state.selection == .chat("direct-group") && state.selectedChat?.id == "direct-group"
        }

        #expect(didReselectNextChat)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func directChatDoesNotOpenGroupImagePicker() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didHydrateDirectChat = await waitFor {
            state.activeChats.first?.isDirect == true
        }
        guard let directChat = state.activeChats.first else {
            Issue.record("Expected a direct chat")
            return
        }

        state.showGroupImagePicker(for: directChat)

        #expect(didHydrateDirectChat)
        #expect(directChat.isDirect)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func groupDetailsProfileSaveAndInviteUseBindings() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installNormalizedMemberRef(
            query: "npub1newmember",
            accountIdHex: "new1234567890new1234567890new1234567890new1234567890new1",
            npub: "npub1newmember"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        #expect(state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot?.name == "Test Group")
        #expect(state.groupDetailsSnapshot?.members.count == 3)
        #expect(state.groupDetailsSnapshot?.canInvite == true)
        #expect(state.groupDetailsSnapshot?.relays == MarmotClient.seedRelays)
        #expect(state.groupDetailsSnapshot?.adminIds == [account.accountIdHex])
        #expect(state.groupDetailsSnapshot?.pendingConfirmation == false)

        state.groupProfileDraftName = "Renamed Group"
        state.groupProfileDraftDescription = "Planning room"
        await state.saveGroupProfile()

        #expect(runtime.updatedGroupProfile == UpdatedGroupProfile(
            groupIdHex: "group",
            name: "Renamed Group",
            description: "Planning room"
        ))
        #expect(state.groupDetailsSnapshot?.name == "Renamed Group")
        #expect(state.activeChats.first?.title == "Renamed Group")

        state.groupInviteMemberQuery = "npub1newmember"
        await state.inviteMemberToSelectedGroup()

        #expect(runtime.invitedMemberRefs == ["npub1newmember"])
        #expect(state.groupInviteMemberQuery.isEmpty)
        #expect(state.groupDetailsSnapshot?.members.contains { $0.npub == "npub1newmember" } == true)
    }

    @MainActor
    @Test func groupDetailsMemberAdminActionsUseDetailedMutations() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        guard let member = state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }) else {
            Issue.record("Expected another member")
            return
        }

        await state.promoteGroupMember(member)
        #expect(runtime.promotedAdminRef == "npub1alice")
        #expect(state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id })?.isAdmin == true)

        guard let promotedMember = state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id }) else {
            Issue.record("Expected promoted member")
            return
        }
        await state.demoteGroupMember(promotedMember)
        #expect(runtime.demotedAdminRef == "npub1alice")
        #expect(state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id })?.isAdmin == false)

        guard let demotedMember = state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id }) else {
            Issue.record("Expected demoted member")
            return
        }
        await state.removeGroupMember(demotedMember)
        #expect(runtime.removedMemberRefs == ["npub1alice"])
        #expect(state.groupDetailsSnapshot?.members.contains { $0.id == member.id } == false)
    }

    @MainActor
    @Test func groupDetailsArchiveAndLeaveRefreshChatList() async throws {
        let account = desktopAccount()
        let archiveRuntime = FakeMarmotRuntime(accounts: [account])
        archiveRuntime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let archiveState = WorkspaceState(clientFactory: { archiveRuntime })

        await archiveState.bootstrap()
        guard let archiveChat = archiveState.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await archiveState.showGroupDetails(for: archiveChat)
        await archiveState.setSelectedGroupArchived(true)

        #expect(archiveRuntime.archivedGroup == ArchivedGroup(groupIdHex: "group", archived: true))
        #expect(!archiveState.isGroupDetailsPresented)
        #expect(archiveState.activeChats.isEmpty)

        let leaveRuntime = FakeMarmotRuntime(accounts: [account])
        let leaveDetails = groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: false)
        leaveRuntime.installGroupDetails(
            leaveDetails,
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: true,
                requiresSelfDemoteBeforeLeave: false,
                memberActions: []
            )
        )
        let leaveState = WorkspaceState(clientFactory: { leaveRuntime })

        await leaveState.bootstrap()
        guard let leaveChat = leaveState.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await leaveState.showGroupDetails(for: leaveChat)
        await leaveState.leaveSelectedGroup()

        #expect(leaveRuntime.leftGroupIdHex == "group")
        #expect(!leaveState.isGroupDetailsPresented)
        #expect(leaveState.activeChats.isEmpty)
    }

    @MainActor
    @Test func groupDetailsSelfDemoteUsesDetailedMutation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(
            selfAccountIdHex: account.accountIdHex,
            otherIsAdmin: true
        ))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.isSelfAdmin == true)
        #expect(state.groupDetailsSnapshot?.isLastAdmin == false)

        await state.selfDemoteSelectedGroupAdmin()

        #expect(runtime.selfDemotedGroupIdHex == "group")
        #expect(state.groupDetailsSnapshot?.isSelfAdmin == false)
        #expect(state.groupDetailsSnapshot?.members.first(where: \.isSelf)?.isAdmin == false)
    }

    @MainActor
    @Test func groupDetailsTranscriptExportCopiesPagedTimelineJSON() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installMessages(
            (0..<205).map { index in
                appMessage(
                    id: String(format: "%064x", index + 1),
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "message \(index)",
                    kind: 9,
                    recordedAt: UInt64(index + 1)
                )
            },
            groupIdHex: "group"
        )

        var copiedText = ""
        let state = WorkspaceState(
            copyTextHandler: { copiedText = $0 },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        runtime.clearTimelineMessageQueries()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        await state.copySelectedGroupTranscriptJSON()

        let data = Data(copiedText.utf8)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(json["group_id_hex"] as? String == "group")
        #expect(json["group_name"] as? String == "Test Group")
        #expect(json["event_count"] as? Int == 205)
        #expect(events.first?["content"] as? String == "message 0")
        #expect(events.last?["content"] as? String == "message 204")
        #expect(runtime.timelineMessageQueries.count >= 2)
        #expect(runtime.timelineMessageQueries.first?.limit == ConversationTranscriptExport.pageLimit)
        #expect(runtime.timelineMessageQueries.dropFirst().first?.before != nil)
        #expect(state.groupTranscriptExportStatus == "Copied transcript JSON for 205 events.")
    }

    @MainActor
    @Test func settingsSelectionUsesDetailPaneWithoutChangingAccount() async throws {
        let state = WorkspaceState.preview()
        let accountId = state.activeAccountId

        state.showSettings()

        #expect(state.selection == .settings(.profile))
        #expect(state.activeAccountId == accountId)
    }

    @MainActor
    @Test func settingsSelectionCanTargetAllSettingsPages() async throws {
        let state = WorkspaceState.preview()

        state.showSettings(.accounts)
        #expect(state.selection == .settings(.accounts))

        state.showSettings(.profile)
        #expect(state.selection == .settings(.profile))

        state.showSettings(.identityKeys)
        #expect(state.selection == .settings(.identityKeys))

        state.showSettings(.relays)
        #expect(state.selection == .settings(.relays))

        state.showSettings(.keyPackages)
        #expect(state.selection == .settings(.keyPackages))

        state.showSettings(.appearance)
        #expect(state.selection == .settings(.appearance))

        state.showSettings(.privacySecurity)
        #expect(state.selection == .settings(.privacySecurity))

        state.showSettings(.notifications)
        #expect(state.selection == .settings(.notifications))

        state.showSettings(.developerMode)
        #expect(state.selection == .settings(.developerMode))
    }

    @MainActor
    @Test func settingsSidebarPagesStartWithProfileAndExcludeOverview() async throws {
        #expect(SettingsPage.sidebarPages.first == .profile)
        #expect(!SettingsPage.sidebarPages.contains(.overview))
        #expect(SettingsPage.sidebarPages.contains(.privacySecurity))
        #expect(SettingsPage.sidebarPages.last == .developerMode)
    }

    @MainActor
    @Test func streamingDebugRequiresDeveloperMode() async throws {
        let defaults = UserDefaults.standard
        let previousDeveloperMode = defaults.object(forKey: "whitenoise.mac.developerMode")
        let previousStreamingDebugMode = defaults.object(forKey: "whitenoise.mac.streamingDebugMode")
        defer {
            restoreDefault(previousDeveloperMode, forKey: "whitenoise.mac.developerMode")
            restoreDefault(previousStreamingDebugMode, forKey: "whitenoise.mac.streamingDebugMode")
        }

        let state = WorkspaceState.preview()
        state.developerMode = false
        state.streamingDebugMode = true
        #expect(!state.streamingDebugEnabled)

        state.developerMode = true
        #expect(state.streamingDebugEnabled)
    }

    @MainActor
    @Test func messageDebugMetadataSummarizesTimelineKindAndId() async throws {
        let message = MessageItem(
            id: "abcdef0123456789abcdef0123456789",
            senderName: "Agent",
            body: "Working",
            sentAt: Date(timeIntervalSince1970: 1_800),
            timelineAt: 1_234,
            timelineKind: 12_345,
            isOutgoing: false,
            presentation: .agentOperation
        )

        #expect(message.debugTitle == "kind 12345 - agent-operation")
        #expect(message.debugDetail.hasSuffix(" - 1234"))
    }

    @MainActor
    @Test func defaultRelaysUseWhiteNoiseEuAndUsOnly() async throws {
        let defaults = [
            "wss://relay.eu.whitenoise.chat",
            "wss://relay.us.whitenoise.chat"
        ]

        #expect(MarmotClient.seedRelays == defaults)
        #expect(RelaySettingsSnapshot.defaults.nip65 == defaults)
        #expect(RelaySettingsSnapshot.defaults.inbox == defaults)
        #expect(RelaySettingsSnapshot.defaults.defaultRelays == defaults)
        #expect(RelaySettingsSnapshot.defaults.bootstrapRelays == defaults)
        #expect(RelaySettingsSection.allCases == [.nip65, .inbox])
    }

    @MainActor
    @Test func settingsAccountSwitchStaysOnAccountsPage() async throws {
        let state = WorkspaceState.preview()
        state.showSettings(.accounts)
        state.searchText = "relay"
        state.draftText = "half-written"

        state.selectAccountFromSettings(AccountItem.samples[1])

        #expect(state.activeAccountId == AccountItem.samples[1].id)
        #expect(state.selection == .settings(.accounts))
        #expect(state.searchText.isEmpty)
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func appearancePreferenceMapsToPreferredColorScheme() async throws {
        let state = WorkspaceState.preview()

        state.appearancePreference = .dark
        #expect(state.preferredColorScheme == .dark)

        state.appearancePreference = .light
        #expect(state.preferredColorScheme == .light)

        state.appearancePreference = .system
        #expect(state.preferredColorScheme == nil)
    }

    @MainActor
    @Test func newChatComposerOpensInChatColumnWithoutChangingDetailSelection() async throws {
        let state = WorkspaceState.preview()
        let selection = state.selection
        state.draftText = "half-written message"

        state.showNewChat()

        #expect(state.isNewChatComposerVisible)
        #expect(state.selection == selection)
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func startingNewChatCreatesAndSelectsConversation() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1alice"
        state.newChatName = "Project Room"
        state.newChatDescription = "planning space"
        await state.createNewChat()

        #expect(runtime.createdGroupMemberRefs == ["npub1alice"])
        #expect(runtime.createdGroupName == "Project Room")
        #expect(runtime.createdGroupDescription == "planning space")
        #expect(state.selection == .chat("created-group"))
        #expect(!state.isNewChatComposerVisible)
        #expect(state.activeChats.map(\.id) == ["created-group"])
    }

    @MainActor
    @Test func resolvingNewChatRecipientUsesProfilePicture() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1alice"
        await state.resolveNewChatQuery()

        #expect(state.resolvedNewChatRecipient?.title == "Desktop Account")
        #expect(state.resolvedNewChatRecipient?.pictureURL == "https://example.com/avatar.png")
    }

    @MainActor
    @Test func staleNewChatRecipientLookupDoesNotReplaceCurrentResult() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let slowId = "1111111111111111111111111111111111111111111111111111111111111111"
        let fastId = "2222222222222222222222222222222222222222222222222222222222222222"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1slow", accountIdHex: slowId, npub: "npub1slow")
        runtime.installNormalizedMemberRef(query: "npub1fast", accountIdHex: fastId, npub: "npub1fast")
        runtime.installProfile(
            accountIdHex: slowId,
            profile: UserProfileMetadataFfi(
                name: "slow",
                displayName: "Slow Recipient",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: fastId,
            profile: UserProfileMetadataFfi(
                name: "fast",
                displayName: "Fast Recipient",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.profileRefreshDelaysByAccountId[slowId] = 150_000_000
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1slow"
        let slowLookup = Task { @MainActor in
            await state.resolveNewChatQueryIfReady()
        }
        let slowLookupStarted = await waitFor {
            runtime.refreshedProfileIds.contains(slowId)
        }
        #expect(slowLookupStarted)

        state.newChatQuery = "npub1fast"
        await state.resolveNewChatQueryIfReady()
        await slowLookup.value

        #expect(state.resolvedNewChatRecipient?.accountIdHex == fastId)
        #expect(state.resolvedNewChatRecipient?.title == "Fast Recipient")
    }

    @MainActor
    @Test func settingsLoadUpdatesActiveAccountProfilePicture() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()

        #expect(state.activeAccount?.displayName == "Desktop Account")
        #expect(state.activeAccount?.pictureURL == "https://example.com/avatar.png")
        #expect(state.profileDraft.picture == "https://example.com/avatar.png")
    }

    @MainActor
    @Test func keyPackageLoadShowsPublishedKeyPackages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.loadKeyPackages()

        #expect(state.keyPackages.map(\.eventIdHex) == ["event-local", "event-fetched"])
        #expect(state.keyPackages.first?.sourceLabel == "Local")
        #expect(runtime.lastPackageFetchBootstrapRelays == MarmotClient.seedRelays)
    }

    @MainActor
    @Test func keyPackageLabelsUseSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)

        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let package = KeyPackageItem(
            accountRef: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "key-package",
            keyPackageRefHex: "key-package-ref",
            eventIdHex: "event-fetched",
            publishedAt: publishedAt,
            keyPackageBytes: 128,
            sourceRelays: ["wss://relay.example"],
            isLocal: false,
            isRelayDiscovered: true
        )
        let expectedPublished = publishedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: AppLanguage.spanish.rawValue))
        )

        #expect(package.sourceLabel == "Obtenido")
        #expect(package.publishedLabel == expectedPublished)

        let unknownPackage = KeyPackageItem(
            accountRef: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "unknown-package",
            keyPackageRefHex: "unknown-key-package-ref",
            eventIdHex: "event-unknown",
            publishedAt: nil,
            keyPackageBytes: 0,
            sourceRelays: [],
            isLocal: false,
            isRelayDiscovered: false
        )

        #expect(unknownPackage.sourceLabel == "Desconocido")
        #expect(unknownPackage.publishedLabel == "Desconocido")
    }

    @MainActor
    @Test func keyPackageLoadUsesAccountRelayBootstrapRelays() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.loadKeyPackages()

        #expect(runtime.lastPackageFetchBootstrapRelays == bootstrapRelays)
    }

    @MainActor
    @Test func settingsLoadDoesNotFetchKeyPackages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()

        #expect(runtime.accountKeyPackagesCallCount == 0)
        #expect(state.keyPackages.isEmpty)
    }

    @MainActor
    @Test func settingsLoadShowsNotificationPreference() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter()
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadSettingsData()

        #expect(state.notificationSettings.localNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus == .authorized)
    }

    @MainActor
    @Test func telemetryBuildConfigUsesSeparateMacBuildSettings() async throws {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "DarkmatterTelemetryOTLPEndpoint": "https://collector.example/v1/metrics",
                "DarkmatterTelemetryBearerToken": "otlp-token",
                "DarkmatterAuditLogBearerToken": "audit-token",
                "DarkmatterTelemetryEnvironment": "production",
                "CFBundleShortVersionString": "2026.6",
                "CFBundleVersion": "12"
            ],
            environment: [:],
            osVersion: "Version 26.0",
            deviceModelIdentifier: "Mac15,3"
        )

        #expect(config.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(config.bearerToken == "otlp-token")
        #expect(config.auditLogBearerToken == "audit-token")
        #expect(config.deploymentEnvironment == "production")
        #expect(config.serviceVersion == "2026.6+12")
        #expect(config.osVersion == "Version 26.0")
        #expect(config.deviceModelIdentifier == "Mac15,3")

        let runtimeConfig = config.runtimeConfig(installId: "install-id")
        #expect(runtimeConfig.authorizationBearerToken == "otlp-token")
        #expect(runtimeConfig.resource?.serviceVersion == "2026.6+12")
        #expect(runtimeConfig.resource?.serviceInstanceId == "install-id")
        #expect(runtimeConfig.resource?.deploymentEnvironment == "production")
        #expect(runtimeConfig.resource?.tenant == "whitenoise-mac")
        #expect(runtimeConfig.resource?.osType == "darwin")
        #expect(runtimeConfig.resource?.osVersion == "Version 26.0")
        #expect(runtimeConfig.resource?.deviceModelIdentifier == "Mac15,3")

        let auditConfig = config.auditTrackerConfig(accountLabel: "Desktop Account")
        #expect(auditConfig.authorizationBearerToken == "audit-token")
        #expect(auditConfig.source.accountLabel == "Desktop Account")
        #expect(auditConfig.source.deviceLabel == "Mac15,3")
        #expect(auditConfig.source.platform == "macOS")
        #expect(auditConfig.source.appVersion == "2026.6+12")
    }

    @MainActor
    @Test func telemetryBuildConfigIgnoresUnresolvedBuildSettingsAndUsesEnvironmentFallbacks() async throws {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "DarkmatterTelemetryOTLPEndpoint": "$(DARKMATTER_OTLP_ENDPOINT)",
                "DarkmatterTelemetryBearerToken": "$(DARKMATTER_OTLP_BEARER_TOKEN)",
                "DarkmatterAuditLogBearerToken": "$(DARKMATTER_AUDIT_LOG_BEARER_TOKEN)",
                "DarkmatterTelemetryEnvironment": "$(DARKMATTER_TELEMETRY_ENVIRONMENT)",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)"
            ],
            environment: [
                "DARKMATTER_OTLP_ENDPOINT": "https://env.example/v1/metrics",
                "OTLP_TOKEN_DARKMATTER_MAC": "env-otlp-token",
                "AUDIT_LOG_TOKEN_DARKMATTER_MAC": "env-audit-token",
                "DARKMATTER_TELEMETRY_ENVIRONMENT": "staging"
            ],
            osVersion: "Version 26.0",
            deviceModelIdentifier: nil
        )

        #expect(config.otlpEndpoint == "https://env.example/v1/metrics")
        #expect(config.bearerToken == "env-otlp-token")
        #expect(config.auditLogBearerToken == "env-audit-token")
        #expect(config.deploymentEnvironment == "staging")
        #expect(config.serviceVersion == "1.2.3")
    }

    @MainActor
    @Test func privacySecuritySettingsLoadAndPersistTelemetryAndAuditToggles() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: true,
            exportIntervalSeconds: 120
        )
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: false)
        runtime.storedAuditLogFiles = [
            AuditLogFileFfi(
                accountRef: account.label,
                path: "/tmp/audit-1.jsonl",
                fileName: "audit-1.jsonl",
                sizeBytes: 512,
                modifiedAtMs: 1_800_000_000_000
            )
        ]
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(
                    telemetryToken: "otlp-token",
                    auditToken: "audit-token",
                    environment: "production"
                )
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()

        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.privacySecuritySettings.relayTelemetryIntervalSeconds == 120)
        #expect(!state.privacySecuritySettings.auditLoggingEnabled)
        #expect(state.privacySecuritySettings.telemetryCredentialsAvailable)
        #expect(state.privacySecuritySettings.auditLogCredentialsAvailable)
        #expect(state.auditLogFiles.count == 1)
        #expect(runtime.relayTelemetryRuntimeConfig?.authorizationBearerToken == "otlp-token")
        let telemetryResource = runtime.relayTelemetryRuntimeConfig?.resource
        #expect(telemetryResource?.serviceVersion == expectedTelemetryServiceVersion())
        #expect(telemetryResource?.serviceInstanceId == "test-install-id")
        #expect(telemetryResource?.deploymentEnvironment == "production")
        #expect(telemetryResource?.tenant == "whitenoise-mac")
        #expect(telemetryResource?.osType == "darwin")
        #expect(telemetryResource?.osVersion == ProcessInfo.processInfo.operatingSystemVersionString)
        #expect(telemetryResource?.deviceModelIdentifier == expectedDeviceModelIdentifier())
        #expect(runtime.auditLogTrackerConfig?.authorizationBearerToken == "audit-token")
        #expect(runtime.auditLogTrackerConfig?.source.accountLabel == "Desktop Account")

        await state.setRelayTelemetryEnabled(false)
        await state.setAuditLoggingEnabled(true)

        #expect(!runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(runtime.storedRelayTelemetrySettings.exportIntervalSeconds == 120)
        #expect(runtime.storedAuditLogSettings.enabled)
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.privacySecuritySettings.auditLoggingEnabled)
    }

    @MainActor
    @Test func enablingPrivacySecurityTogglesRequireConfiguredTokens() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: nil, auditToken: nil)
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()

        await state.setRelayTelemetryEnabled(true)
        #expect(!runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(state.lastError == "Telemetry credentials are not configured for this build.")

        await state.setAuditLoggingEnabled(true)

        #expect(!runtime.storedAuditLogSettings.enabled)
        #expect(state.lastError == "Audit log credentials are not configured for this build.")
    }

    @MainActor
    @Test func backgroundListenerFailureRoutesToBackgroundStatusNotLastError() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        // A background notification-listener failure must not surface on the shared
        // per-screen error field that login/settings/new-chat render (issue #24).
        runtime.subscribeNotificationsError = NSError(
            domain: "test.background",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "background listener dropped"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        let routedToBackground = await waitFor {
            state.backgroundStatus == "background listener dropped"
        }
        #expect(routedToBackground)
        // The user-facing per-screen error field must remain untouched.
        #expect(state.lastError == nil)

        // The banner is dismissible without affecting lastError.
        state.clearBackgroundStatus()
        #expect(state.backgroundStatus == nil)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func notificationDeliveryFailureRoutesToBackgroundStatusNotLastError() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        // `handleNotificationUpdate(_:)` runs on the background notification listener.
        // A failure posting the local notification must surface on the non-modal
        // background banner, never on the per-screen `lastError` that login/settings/
        // new-chat render (issue #24 — see PR #49 review finding).
        let notificationCenter = FakeLocalNotificationCenter(
            status: .authorized,
            postError: NSError(
                domain: "test.notification",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "notification delivery failed"]
            )
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "notice-1",
            groupIdHex: "direct-group",
            senderName: "Alice",
            previewText: "See you there."
        ))

        #expect(state.backgroundStatus == "notification delivery failed")
        // The user-facing per-screen error field must remain untouched.
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func auditLogFileActionsRefreshDeleteAndUploadThroughRuntime() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: true)
        runtime.storedAuditLogFiles = [
            AuditLogFileFfi(
                accountRef: account.label,
                path: "/tmp/audit-1.jsonl",
                fileName: "audit-1.jsonl",
                sizeBytes: 123,
                modifiedAtMs: nil
            ),
            AuditLogFileFfi(
                accountRef: account.label,
                path: "/tmp/audit-2.jsonl",
                fileName: "audit-2.jsonl",
                sizeBytes: 456,
                modifiedAtMs: nil
            )
        ]
        runtime.nextAuditLogTrackerUpdate = AuditLogTrackerUpdateResultFfi(
            enabled: true,
            uploaded: [
                AuditLogUploadResultFfi(path: "/tmp/audit-1.jsonl", status: 200, bytesSent: 123),
                AuditLogUploadResultFfi(path: "/tmp/audit-2.jsonl", status: 200, bytesSent: 456)
            ],
            skippedReason: nil
        )
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: "otlp-token", auditToken: "audit-token")
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.auditLogFiles.count == 2)

        await state.uploadAuditLogFiles()
        #expect(runtime.didPostAuditLogTrackerUpdate)
        #expect(state.auditLogUploadStatus == "Uploaded 2 audit log files (579 bytes).")

        await state.deleteAllAuditLogFiles()
        #expect(runtime.deletedAuditLogFilePaths == ["/tmp/audit-1.jsonl", "/tmp/audit-2.jsonl"])
        #expect(state.auditLogFiles.isEmpty)
    }

    @MainActor
    @Test func enablingLocalNotificationsRequestsPermissionAndUpdatesRuntime() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: false)
        let notificationCenter = FakeLocalNotificationCenter(
            status: .notDetermined,
            requestedStatus: .authorized
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setLocalNotificationsEnabled(true)

        #expect(notificationCenter.didRequestAuthorization)
        #expect(runtime.localNotificationsEnabledSet == true)
        #expect(state.notificationSettings.localNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus == .authorized)
    }

    @MainActor
    @Test func enablingLocalNotificationsShowsSettingsGuidanceWhenMacNotificationsAreNotAllowed() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: false)
        let notificationCenter = FakeLocalNotificationCenter(
            status: .notDetermined,
            requestError: NSError(
                domain: UNErrorDomain,
                code: UNError.Code.notificationsNotAllowed.rawValue
            )
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setLocalNotificationsEnabled(true)

        #expect(notificationCenter.didRequestAuthorization)
        #expect(runtime.localNotificationsEnabledSet == nil)
        #expect(!state.notificationSettings.localNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus == .denied)
        #expect(state.lastError == "Open System Settings > Notifications and allow White Noise notifications, then try again.")
    }

    @MainActor
    @Test func incomingNotificationPostsLocalAlertWhenEnabledAndInactive() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "notice-1",
            groupIdHex: "direct-group",
            senderName: "Alice",
            previewText: "See you there."
        ))

        #expect(notificationCenter.postedRequests.count == 1)
        #expect(notificationCenter.postedRequests.first?.identifier == "notice-1")
        #expect(notificationCenter.postedRequests.first?.title == "Alice")
        #expect(notificationCenter.postedRequests.first?.body == "See you there.")
        #expect(notificationCenter.postedRequests.first?.threadIdentifier == "direct-group")
        #expect(notificationCenter.postedRequests.first?.userInfo["groupIdHex"] == "direct-group")
    }

    @MainActor
    @Test func activeChatNotificationIsSuppressedWhileAppIsActive() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "notice-1",
            groupIdHex: "direct-group",
            senderName: "Alice",
            previewText: "See you there."
        ))

        #expect(state.selection == .chat("direct-group"))
        #expect(notificationCenter.postedRequests.isEmpty)
    }

    @MainActor
    @Test func selfNotificationsAndDuplicatesAreSuppressed() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "self-notice",
            senderName: "Desktop Account",
            previewText: "Sent by me.",
            isFromSelf: true
        ))
        let incoming = notificationUpdate(
            account: account,
            notificationKey: "duplicate-notice",
            senderName: "Alice",
            previewText: "Only once."
        )
        await state.handleNotificationUpdate(incoming)
        await state.handleNotificationUpdate(incoming)

        #expect(notificationCenter.postedRequests.map(\.identifier) == ["duplicate-notice"])
    }

    @MainActor
    @Test func notificationResponseSelectsConversation() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
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
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.showSettings()
        notificationCenter.simulateResponse([
            "accountRef": account.label,
            "accountIdHex": account.accountIdHex,
            "groupIdHex": "direct-group"
        ])

        #expect(state.activeAccountId == account.label)
        #expect(state.selection == .chat("direct-group"))
    }

    @MainActor
    @Test func publishingNewKeyPackageRefreshesPackageList() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.publishNewKeyPackage()

        #expect(runtime.didPublishNewKeyPackage)
        #expect(state.keyPackages.map(\.eventIdHex).contains("event-new"))
    }

    @MainActor
    @Test func deletingKeyPackageUsesAccountRelayBootstrapRelaysAndRefreshes() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.loadKeyPackages()
        guard let fetchedPackage = state.keyPackages.last else {
            Issue.record("Expected a fetched key package")
            return
        }
        await state.deleteKeyPackage(fetchedPackage)

        #expect(runtime.deletedPackageEventId == "event-fetched")
        #expect(runtime.lastPackageDeleteRelays == bootstrapRelays)
        #expect(!state.keyPackages.map(\.eventIdHex).contains("event-fetched"))
    }

    @MainActor
    @Test func savingProfileUsesAccountRelayLists() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let publishRelays = ["wss://published.example"]
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: publishRelays,
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        state.profileDraft.displayName = "Desktop Renamed"
        await state.saveProfile()

        #expect(runtime.lastPublishedProfileDefaultRelays == publishRelays)
        #expect(runtime.lastPublishedProfileBootstrapRelays == bootstrapRelays)
        #expect(state.profileDraft.displayName == "Desktop Renamed")
    }

    @MainActor
    @Test func savingRelaySettingsUsesExistingBootstrapRelays() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://old-nip65.example"],
            inbox: ["wss://old-inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        state.selectRelaySection(.inbox)
        state.relayDraft = ["wss://new-inbox.example"]
        await state.saveRelaySettings()

        #expect(runtime.lastSetInboxBootstrapRelays == bootstrapRelays)
        #expect(state.relaySettings.inbox == ["wss://new-inbox.example"])
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

private actor FakeGroupImageSearchClient: GroupImageSearchClient {
    private let results: [GroupImageSearchResult]
    private(set) var queries: [String] = []

    init(results: [GroupImageSearchResult]) {
        self.results = results
    }

    func searchImages(query: String) async throws -> [GroupImageSearchResult] {
        queries.append(query)
        return results
    }
}

private nonisolated final class FakeMarmotRuntime: MarmotRuntime, @unchecked Sendable {
    private var storedAccounts: [AccountSummaryFfi]
    private let createdAccount: AccountSummaryFfi?
    private(set) var didStart = false
    let storageRootPath = "/tmp/whitenoise-mac-tests"
    private var profile = UserProfileMetadataFfi(
        name: "desktop",
        displayName: "Desktop Account",
        about: nil,
        picture: "https://example.com/avatar.png",
        nip05: nil,
        lud16: nil
    )
    private var relayLists = AccountRelayListsFfi(
        complete: true,
        missing: [],
        defaultRelays: MarmotClient.seedRelays,
        bootstrapRelays: MarmotClient.seedRelays,
        nip65: RelayListFfi(kind: 10002, relays: MarmotClient.seedRelays),
        inbox: RelayListFfi(kind: 10050, relays: MarmotClient.seedRelays)
    )
    private var keyPackages = [
        AccountKeyPackageFfi(
            accountRef: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "slot-local",
            keyPackageRefHex: "ref-local",
            eventIdHex: "event-local",
            publishedAt: 1_700_000_000,
            keyPackageBytes: 512,
            sourceRelays: MarmotClient.seedRelays,
            local: true,
            relay: false
        ),
        AccountKeyPackageFfi(
            accountRef: nil,
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "slot-fetched",
            keyPackageRefHex: "ref-fetched",
            eventIdHex: "event-fetched",
            publishedAt: 1_700_000_100,
            keyPackageBytes: 520,
            sourceRelays: [],
            local: false,
            relay: true
        )
    ]
    private var groups: [AppGroupRecordFfi] = []
    private var messagesByGroupId: [String: [AppMessageRecordFfi]] = [:]
    private var timelinePagesByGroupId: [String: TimelinePageFfi] = [:]
    private var timelineUpdatesByGroupId: [String: [TimelineSubscriptionUpdateFfi]] = [:]
    private var chatListUpdates: [ChatListSubscriptionUpdateFfi] = []
    private(set) var createdGroupMemberRefs: [String] = []
    private(set) var createdGroupName: String?
    private(set) var createdGroupDescription: String?
    private(set) var repliedMessage: SentReply?
    private(set) var reactedMessage: SentReaction?
    private(set) var deletedMessage: DeletedMessage?
    private(set) var updatedGroupAvatar: UpdatedGroupAvatar?
    private(set) var updatedGroupProfile: UpdatedGroupProfile?
    private(set) var archivedGroup: ArchivedGroup?
    private(set) var leftGroupIdHex: String?
    private(set) var invitedMemberRefs: [String] = []
    private(set) var promotedAdminRef: String?
    private(set) var demotedAdminRef: String?
    private(set) var selfDemotedGroupIdHex: String?
    private(set) var removedMemberRefs: [String] = []
    private(set) var lastPackageFetchBootstrapRelays: [String] = []
    private(set) var didPublishNewKeyPackage = false
    private(set) var didRepublishKeyPackage = false
    private(set) var deletedPackageEventId: String?
    private(set) var lastPackageDeleteRelays: [String] = []
    private(set) var lastPublishedProfileDefaultRelays: [String] = []
    private(set) var lastPublishedProfileBootstrapRelays: [String] = []
    private(set) var lastSetInboxBootstrapRelays: [String] = []
    private(set) var lastSetNip65BootstrapRelays: [String] = []
    private(set) var refreshedProfileIds: [String] = []
    private(set) var markedReadMessageIds: [String] = []
    private(set) var accountKeyPackagesCallCount = 0
    private(set) var chatListSubscriptionCount = 0
    private(set) var timelineSubscriptionCount = 0
    private(set) var lastTimelineSubscription: FakeTimelineMessagesSubscription?
    private(set) var timelineMessageQueries: [TimelineMessageQueryFfi] = []
    var profileRefreshDelaysByAccountId: [String: UInt64] = [:]
    var accountIdsMissingProfiles = Set<String>()
    var timelineMessagesHandler: ((TimelineMessageQueryFfi) -> TimelinePageFfi)?
    /// When set, `subscribeNotifications()` throws this error, simulating a background
    /// notification-listener failure for routing tests.
    var subscribeNotificationsError: Error?
    /// Simulates the async relay/runtime delay before the first timeline snapshot is available.
    var timelineSubscriptionDelayNanoseconds: UInt64 = 0
    var timelineUpdateDelayNanoseconds: UInt64 = 0
    private var profilesByAccountId: [String: UserProfileMetadataFfi] = [:]
    private var normalizedMembersByRef: [String: MemberRefFfi] = [:]
    private var groupDetailsById: [String: GroupDetailsFfi] = [:]
    private var groupManagementStateById: [String: GroupManagementStateFfi] = [:]
    var notificationSettings = NotificationSettingsFfi(
        accountRef: "Desktop Account",
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        localNotificationsEnabled: false,
        nativePushEnabled: false
    )
    var storedAuditLogSettings = AuditLogSettingsFfi(enabled: false)
    var storedAuditLogFiles: [AuditLogFileFfi] = []
    var nextAuditLogTrackerUpdate = AuditLogTrackerUpdateResultFfi(
        enabled: true,
        uploaded: [],
        skippedReason: nil
    )
    var storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
        exportEnabled: false,
        exportIntervalSeconds: 60
    )
    private(set) var localNotificationsEnabledSet: Bool?
    private(set) var auditLogTrackerConfig: AuditLogTrackerConfigFfi?
    private(set) var deletedAuditLogFilePaths: [String] = []
    private(set) var didPostAuditLogTrackerUpdate = false
    private(set) var relayTelemetryRuntimeConfig: RelayTelemetryRuntimeConfigFfi?
    private(set) var removedAccountRefs: [String] = []
    private(set) var didDeleteAllLocalData = false

    init(accounts: [AccountSummaryFfi], createdAccount: AccountSummaryFfi? = nil) {
        self.storedAccounts = accounts
        self.createdAccount = createdAccount
    }

    func start() async throws {
        didStart = true
    }

    func listAccounts() throws -> [AccountSummaryFfi] {
        storedAccounts
    }

    func npub(accountIdHex: String) -> String? {
        "npub1\(accountIdHex.prefix(12))"
    }

    func displayName(accountIdHex: String) -> String? {
        guard !accountIdsMissingProfiles.contains(accountIdHex) else { return nil }
        let resolvedProfile = profilesByAccountId[accountIdHex] ?? profile
        return resolvedProfile.displayName ?? resolvedProfile.name
    }

    func userProfile(accountIdHex: String) throws -> UserProfileMetadataFfi? {
        guard !accountIdsMissingProfiles.contains(accountIdHex) else { return nil }
        return profilesByAccountId[accountIdHex] ?? profile
    }

    func normalizeMemberRef(memberRef: String) throws -> MemberRefFfi {
        if let member = normalizedMembersByRef[memberRef] {
            return member
        }
        return MemberRefFfi(
            memberRef: memberRef,
            accountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            npub: "npub1alice"
        )
    }

    func refreshProfile(accountIdHex: String, relays: [String]) async throws {
        refreshedProfileIds.append(accountIdHex)
        if let delay = profileRefreshDelaysByAccountId[accountIdHex] {
            try await Task.sleep(nanoseconds: delay)
        }
    }

    func clearRefreshedProfileIds() {
        refreshedProfileIds = []
    }

    func clearTimelineMessageQueries() {
        timelineMessageQueries = []
    }

    func installDirectGroup(
        _ group: AppGroupRecordFfi,
        selfAccountIdHex: String,
        otherAccountIdHex: String,
        otherDisplayName: String,
        otherProfile: UserProfileMetadataFfi
    ) {
        groups = [group]
        profilesByAccountId[otherAccountIdHex] = otherProfile
        let details = GroupDetailsFfi(
            group: group,
            members: [
                GroupMemberDetailsFfi(
                    memberIdHex: selfAccountIdHex,
                    account: "Desktop Account",
                    local: true,
                    isAdmin: true,
                    isSelf: true,
                    npub: "npub1self",
                    displayName: "Desktop Account"
                ),
                GroupMemberDetailsFfi(
                    memberIdHex: otherAccountIdHex,
                    account: nil,
                    local: false,
                    isAdmin: false,
                    isSelf: false,
                    npub: "npub1alice",
                    displayName: otherDisplayName
                )
            ]
        )
        groupDetailsById[group.groupIdHex] = details
        groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
    }

    func installMessages(_ messages: [AppMessageRecordFfi], groupIdHex: String) {
        messagesByGroupId[groupIdHex] = messages
        timelinePagesByGroupId[groupIdHex] = projectedTimeline(from: messages)
    }

    func installGroup(_ group: AppGroupRecordFfi) {
        groups = [group]
        let details = GroupDetailsFfi(group: group, members: [])
        groupDetailsById[group.groupIdHex] = details
        groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
    }

    func installGroups(_ groups: [AppGroupRecordFfi]) {
        self.groups = groups
        for group in groups {
            let details = GroupDetailsFfi(group: group, members: [])
            groupDetailsById[group.groupIdHex] = details
            groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
        }
    }

    func installGroupDetails(_ details: GroupDetailsFfi, managementState: GroupManagementStateFfi? = nil) {
        groups = [details.group]
        groupDetailsById[details.group.groupIdHex] = details
        groupManagementStateById[details.group.groupIdHex] = managementState ?? defaultGroupManagementState(for: details)
    }

    func installChatListUpdates(_ updates: [ChatListSubscriptionUpdateFfi]) {
        chatListUpdates = updates
    }

    func installTimelineUpdates(_ updates: [TimelineSubscriptionUpdateFfi], groupIdHex: String) {
        timelineUpdatesByGroupId[groupIdHex] = updates
    }

    func installProfile(accountIdHex: String, profile: UserProfileMetadataFfi) {
        profilesByAccountId[accountIdHex] = profile
    }

    func installRelayLists(
        defaultRelays: [String],
        bootstrapRelays: [String],
        nip65: [String],
        inbox: [String],
        complete: Bool = true,
        missing: [String] = []
    ) {
        relayLists = AccountRelayListsFfi(
            complete: complete,
            missing: missing,
            defaultRelays: defaultRelays,
            bootstrapRelays: bootstrapRelays,
            nip65: RelayListFfi(kind: 10002, relays: nip65),
            inbox: RelayListFfi(kind: 10050, relays: inbox)
        )
    }

    func installNormalizedMemberRef(query: String, accountIdHex: String, npub: String) {
        normalizedMembersByRef[query] = MemberRefFfi(
            memberRef: query,
            accountIdHex: accountIdHex,
            npub: npub
        )
    }

    func createIdentity(defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        guard let createdAccount else { throw FakeMarmotRuntimeError.missingCreatedAccount }
        storedAccounts = [createdAccount]
        return createdAccount
    }

    func login(identity: String, defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        guard let createdAccount else { throw FakeMarmotRuntimeError.missingCreatedAccount }
        storedAccounts = [createdAccount]
        return createdAccount
    }

    func publishUserProfile(accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]) async throws -> UserProfileMetadataFfi {
        lastPublishedProfileDefaultRelays = defaultRelays
        lastPublishedProfileBootstrapRelays = bootstrapRelays
        self.profile = profile
        return profile
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        relayLists
    }

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        accountKeyPackagesCallCount += 1
        lastPackageFetchBootstrapRelays = bootstrapRelays
        return keyPackages
    }

    func auditLogFiles() throws -> [AuditLogFileFfi] {
        storedAuditLogFiles
    }

    func auditLogSettings() throws -> AuditLogSettingsFfi {
        storedAuditLogSettings
    }

    func deleteAuditLogFile(path: String) async throws -> AuditLogDeleteResultFfi {
        deletedAuditLogFilePaths.append(path)
        storedAuditLogFiles.removeAll { $0.path == path }
        return AuditLogDeleteResultFfi(stillRecording: storedAuditLogSettings.enabled)
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        notificationSettings
    }

    func postAuditLogTrackerUpdate() async throws -> AuditLogTrackerUpdateResultFfi {
        didPostAuditLogTrackerUpdate = true
        return nextAuditLogTrackerUpdate
    }

    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi {
        storedRelayTelemetrySettings
    }

    func setAuditLogSettings(settings: AuditLogSettingsFfi) async throws -> AuditLogSettingsFfi {
        storedAuditLogSettings = settings
        return storedAuditLogSettings
    }

    func setAuditLogTrackerConfig(config: AuditLogTrackerConfigFfi) throws -> AuditLogTrackerConfigFfi {
        auditLogTrackerConfig = config
        return config
    }

    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi {
        localNotificationsEnabledSet = enabled
        notificationSettings.localNotificationsEnabled = enabled
        return notificationSettings
    }

    func setRelayTelemetryRuntimeConfig(config: RelayTelemetryRuntimeConfigFfi) async throws {
        relayTelemetryRuntimeConfig = config
    }

    func setRelayTelemetrySettings(settings: RelayTelemetrySettingsFfi) async throws -> RelayTelemetrySettingsFfi {
        storedRelayTelemetrySettings = settings
        return storedRelayTelemetrySettings
    }

    func telemetryInstallId() throws -> String {
        "test-install-id"
    }

    func deleteAllLocalData() async throws {
        didDeleteAllLocalData = true
        storedAccounts = []
        groups = []
        messagesByGroupId = [:]
        timelinePagesByGroupId = [:]
        timelineUpdatesByGroupId = [:]
        chatListUpdates = []
        storedAuditLogFiles = []
    }

    func removeAccount(accountRef: String) async throws {
        removedAccountRefs.append(accountRef)
        storedAccounts.removeAll { $0.label == accountRef }
    }

    func publishNewKeyPackage(accountRef: String) async throws -> UInt64 {
        didPublishNewKeyPackage = true
        keyPackages.append(
            AccountKeyPackageFfi(
                accountRef: accountRef,
                accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                keyPackageId: "slot-new",
                keyPackageRefHex: "ref-new",
                eventIdHex: "event-new",
                publishedAt: 1_700_000_200,
                keyPackageBytes: 524,
                sourceRelays: MarmotClient.seedRelays,
                local: true,
                relay: true
            )
        )
        return 1
    }

    func republishKeyPackage(accountRef: String) async throws -> UInt64 {
        didRepublishKeyPackage = true
        return 1
    }

    func deleteAccountKeyPackage(accountRef: String, eventIdHex: String, relays: [String]) async throws -> UInt64 {
        deletedPackageEventId = eventIdHex
        lastPackageDeleteRelays = relays
        keyPackages.removeAll { $0.eventIdHex == eventIdHex }
        return 1
    }

    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws -> String {
        createdGroupMemberRefs = memberRefs
        createdGroupName = name
        createdGroupDescription = description
        groups = [
            AppGroupRecordFfi(
                groupIdHex: "created-group",
                endpoint: "",
                name: name,
                description: description ?? "",
                admins: [],
                relays: MarmotClient.seedRelays,
                nostrGroupIdHex: "",
                avatarUrl: nil,
                avatarDim: nil,
                avatarThumbhash: nil,
                encryptedMedia: encryptedMediaComponent(),
                archived: false,
                pendingConfirmation: false,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            )
        ]
        if let group = groups.first {
            let details = GroupDetailsFfi(group: group, members: [])
            groupDetailsById[group.groupIdHex] = details
            groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
        }
        return "created-group"
    }

    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi {
        if let details = groupDetailsById[groupIdHex] {
            return details
        }
        guard let group = groups.first(where: { $0.groupIdHex == groupIdHex }) else {
            throw FakeMarmotRuntimeError.unused
        }
        return GroupDetailsFfi(group: group, members: [])
    }

    func groupManagementState(accountRef: String, groupIdHex: String) async throws -> GroupManagementStateFfi {
        if let state = groupManagementStateById[groupIdHex] {
            return state
        }
        let details = try await groupDetails(accountRef: accountRef, groupIdHex: groupIdHex)
        let state = defaultGroupManagementState(for: details)
        groupManagementStateById[groupIdHex] = state
        return state
    }

    func inviteMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws -> GroupMutationResultFfi {
        invitedMemberRefs = memberRefs
        guard var details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }

        for memberRef in memberRefs {
            let normalized = normalizedMembersByRef.values.first { member in
                member.memberRef == memberRef || member.npub == memberRef || member.accountIdHex == memberRef
            }
            let memberIdHex = normalized?.accountIdHex ?? memberRef
            guard !details.members.contains(where: { $0.memberIdHex == memberIdHex }) else { continue }
            details.members.append(
                GroupMemberDetailsFfi(
                    memberIdHex: memberIdHex,
                    account: nil,
                    local: false,
                    isAdmin: false,
                    isSelf: false,
                    npub: normalized?.npub ?? memberRef,
                    displayName: nil
                )
            )
        }
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-invite")
    }

    func leaveGroup(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        leftGroupIdHex = groupIdHex
        groups.removeAll { $0.groupIdHex == groupIdHex }
        groupDetailsById[groupIdHex] = nil
        groupManagementStateById[groupIdHex] = nil
        return SendSummaryFfi(published: 1, messageIds: ["group-leave"])
    }

    func promoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws -> GroupMutationResultFfi {
        promotedAdminRef = memberRef
        updateMember(groupIdHex: groupIdHex, matching: memberRef) { member in
            member.isAdmin = true
        }
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-promote")
    }

    func demoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws -> GroupMutationResultFfi {
        demotedAdminRef = memberRef
        updateMember(groupIdHex: groupIdHex, matching: memberRef) { member in
            member.isAdmin = false
        }
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-demote")
    }

    func removeMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws -> GroupMutationResultFfi {
        removedMemberRefs = memberRefs
        guard var details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }
        details.members.removeAll { member in
            memberRefs.contains { memberMatches(member, ref: $0) }
        }
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-remove")
    }

    func selfDemoteAdminDetailed(accountRef: String, groupIdHex: String) async throws -> GroupMutationResultFfi {
        selfDemotedGroupIdHex = groupIdHex
        guard var details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }
        if let index = details.members.firstIndex(where: \.isSelf) {
            details.members[index].isAdmin = false
        }
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-self-demote")
    }

    func setGroupArchived(accountRef: String, groupIdHex: String, archived: Bool) async throws -> AppGroupRecordFfi {
        archivedGroup = ArchivedGroup(groupIdHex: groupIdHex, archived: archived)
        guard let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) else {
            throw FakeMarmotRuntimeError.unused
        }
        groups[index].archived = archived
        if var details = groupDetailsById[groupIdHex] {
            details.group.archived = archived
            groupDetailsById[groupIdHex] = details
        }
        return groups[index]
    }

    func updateGroupAvatarUrl(accountRef: String, groupIdHex: String, url: String?, dim: String?, thumbhash: String?) async throws -> SendSummaryFfi {
        updatedGroupAvatar = UpdatedGroupAvatar(groupIdHex: groupIdHex, url: url, dim: dim, thumbhash: thumbhash)

        if let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) {
            groups[index].avatarUrl = url
            groups[index].avatarDim = dim
            groups[index].avatarThumbhash = thumbhash
        }

        if var details = groupDetailsById[groupIdHex] {
            details.group.avatarUrl = url
            details.group.avatarDim = dim
            details.group.avatarThumbhash = thumbhash
            groupDetailsById[groupIdHex] = details
        }

        return SendSummaryFfi(published: 1, messageIds: ["group-avatar"])
    }

    func updateGroupProfile(accountRef: String, groupIdHex: String, name: String?, description: String?) async throws -> SendSummaryFfi {
        updatedGroupProfile = UpdatedGroupProfile(groupIdHex: groupIdHex, name: name, description: description)

        if let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) {
            if let name {
                groups[index].name = name
            }
            if let description {
                groups[index].description = description
            }
        }

        if var details = groupDetailsById[groupIdHex] {
            if let name {
                details.group.name = name
            }
            if let description {
                details.group.description = description
            }
            groupDetailsById[groupIdHex] = details
        }

        return SendSummaryFfi(published: 1, messageIds: ["group-profile"])
    }

    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        lastSetInboxBootstrapRelays = bootstrapRelays
        relayLists.inbox = RelayListFfi(kind: relayLists.inbox.kind, relays: relays)
        return relayLists
    }

    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        lastSetNip65BootstrapRelays = bootstrapRelays
        relayLists.nip65 = RelayListFfi(kind: relayLists.nip65.kind, relays: relays)
        return relayLists
    }

    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription {
        chatListSubscriptionCount += 1
        return FakeChatListSubscription(
            rows: chatListRows(includeArchived: includeArchived),
            updates: chatListUpdates
        )
    }

    private func chatListRows(includeArchived: Bool) -> [ChatListRowFfi] {
        groups
            .filter { includeArchived || !$0.archived }
            .map { chatListRow(for: $0) }
    }

    private func groupMutationResult(groupIdHex: String, messageId: String) throws -> GroupMutationResultFfi {
        guard let details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }
        let managementState = groupManagementStateById[groupIdHex] ?? defaultGroupManagementState(for: details)
        return GroupMutationResultFfi(
            summary: SendSummaryFfi(published: 1, messageIds: [messageId]),
            details: details,
            managementState: managementState
        )
    }

    private func updateMember(
        groupIdHex: String,
        matching memberRef: String,
        update: (inout GroupMemberDetailsFfi) -> Void
    ) {
        guard var details = groupDetailsById[groupIdHex],
              let index = details.members.firstIndex(where: { memberMatches($0, ref: memberRef) })
        else { return }

        update(&details.members[index])
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
    }

    private func memberMatches(_ member: GroupMemberDetailsFfi, ref: String) -> Bool {
        member.memberIdHex == ref || member.npub == ref || member.account == ref
    }

    private func defaultGroupManagementState(for details: GroupDetailsFfi) -> GroupManagementStateFfi {
        let selfMember = details.members.first(where: \.isSelf)
        let adminCount = details.members.filter(\.isAdmin).count
        let selfIsAdmin = selfMember?.isAdmin ?? true
        let memberActions = details.members.map { member in
            GroupMemberActionStateFfi(
                memberIdHex: member.memberIdHex,
                isSelf: member.isSelf,
                isAdmin: member.isAdmin,
                canRemove: selfIsAdmin && !member.isSelf,
                canPromote: selfIsAdmin && !member.isAdmin,
                canDemote: selfIsAdmin && member.isAdmin && (!member.isSelf || adminCount > 1)
            )
        }

        return GroupManagementStateFfi(
            myAccountIdHex: selfMember?.memberIdHex ?? storedAccounts.first?.accountIdHex ?? "",
            isSelfAdmin: selfIsAdmin,
            isLastAdmin: selfIsAdmin && adminCount <= 1,
            canInvite: selfIsAdmin,
            canLeave: !selfIsAdmin || adminCount > 1,
            requiresSelfDemoteBeforeLeave: selfIsAdmin,
            memberActions: memberActions
        )
    }

    func subscribeNotifications() async throws -> NotificationsSubscription {
        if let subscribeNotificationsError {
            throw subscribeNotificationsError
        }
        return FakeNotificationsSubscription()
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        timelineMessageQueries.append(query)
        if let timelineMessagesHandler {
            return timelineMessagesHandler(query)
        }
        if let groupIdHex = query.groupIdHex {
            return pagedTimeline(from: timelinePagesByGroupId[groupIdHex]?.messages ?? [], query: query)
        }

        let messages = timelinePagesByGroupId.values.flatMap(\.messages).sorted { lhs, rhs in
            if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
            return lhs.messageIdHex < rhs.messageIdHex
        }
        return pagedTimeline(from: messages, query: query)
    }

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws -> TimelineMessagesSubscription {
        timelineSubscriptionCount += 1
        if timelineSubscriptionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: timelineSubscriptionDelayNanoseconds)
        }
        let ordered: [TimelineMessageRecordFfi]
        if let groupIdHex {
            ordered = timelinePagesByGroupId[groupIdHex]?.messages ?? []
        } else {
            ordered = timelinePagesByGroupId.values.flatMap(\.messages)
        }
        let subscription = FakeTimelineMessagesSubscription(
            messages: ordered,
            limit: Int(limit ?? 100),
            windowCap: 200,
            updates: groupIdHex.flatMap { timelineUpdatesByGroupId[$0] } ?? [],
            updateDelayNanoseconds: timelineUpdateDelayNanoseconds
        )
        lastTimelineSubscription = subscription
        return subscription
    }

    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi? {
        groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi? {
        markedReadMessageIds.append(messageIdHex)
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        throw FakeMarmotRuntimeError.unused
    }

    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws -> SendSummaryFfi {
        repliedMessage = SentReply(groupIdHex: groupIdHex, targetMessageId: targetMessageId, text: text)
        return SendSummaryFfi(published: 1, messageIds: ["reply"])
    }

    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws -> SendSummaryFfi {
        reactedMessage = SentReaction(groupIdHex: groupIdHex, targetMessageId: targetMessageId, emoji: emoji)
        return SendSummaryFfi(published: 1, messageIds: ["reaction"])
    }

    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        deletedMessage = DeletedMessage(groupIdHex: groupIdHex, targetMessageId: targetMessageId)
        return SendSummaryFfi(published: 1, messageIds: ["delete"])
    }

    private func chatListRow(for group: AppGroupRecordFfi) -> ChatListRowFfi {
        let latest = timelinePagesByGroupId[group.groupIdHex]?.messages.last(where: { $0.kind == 9 })
        return ChatListRowFfi(
            groupIdHex: group.groupIdHex,
            archived: group.archived,
            pendingConfirmation: group.pendingConfirmation,
            title: group.name.isEmpty ? DisplayText.short(group.groupIdHex) : group.name,
            groupName: group.name,
            avatarUrl: group.avatarUrl,
            avatar: nil,
            lastMessage: latest.map { message in
                ChatListMessagePreviewFfi(
                    messageIdHex: message.messageIdHex,
                    sender: message.sender,
                    senderDisplayName: displayName(accountIdHex: message.sender),
                    plaintext: message.plaintext,
                    contentTokens: message.contentTokens,
                    kind: message.kind,
                    timelineAt: message.timelineAt,
                    deleted: message.deleted
                )
            },
            unreadCount: 0,
            hasUnread: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: latest?.timelineAt,
            updatedAt: latest?.timelineAt ?? 0
        )
    }
}

private enum FakeMarmotRuntimeError: Error {
    case missingCreatedAccount
    case unused
}

private struct SentReply: Equatable {
    let groupIdHex: String
    let targetMessageId: String
    let text: String
}

private struct SentReaction: Equatable {
    let groupIdHex: String
    let targetMessageId: String
    let emoji: String
}

private struct DeletedMessage: Equatable {
    let groupIdHex: String
    let targetMessageId: String
}

private struct UpdatedGroupAvatar: Equatable {
    let groupIdHex: String
    let url: String?
    let dim: String?
    let thumbhash: String?
}

private struct UpdatedGroupProfile: Equatable {
    let groupIdHex: String
    let name: String?
    let description: String?
}

private struct ArchivedGroup: Equatable {
    let groupIdHex: String
    let archived: Bool
}

private final class FakeChatListSubscription: ChatListSubscription {
    private let rows: [ChatListRowFfi]
    private var updates: [ChatListSubscriptionUpdateFfi]

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.rows = []
        self.updates = []
        super.init(unsafeFromRawPointer: pointer)
    }

    init(rows: [ChatListRowFfi], updates: [ChatListSubscriptionUpdateFfi] = []) {
        self.rows = rows
        self.updates = updates
        super.init(noPointer: NoPointer())
    }

    override func snapshot() -> [ChatListRowFfi] {
        rows
    }

    override func next() async -> ChatListRowFfi? {
        nil
    }

    override func nextUpdate() async -> ChatListSubscriptionUpdateFfi? {
        guard !updates.isEmpty else { return nil }
        return updates.removeFirst()
    }
}

// Models the runtime's authoritative, bounded, materialized timeline window: a sliding
// [lo, hi) window over the full ordered message set, capped at `windowCap`, extended by
// `paginateBackwards`/`paginateForwards` and mutated by live `next()` updates. Mirrors the
// marmot-app windowing contract closely enough for client-level tests; the exact math is
// unit-tested in Rust.
private final class FakeTimelineMessagesSubscription: TimelineMessagesSubscription {
    private var fullSet: TimelinePageFfi
    private let limit: Int
    private let windowCap: Int
    private var lo: Int
    private var hi: Int
    private var updates: [TimelineSubscriptionUpdateFfi]
    private let updateDelayNanoseconds: UInt64
    private(set) var paginateBackwardsCount = 0
    private(set) var paginateForwardsCount = 0

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.fullSet = emptyTimelinePage()
        self.limit = 100
        self.windowCap = 200
        self.lo = 0
        self.hi = 0
        self.updates = []
        self.updateDelayNanoseconds = 0
        super.init(unsafeFromRawPointer: pointer)
    }

    init(
        messages: [TimelineMessageRecordFfi],
        limit: Int,
        windowCap: Int,
        updates: [TimelineSubscriptionUpdateFfi] = [],
        updateDelayNanoseconds: UInt64 = 0
    ) {
        var page = TimelinePageFfi(messages: messages, hasMoreBefore: false, hasMoreAfter: false)
        page.sortCanonical()
        self.fullSet = page
        self.limit = max(1, limit)
        self.windowCap = max(1, windowCap)
        self.hi = page.messages.count
        self.lo = max(0, page.messages.count - max(1, limit))
        self.updates = updates
        self.updateDelayNanoseconds = updateDelayNanoseconds
        super.init(noPointer: NoPointer())
    }

    private func windowPage() -> TimelinePageFfi {
        let count = fullSet.messages.count
        let clampedHi = min(max(hi, 0), count)
        let clampedLo = min(max(lo, 0), clampedHi)
        return TimelinePageFfi(
            messages: Array(fullSet.messages[clampedLo..<clampedHi]),
            hasMoreBefore: clampedLo > 0,
            hasMoreAfter: clampedHi < count
        )
    }

    override func snapshot() -> TimelinePageFfi? {
        windowPage()
    }

    override func paginateBackwards(count: UInt32) async throws -> TimelinePageFfi {
        paginateBackwardsCount += 1
        lo = max(0, lo - Int(count))
        if hi - lo > windowCap { hi = lo + windowCap }
        return windowPage()
    }

    override func paginateForwards(count: UInt32) async throws -> TimelinePageFfi {
        paginateForwardsCount += 1
        hi = min(fullSet.messages.count, hi + Int(count))
        if hi - lo > windowCap { lo = hi - windowCap }
        return windowPage()
    }

    override func next() async -> TimelinePageFfi? {
        guard !updates.isEmpty else { return nil }
        if updateDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: updateDelayNanoseconds)
        }
        let update = updates.removeFirst()
        let priorSpan = hi - lo
        let wasAnchored = hi >= fullSet.messages.count
        switch update {
        case .page(page: let page):
            // A head `.page` refresh never replaces a scrolled-back (detached) window.
            guard wasAnchored else { return windowPage() }
            for message in page.messages {
                if let index = fullSet.messages.firstIndex(where: { $0.messageIdHex == message.messageIdHex }) {
                    fullSet.messages[index] = message
                } else {
                    fullSet.messages.append(message)
                }
            }
            fullSet.sortCanonical()
        case .projection(update: let runtimeUpdate):
            fullSet.applyProjectionUpdate(runtimeUpdate.update)
        }
        let count = fullSet.messages.count
        if wasAnchored {
            hi = count
            lo = max(0, hi - max(limit, priorSpan))
            if hi - lo > windowCap { lo = hi - windowCap }
        } else {
            hi = min(hi, count)
            lo = min(lo, hi)
        }
        return windowPage()
    }

    override func nextUpdate() async -> TimelineSubscriptionUpdateFfi? {
        guard !updates.isEmpty else { return nil }
        if updateDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: updateDelayNanoseconds)
        }
        return updates.removeFirst()
    }
}

private extension TimelinePageFfi {
    mutating func sortCanonical() {
        messages.sort {
            if $0.timelineAt != $1.timelineAt { return $0.timelineAt < $1.timelineAt }
            return $0.messageIdHex < $1.messageIdHex
        }
    }

    mutating func applyProjectionUpdate(_ update: TimelineProjectionUpdateFfi) {
        if update.changes.isEmpty {
            for message in update.messages {
                upsert(message)
            }
        } else {
            for change in update.changes {
                switch change {
                case .upsert(trigger: _, message: let message):
                    upsert(message)
                case .remove(messageIdHex: let messageIdHex, reason: _):
                    messages.removeAll { $0.messageIdHex == messageIdHex }
                }
            }
        }
        messages.sort {
            if $0.timelineAt != $1.timelineAt { return $0.timelineAt < $1.timelineAt }
            return $0.messageIdHex < $1.messageIdHex
        }
    }

    private mutating func upsert(_ message: TimelineMessageRecordFfi) {
        if let index = messages.firstIndex(where: { $0.messageIdHex == message.messageIdHex }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }
}

@MainActor
private final class FakeLocalNotificationCenter: LocalNotificationCenter {
    private(set) var status: LocalNotificationAuthorizationStatus
    private let requestedStatus: LocalNotificationAuthorizationStatus
    private let requestError: Error?
    private let postError: Error?
    private(set) var didRequestAuthorization = false
    private(set) var postedRequests: [LocalNotificationRequest] = []
    private var responseHandler: (@MainActor ([String: String]) -> Void)?

    init(
        status: LocalNotificationAuthorizationStatus = .authorized,
        requestedStatus: LocalNotificationAuthorizationStatus = .authorized,
        requestError: Error? = nil,
        postError: Error? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
        self.requestError = requestError
        self.postError = postError
    }

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus {
        didRequestAuthorization = true
        if let requestError {
            throw requestError
        }
        status = requestedStatus
        return status
    }

    func post(_ notification: LocalNotificationRequest) async throws {
        if let postError {
            throw postError
        }
        postedRequests.append(notification)
    }

    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void) {
        responseHandler = handler
    }

    func simulateResponse(_ userInfo: [String: String]) {
        responseHandler?(userInfo)
    }
}

private final class FakeNotificationsSubscription: NotificationsSubscription {
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        super.init(unsafeFromRawPointer: pointer)
    }

    init() {
        super.init(noPointer: NoPointer())
    }

    override func next() async -> NotificationUpdateFfi? {
        nil
    }
}

private func appMessage(
    id: String,
    direction: String = "inbound",
    groupIdHex: String,
    sender: String,
    plaintext: String,
    kind: UInt64,
    tags: [MessageTagFfi] = [],
    recordedAt: UInt64
) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: id,
        direction: direction,
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        contentTokens: emptyMarkdownDocument(),
        kind: kind,
        tags: tags,
        recordedAt: recordedAt,
        receivedAt: recordedAt
    )
}

private func projectedTimeline(from messages: [AppMessageRecordFfi]) -> TimelinePageFfi {
    let deletedMessageIds = Set(
        messages
            .filter { $0.kind == 5 }
            .compactMap { firstTagValue("e", in: $0.tags) }
    )
    let visibleMessages = messages.filter { message in
        message.kind != 5
            && message.kind != 7
            && !deletedMessageIds.contains(message.messageIdHex)
    }
    let visibleById = visibleMessages.reduce(into: [String: AppMessageRecordFfi]()) { result, message in
        result[message.messageIdHex] = message
    }
    let reactionsByTarget = Dictionary(grouping: messages.compactMap { message -> TimelineUserReactionFfi? in
        guard message.kind == 7,
              !deletedMessageIds.contains(message.messageIdHex),
              let targetMessageId = firstTagValue("e", in: message.tags)
        else {
            return nil
        }

        let emoji = message.plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty else { return nil }
        return TimelineUserReactionFfi(
            reactionMessageIdHex: message.messageIdHex,
            targetMessageIdHex: targetMessageId,
            sender: message.sender,
            emoji: emoji,
            reactedAt: message.recordedAt
        )
    }, by: \.targetMessageIdHex)

    let timelineMessages = visibleMessages.map { message in
        TimelineMessageRecordFfi(
            messageIdHex: message.messageIdHex,
            sourceMessageIdHex: nil,
            direction: message.direction,
            groupIdHex: message.groupIdHex,
            sender: message.sender,
            plaintext: message.plaintext,
            contentTokens: message.contentTokens,
            kind: message.kind,
            tags: message.tags,
            timelineAt: message.recordedAt,
            receivedAt: message.receivedAt,
            replyToMessageIdHex: firstTagValue("q", in: message.tags),
            replyPreview: firstTagValue("q", in: message.tags).flatMap { replyId in
                visibleById[replyId].map { reply in
                    TimelineReplyPreviewFfi(
                        messageIdHex: reply.messageIdHex,
                        sender: reply.sender,
                        plaintext: reply.plaintext,
                        contentTokens: reply.contentTokens,
                        kind: reply.kind,
                        mediaJson: nil,
                        agentTextStreamJson: nil,
                        deleted: false
                    )
                }
            },
            mediaJson: nil,
            agentTextStreamJson: nil,
            reactions: projectedReactionSummary(reactionsByTarget[message.messageIdHex] ?? []),
            deleted: false,
            deletedByMessageIdHex: nil,
            invalidationStatus: nil
        )
    }
    .sorted { lhs, rhs in
        if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
        return lhs.messageIdHex < rhs.messageIdHex
    }

    return TimelinePageFfi(messages: timelineMessages, hasMoreBefore: false, hasMoreAfter: false)
}

private func pagedTimeline(
    from messages: [TimelineMessageRecordFfi],
    query: TimelineMessageQueryFfi
) -> TimelinePageFfi {
    let sortedMessages = messages.sorted { lhs, rhs in
        if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
        return lhs.messageIdHex < rhs.messageIdHex
    }
    let limit = Int(query.limit ?? 50)

    if let before = query.before, let beforeMessageId = query.beforeMessageId {
        let olderMessages = sortedMessages.filter { message in
            message.timelineAt < before
                || (message.timelineAt == before && message.messageIdHex < beforeMessageId)
        }
        let pageMessages = Array(olderMessages.suffix(limit))
        return TimelinePageFfi(
            messages: pageMessages,
            hasMoreBefore: olderMessages.count > pageMessages.count,
            hasMoreAfter: true
        )
    }

    if let after = query.after, let afterMessageId = query.afterMessageId {
        let newerMessages = sortedMessages.filter { message in
            message.timelineAt > after
                || (message.timelineAt == after && message.messageIdHex > afterMessageId)
        }
        let pageMessages = Array(newerMessages.prefix(limit))
        return TimelinePageFfi(
            messages: pageMessages,
            hasMoreBefore: true,
            hasMoreAfter: newerMessages.count > pageMessages.count
        )
    }

    let pageMessages = Array(sortedMessages.suffix(limit))
    return TimelinePageFfi(
        messages: pageMessages,
        hasMoreBefore: sortedMessages.count > pageMessages.count,
        hasMoreAfter: false
    )
}

private func timelineMessage(
    id: String,
    direction: String = "inbound",
    groupIdHex: String,
    sender: String,
    plaintext: String,
    kind: UInt64 = 9,
    tags: [MessageTagFfi] = [],
    recordedAt: UInt64,
    mediaJson: String? = nil,
    agentTextStreamJson: String? = nil,
    reactions: TimelineReactionSummaryFfi = projectedReactionSummary([])
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: id,
        sourceMessageIdHex: nil,
        direction: direction,
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        contentTokens: emptyMarkdownDocument(),
        kind: kind,
        tags: tags,
        timelineAt: recordedAt,
        receivedAt: recordedAt,
        replyToMessageIdHex: nil,
        replyPreview: nil,
        mediaJson: mediaJson,
        agentTextStreamJson: agentTextStreamJson,
        reactions: reactions,
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

private func chatListRow(
    groupIdHex: String,
    title: String,
    preview: String,
    sender: String,
    timelineAt: UInt64,
    kind: UInt64 = 9
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: groupIdHex,
        archived: false,
        pendingConfirmation: false,
        title: title,
        groupName: "",
        avatarUrl: nil,
        avatar: nil,
        lastMessage: ChatListMessagePreviewFfi(
            messageIdHex: "preview",
            sender: sender,
            senderDisplayName: nil,
            plaintext: preview,
            contentTokens: emptyMarkdownDocument(),
            kind: kind,
            timelineAt: timelineAt,
            deleted: false
        ),
        unreadCount: 0,
        hasUnread: false,
        firstUnreadMessageIdHex: nil,
        lastReadMessageIdHex: nil,
        lastReadTimelineAt: nil,
        updatedAt: timelineAt
    )
}

private func projectedReactionSummary(_ reactions: [TimelineUserReactionFfi]) -> TimelineReactionSummaryFfi {
    let byEmoji = Dictionary(grouping: reactions, by: \.emoji)
        .map { emoji, reactions in
            TimelineReactionEmojiFfi(emoji: emoji, senders: reactions.map(\.sender))
        }
        .sorted { lhs, rhs in
            if lhs.senders.count != rhs.senders.count {
                return lhs.senders.count > rhs.senders.count
            }
            return lhs.emoji < rhs.emoji
        }

    return TimelineReactionSummaryFfi(byEmoji: byEmoji, userReactions: reactions)
}

private func firstTagValue(_ name: String, in tags: [MessageTagFfi]) -> String? {
    tags.first { tag in
        tag.values.first == name && tag.values.count > 1
    }?.values[1]
}

private func emptyTimelinePage() -> TimelinePageFfi {
    TimelinePageFfi(
        messages: [],
        hasMoreBefore: false,
        hasMoreAfter: false
    )
}

@MainActor
private func waitFor(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<20 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}

private func notificationSettings(
    for account: AccountSummaryFfi,
    localEnabled: Bool
) -> NotificationSettingsFfi {
    NotificationSettingsFfi(
        accountRef: account.label,
        accountIdHex: account.accountIdHex,
        localNotificationsEnabled: localEnabled,
        nativePushEnabled: false
    )
}

private func telemetryBuildConfig(
    telemetryToken: String? = "otlp-token",
    auditToken: String? = "audit-token",
    environment: String = "production",
    serviceVersion: String = expectedTelemetryServiceVersion(),
    osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
    deviceModelIdentifier: String? = expectedDeviceModelIdentifier()
) -> TelemetryBuildConfig {
    TelemetryBuildConfig(
        otlpEndpoint: TelemetryBuildConfig.defaultOtlpEndpoint,
        bearerToken: telemetryToken,
        auditLogBearerToken: auditToken,
        deploymentEnvironment: environment,
        serviceVersion: serviceVersion,
        osVersion: osVersion,
        deviceModelIdentifier: deviceModelIdentifier
    )
}

private func expectedTelemetryServiceVersion(bundle: Bundle = .main) -> String {
    let shortVersion = nonBlank(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    let buildVersion = nonBlank(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    return "\(shortVersion)+\(buildVersion)"
}

private func expectedDeviceModelIdentifier() -> String? {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }

    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
        return nil
    }
    return nonBlank(String(cString: value))
}

private func nonBlank(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

private func notificationUpdate(
    account: AccountSummaryFfi,
    notificationKey: String,
    groupIdHex: String = "direct-group",
    senderName: String,
    previewText: String,
    isFromSelf: Bool = false
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: notificationKey,
        conversationKey: groupIdHex,
        trigger: .newMessage,
        accountRef: account.label,
        accountIdHex: account.accountIdHex,
        groupIdHex: groupIdHex,
        groupName: nil,
        isDm: true,
        messageIdHex: "\(notificationKey)-message",
        sender: NotificationUserFfi(
            accountIdHex: isFromSelf ? account.accountIdHex : "alice1234567890alice1234567890alice1234567890alice1234567890",
            displayName: senderName,
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: account.accountIdHex,
            displayName: account.label,
            pictureUrl: nil
        ),
        previewText: previewText,
        timestampMs: 1_700_000_000_000,
        isFromSelf: isFromSelf
    )
}

private func desktopAccount() -> AccountSummaryFfi {
    AccountSummaryFfi(
        label: "Desktop Account",
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        localSigning: true,
        running: true
    )
}

private func groupDetailsFixture(
    selfAccountIdHex: String,
    selfIsAdmin: Bool = true,
    otherIsAdmin: Bool = false
) -> GroupDetailsFfi {
    var group = messageGroup()
    group.description = "Original room"
    let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
    group.admins = [
        selfIsAdmin ? selfAccountIdHex : nil,
        otherIsAdmin ? aliceIdHex : nil
    ].compactMap(\.self)
    return GroupDetailsFfi(
        group: group,
        members: [
            GroupMemberDetailsFfi(
                memberIdHex: selfAccountIdHex,
                account: "Desktop Account",
                local: true,
                isAdmin: selfIsAdmin,
                isSelf: true,
                npub: "npub1self",
                displayName: "Desktop Account"
            ),
            GroupMemberDetailsFfi(
                memberIdHex: aliceIdHex,
                account: nil,
                local: false,
                isAdmin: otherIsAdmin,
                isSelf: false,
                npub: "npub1alice",
                displayName: "Alice"
            ),
            GroupMemberDetailsFfi(
                memberIdHex: "bob1234567890bob1234567890bob1234567890bob1234567890bob1",
                account: nil,
                local: false,
                isAdmin: false,
                isSelf: false,
                npub: "npub1bob",
                displayName: "Bob"
            )
        ]
    )
}

private func directGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
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
        encryptedMedia: encryptedMediaComponent(),
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func messageGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: "group",
        endpoint: "",
        name: "Test Group",
        description: "",
        admins: [],
        relays: MarmotClient.seedRelays,
        nostrGroupIdHex: "",
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: encryptedMediaComponent(),
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func encryptedMediaComponent() -> AppGroupEncryptedMediaComponentFfi {
    AppGroupEncryptedMediaComponentFfi(
        componentId: 0,
        component: "",
        required: false,
        mediaFormat: "",
        allowedLocatorKinds: [],
        defaultBlobEndpoints: []
    )
}

private func emptyMarkdownDocument() -> MarkdownDocumentFfi {
    MarkdownDocumentFfi(blocks: [])
}

private func restoreDefault(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
