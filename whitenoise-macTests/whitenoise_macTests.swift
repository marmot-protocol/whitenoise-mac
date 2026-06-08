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
    @Test func projectedChatRowTimestampUsesLastMessageTime() async throws {
        let lastMessageAt: UInt64 = 1_700_000_000
        let projectionRefreshedAt: UInt64 = 1_800_000_000
        let row = ChatListRowFfi(
            groupIdHex: "direct-group",
            archived: false,
            pendingConfirmation: false,
            title: "Alice",
            groupName: "",
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "A prior message",
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
            MessageReaction(emoji: "👍", count: 1, isOwn: true)
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
    @Test func timelineProjectionChangesUpdateVisibleMessagesAndChatPreview() async throws {
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
                    chatListRow: chatListRow(
                        groupIdHex: "direct-group",
                        title: "Alice",
                        preview: "Streaming…",
                        sender: account.accountIdHex,
                        timelineAt: 1_700_000_010
                    ),
                    chatListTrigger: .newLastMessage
                )
            ))
        ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.map(\.id) == ["stream"]
        }

        #expect(didApplyProjection)
        #expect(state.messagesByChat["direct-group"]?.first?.body == "Streaming…")
        #expect(state.activeChats.first?.preview == "Streaming…")
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
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.first(where: { $0.id == "older" })?.body == "Earlier message edited by projection"
        }

        #expect(didApplyProjection)
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
        #expect(runtime.chatListCallCount == 0)
        #expect(runtime.chatListSubscriptionCount == 1)
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

        #expect(state.activeChats.first?.title == "Alice Actual")
        #expect(state.activeChats.first?.subtitle == "Direct message")
        #expect(state.activeChats.first?.avatarSeed == "alice1234567890alice1234567890alice1234567890alice1234567890")
        #expect(state.activeChats.first?.pictureURL == "https://example.com/alice.png")
        #expect(runtime.refreshedProfileIds == ["alice1234567890alice1234567890alice1234567890alice1234567890"])
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
    @Test func defaultRelaysUseWhiteNoiseEuAndUsOnly() async throws {
        let defaults = [
            "wss://relay.eu.whitenoise.chat",
            "wss://relay.us.whitenoise.chat"
        ]

        #expect(MarmotClient.seedRelays == defaults)
        #expect(RelaySettingsSnapshot.defaults.nip65 == defaults)
        #expect(RelaySettingsSnapshot.defaults.inbox == defaults)
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
    @Test func settingsLoadShowsPublishedKeyPackages() async throws {
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

        #expect(state.keyPackages.map(\.eventIdHex) == ["event-local", "event-fetched"])
        #expect(state.keyPackages.first?.sourceLabel == "Local")
        #expect(runtime.lastPackageFetchBootstrapRelays == MarmotClient.seedRelays)
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
        #expect(!state.notificationSettings.nativePushEnabled)
        #expect(state.notificationAuthorizationStatus == .authorized)
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
        let state = WorkspaceState(
            observabilityTokenProvider: { "test-token" },
            clientFactory: { runtime }
        )

        await state.bootstrap()

        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.privacySecuritySettings.relayTelemetryIntervalSeconds == 120)
        #expect(!state.privacySecuritySettings.auditLogUploadsEnabled)
        #expect(state.privacySecuritySettings.hasObservabilityToken)
        #expect(runtime.relayTelemetryRuntimeConfig?.authorizationBearerToken == "test-token")
        let telemetryResource = runtime.relayTelemetryRuntimeConfig?.resource
        #expect(telemetryResource?.serviceVersion == expectedTelemetryServiceVersion())
        #expect(telemetryResource?.serviceInstanceId == "test-install-id")
        #expect(telemetryResource?.deploymentEnvironment == "production")
        #expect(telemetryResource?.tenant == "whitenoise-mac")
        #expect(telemetryResource?.osType == "darwin")
        #expect(telemetryResource?.osVersion == ProcessInfo.processInfo.operatingSystemVersionString)
        #expect(telemetryResource?.deviceModelIdentifier == expectedDeviceModelIdentifier())
        #expect(runtime.auditLogTrackerConfig?.authorizationBearerToken == "test-token")
        #expect(runtime.auditLogTrackerConfig?.source.accountLabel == "Desktop Account")

        await state.setRelayTelemetryEnabled(false)
        await state.setAuditLogUploadsEnabled(true)

        #expect(!runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(runtime.storedRelayTelemetrySettings.exportIntervalSeconds == 120)
        #expect(runtime.storedAuditLogSettings.enabled)
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.privacySecuritySettings.auditLogUploadsEnabled)
    }

    @MainActor
    @Test func enablingPrivacySecurityUploadRequiresBuildToken() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(
            observabilityTokenProvider: { nil },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setRelayTelemetryEnabled(true)
        await state.setAuditLogUploadsEnabled(true)

        #expect(!runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(!runtime.storedAuditLogSettings.enabled)
        #expect(state.lastError == "Missing OTLP_TOKEN_DARKMATTER_MAC build setting.")
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
    @Test func deletingKeyPackageFallsBackToNip65RelaysAndRefreshes() async throws {
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
        guard let fetchedPackage = state.keyPackages.last else {
            Issue.record("Expected a fetched key package")
            return
        }
        await state.deleteKeyPackage(fetchedPackage)

        #expect(runtime.deletedPackageEventId == "event-fetched")
        #expect(runtime.lastPackageDeleteRelays == MarmotClient.seedRelays)
        #expect(!state.keyPackages.map(\.eventIdHex).contains("event-fetched"))
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

@MainActor
private final class FakeMarmotRuntime: MarmotRuntime {
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
    private(set) var lastPackageFetchBootstrapRelays: [String] = []
    private(set) var didPublishNewKeyPackage = false
    private(set) var didRepublishKeyPackage = false
    private(set) var deletedPackageEventId: String?
    private(set) var lastPackageDeleteRelays: [String] = []
    private(set) var refreshedProfileIds: [String] = []
    private(set) var markedReadMessageIds: [String] = []
    private(set) var chatListCallCount = 0
    private(set) var chatListSubscriptionCount = 0
    private(set) var timelineSubscriptionCount = 0
    private var profilesByAccountId: [String: UserProfileMetadataFfi] = [:]
    private var groupDetailsById: [String: GroupDetailsFfi] = [:]
    var notificationSettings = NotificationSettingsFfi(
        accountRef: "Desktop Account",
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        localNotificationsEnabled: false,
        nativePushEnabled: false
    )
    var storedAuditLogSettings = AuditLogSettingsFfi(enabled: false)
    var storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
        exportEnabled: false,
        exportIntervalSeconds: 60
    )
    private(set) var localNotificationsEnabledSet: Bool?
    private(set) var auditLogTrackerConfig: AuditLogTrackerConfigFfi?
    private(set) var relayTelemetryRuntimeConfig: RelayTelemetryRuntimeConfigFfi?

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
        let resolvedProfile = profilesByAccountId[accountIdHex] ?? profile
        return resolvedProfile.displayName ?? resolvedProfile.name
    }

    func userProfile(accountIdHex: String) throws -> UserProfileMetadataFfi? {
        profilesByAccountId[accountIdHex] ?? profile
    }

    func normalizeMemberRef(memberRef: String) throws -> MemberRefFfi {
        MemberRefFfi(
            memberRef: memberRef,
            accountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            npub: "npub1alice"
        )
    }

    func refreshProfile(accountIdHex: String, relays: [String]) async throws {
        refreshedProfileIds.append(accountIdHex)
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
        groupDetailsById[group.groupIdHex] = GroupDetailsFfi(
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
    }

    func installMessages(_ messages: [AppMessageRecordFfi], groupIdHex: String) {
        messagesByGroupId[groupIdHex] = messages
        timelinePagesByGroupId[groupIdHex] = projectedTimeline(from: messages)
    }

    func installGroup(_ group: AppGroupRecordFfi) {
        groups = [group]
        groupDetailsById[group.groupIdHex] = GroupDetailsFfi(group: group, members: [])
    }

    func installGroups(_ groups: [AppGroupRecordFfi]) {
        self.groups = groups
        for group in groups {
            groupDetailsById[group.groupIdHex] = GroupDetailsFfi(group: group, members: [])
        }
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
        self.profile = profile
        return profile
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        relayLists
    }

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        lastPackageFetchBootstrapRelays = bootstrapRelays
        return keyPackages
    }

    func auditLogSettings() throws -> AuditLogSettingsFfi {
        storedAuditLogSettings
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        notificationSettings
    }

    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi {
        storedRelayTelemetrySettings
    }

    func setAuditLogSettings(settings: AuditLogSettingsFfi) throws -> AuditLogSettingsFfi {
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
                archived: false,
                pendingConfirmation: false,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            )
        ]
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

    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        relayLists.inbox = RelayListFfi(kind: relayLists.inbox.kind, relays: relays)
        return relayLists
    }

    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        relayLists.nip65 = RelayListFfi(kind: relayLists.nip65.kind, relays: relays)
        return relayLists
    }

    func subscribeChats(accountRef: String, includeArchived: Bool) async throws -> ChatsSubscription {
        FakeChatsSubscription(groups: groups)
    }

    func chatList(accountRef: String, includeArchived: Bool) throws -> [ChatListRowFfi] {
        chatListCallCount += 1
        return chatListRows(includeArchived: includeArchived)
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

    func subscribeNotifications() async throws -> NotificationsSubscription {
        FakeNotificationsSubscription()
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        if let groupIdHex = query.groupIdHex {
            return timelinePagesByGroupId[groupIdHex] ?? emptyTimelinePage()
        }

        let messages = timelinePagesByGroupId.values.flatMap(\.messages).sorted { lhs, rhs in
            if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
            return lhs.messageIdHex < rhs.messageIdHex
        }
        return TimelinePageFfi(messages: messages, hasMoreBefore: false, hasMoreAfter: false)
    }

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws -> TimelineMessagesSubscription {
        timelineSubscriptionCount += 1
        let page = try timelineMessages(
            accountRef: accountRef,
            query: TimelineMessageQueryFfi(
                groupIdHex: groupIdHex,
                search: nil,
                before: nil,
                beforeMessageId: nil,
                after: nil,
                afterMessageId: nil,
                limit: limit
            )
        )
        return FakeTimelineMessagesSubscription(
            page: page,
            updates: groupIdHex.flatMap { timelineUpdatesByGroupId[$0] } ?? []
        )
    }

    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi? {
        groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi? {
        markedReadMessageIds.append(messageIdHex)
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func messages(accountRef: String, groupIdHex: String?, limit: UInt32?) throws -> [AppMessageRecordFfi] {
        if let groupIdHex {
            return messagesByGroupId[groupIdHex] ?? []
        }
        return messagesByGroupId.values.flatMap { $0 }
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
            avatar: nil,
            lastMessage: latest.map { message in
                ChatListMessagePreviewFfi(
                    messageIdHex: message.messageIdHex,
                    sender: message.sender,
                    senderDisplayName: displayName(accountIdHex: message.sender),
                    plaintext: message.plaintext,
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

private final class FakeChatsSubscription: ChatsSubscription {
    private let groups: [AppGroupRecordFfi]

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.groups = []
        super.init(unsafeFromRawPointer: pointer)
    }

    init(groups: [AppGroupRecordFfi]) {
        self.groups = groups
        super.init(noPointer: NoPointer())
    }

    override func snapshot() -> [AppGroupRecordFfi] {
        groups
    }

    override func next() async -> AppGroupRecordFfi? {
        nil
    }
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

private final class FakeTimelineMessagesSubscription: TimelineMessagesSubscription {
    private let page: TimelinePageFfi
    private var updates: [TimelineSubscriptionUpdateFfi]

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.page = emptyTimelinePage()
        self.updates = []
        super.init(unsafeFromRawPointer: pointer)
    }

    init(page: TimelinePageFfi, updates: [TimelineSubscriptionUpdateFfi] = []) {
        self.page = page
        self.updates = updates
        super.init(noPointer: NoPointer())
    }

    override func snapshot() -> TimelinePageFfi? {
        page
    }

    override func next() async -> TimelinePageFfi? {
        nil
    }

    override func nextUpdate() async -> TimelineSubscriptionUpdateFfi? {
        guard !updates.isEmpty else { return nil }
        return updates.removeFirst()
    }
}

@MainActor
private final class FakeLocalNotificationCenter: LocalNotificationCenter {
    private(set) var status: LocalNotificationAuthorizationStatus
    private let requestedStatus: LocalNotificationAuthorizationStatus
    private let requestError: Error?
    private(set) var didRequestAuthorization = false
    private(set) var postedRequests: [LocalNotificationRequest] = []
    private var responseHandler: (@MainActor ([String: String]) -> Void)?

    init(
        status: LocalNotificationAuthorizationStatus = .authorized,
        requestedStatus: LocalNotificationAuthorizationStatus = .authorized,
        requestError: Error? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
        self.requestError = requestError
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
            deletedByMessageIdHex: nil
        )
    }
    .sorted { lhs, rhs in
        if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
        return lhs.messageIdHex < rhs.messageIdHex
    }

    return TimelinePageFfi(messages: timelineMessages, hasMoreBefore: false, hasMoreAfter: false)
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
        deletedByMessageIdHex: nil
    )
}

private func chatListRow(
    groupIdHex: String,
    title: String,
    preview: String,
    sender: String,
    timelineAt: UInt64
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: groupIdHex,
        archived: false,
        pendingConfirmation: false,
        title: title,
        groupName: "",
        avatar: nil,
        lastMessage: ChatListMessagePreviewFfi(
            messageIdHex: "preview",
            sender: sender,
            senderDisplayName: nil,
            plaintext: preview,
            kind: 9,
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
    localEnabled: Bool,
    nativeEnabled: Bool = false
) -> NotificationSettingsFfi {
    NotificationSettingsFfi(
        accountRef: account.label,
        accountIdHex: account.accountIdHex,
        localNotificationsEnabled: localEnabled,
        nativePushEnabled: nativeEnabled
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

private func directGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: "direct-group",
        endpoint: "",
        name: "",
        description: "",
        admins: [],
        relays: ["wss://relay.example"],
        nostrGroupIdHex: "",
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
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}
