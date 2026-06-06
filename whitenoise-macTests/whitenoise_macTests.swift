//
//  whitenoise_macTests.swift
//  whitenoise-macTests
//
//  Created by Jeff Gardner on 26/05/2026.
//

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
        runtime.installMessages([
            appMessage(
                id: "parent",
                groupIdHex: "group",
                sender: "Alice",
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
        runtime.installMessages([
            appMessage(
                id: "parent",
                groupIdHex: "group",
                sender: "Alice",
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

        state.showSettings(.notifications)
        #expect(state.selection == .settings(.notifications))

        state.showSettings(.developerMode)
        #expect(state.selection == .settings(.developerMode))
    }

    @MainActor
    @Test func settingsSidebarPagesStartWithProfileAndExcludeOverview() async throws {
        #expect(SettingsPage.sidebarPages.first == .profile)
        #expect(!SettingsPage.sidebarPages.contains(.overview))
        #expect(SettingsPage.sidebarPages.last == .developerMode)
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

        #expect(state.keyPackages.map(\.eventIdHex) == ["event-local", "event-relay"])
        #expect(state.keyPackages.first?.sourceLabel == "Local")
        #expect(runtime.keyPackageBootstrapRelays == MarmotClient.seedRelays)
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
    @Test func deletingKeyPackageUsesSourceRelaysAndRefreshes() async throws {
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
        guard let relayPackage = state.keyPackages.last else {
            Issue.record("Expected a relay-discovered key package")
            return
        }
        await state.deleteKeyPackage(relayPackage)

        #expect(runtime.deletedKeyPackageEventId == "event-relay")
        #expect(runtime.deletedKeyPackageRelays == ["wss://relay-key.example"])
        #expect(!state.keyPackages.map(\.eventIdHex).contains("event-relay"))
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
        inbox: RelayListFfi(kind: 10050, relays: MarmotClient.seedRelays),
        keyPackage: RelayListFfi(kind: 30443, relays: MarmotClient.seedRelays)
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
            keyPackageId: "slot-relay",
            keyPackageRefHex: "ref-relay",
            eventIdHex: "event-relay",
            publishedAt: 1_700_000_100,
            keyPackageBytes: 520,
            sourceRelays: ["wss://relay-key.example"],
            local: false,
            relay: true
        )
    ]
    private var groups: [AppGroupRecordFfi] = []
    private var messagesByGroupId: [String: [AppMessageRecordFfi]] = [:]
    private var timelinePagesByGroupId: [String: TimelinePageFfi] = [:]
    private var timelineUpdatesByGroupId: [String: [TimelineSubscriptionUpdateFfi]] = [:]
    private(set) var createdGroupMemberRefs: [String] = []
    private(set) var createdGroupName: String?
    private(set) var createdGroupDescription: String?
    private(set) var repliedMessage: SentReply?
    private(set) var reactedMessage: SentReaction?
    private(set) var deletedMessage: DeletedMessage?
    private(set) var keyPackageBootstrapRelays: [String] = []
    private(set) var didPublishNewKeyPackage = false
    private(set) var didRepublishKeyPackage = false
    private(set) var deletedKeyPackageEventId: String?
    private(set) var deletedKeyPackageRelays: [String] = []
    private(set) var refreshedProfileIds: [String] = []
    private var profilesByAccountId: [String: UserProfileMetadataFfi] = [:]
    private var groupDetailsById: [String: GroupDetailsFfi] = [:]
    var notificationSettings = NotificationSettingsFfi(
        accountRef: "Desktop Account",
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        localNotificationsEnabled: false,
        nativePushEnabled: false
    )
    private(set) var localNotificationsEnabledSet: Bool?

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

    func installTimelineUpdates(_ updates: [TimelineSubscriptionUpdateFfi], groupIdHex: String) {
        timelineUpdatesByGroupId[groupIdHex] = updates
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
        keyPackageBootstrapRelays = bootstrapRelays
        return keyPackages
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        notificationSettings
    }

    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi {
        localNotificationsEnabledSet = enabled
        notificationSettings.localNotificationsEnabled = enabled
        return notificationSettings
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
        deletedKeyPackageEventId = eventIdHex
        deletedKeyPackageRelays = relays
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

    func setAccountKeyPackageRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        relayLists.keyPackage = RelayListFfi(kind: relayLists.keyPackage.kind, relays: relays)
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
        groups
            .filter { includeArchived || !$0.archived }
            .map { chatListRow(for: $0) }
    }

    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription {
        FakeChatListSubscription(rows: try chatList(accountRef: accountRef, includeArchived: includeArchived))
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
        groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
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

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.rows = []
        super.init(unsafeFromRawPointer: pointer)
    }

    init(rows: [ChatListRowFfi]) {
        self.rows = rows
        super.init(noPointer: NoPointer())
    }

    override func snapshot() -> [ChatListRowFfi] {
        rows
    }

    override func next() async -> ChatListRowFfi? {
        nil
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
