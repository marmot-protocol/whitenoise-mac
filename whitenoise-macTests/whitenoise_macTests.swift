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
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: created)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.signUp()

        #expect(state.phase == .ready)
        #expect(state.showsMessengerChrome)
        #expect(state.accounts.map(\.displayName) == ["Desktop Account"])
        #expect(state.accounts.first?.pictureURL == "https://example.com/avatar.png")
        #expect(state.accounts.first?.isRunning == true)
        #expect(state.activeAccountId == "Desktop Account")
        #expect(runtime.didStart)
        #expect(runtime.startCallCount == 1)
    }

    @MainActor
    @Test func loginStartsRuntimeAndEntersMessengerShell() async throws {
        let loggedIn = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: loggedIn)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1desktop"
        await state.login()

        #expect(state.phase == .ready)
        #expect(state.showsMessengerChrome)
        #expect(state.accounts.map(\.displayName) == ["Desktop Account"])
        #expect(state.accounts.first?.isRunning == true)
        #expect(state.activeAccountId == "Desktop Account")
        #expect(runtime.didStart)
        #expect(runtime.startCallCount == 1)
    }

    @MainActor
    @Test func bootstrapRunsSynchronousRuntimeReadsOffMainThread() async throws {
        // Regression for #17: WorkspaceState is @MainActor, but blocking sync FFI reads
        // (account listing/profile/name/npub plus settings probes) must not execute on
        // the main thread during launch.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        runtime.clearSyncCallThreadRecords()
        await state.bootstrap()

        #expect(state.phase == .ready)
        #expect(runtime.syncCallThreadRecord("listAccounts").count >= 2)
        #expect(runtime.syncCallThreadRecord("listAccounts").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("userProfile").contains(false))
        #expect(runtime.syncCallThreadRecord("userProfile").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("displayName").contains(false))
        #expect(runtime.syncCallThreadRecord("displayName").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("npub").contains(false))
        #expect(runtime.syncCallThreadRecord("npub").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("notificationSettings").contains(false))
        #expect(runtime.syncCallThreadRecord("notificationSettings").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("telemetryInstallId").contains(false))
        #expect(runtime.syncCallThreadRecord("telemetryInstallId").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("setAuditLogTrackerConfig").contains(false))
        #expect(runtime.syncCallThreadRecord("setAuditLogTrackerConfig").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("relayTelemetrySettings").contains(false))
        #expect(runtime.syncCallThreadRecord("relayTelemetrySettings").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("auditLogSettings").contains(false))
        #expect(runtime.syncCallThreadRecord("auditLogSettings").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("auditLogFiles").contains(false))
        #expect(runtime.syncCallThreadRecord("auditLogFiles").allSatisfy { !$0 })
    }

    @MainActor
    @Test func loadSettingsDataRunsSynchronousRuntimeReadsOffMainThread() async throws {
        // The Settings screen pulls profile, relay, notification, telemetry, and audit
        // snapshots. Those are synchronous FFI reads and must not block the run loop.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        runtime.clearSyncCallThreadRecords()
        await state.loadSettingsData()

        #expect(runtime.syncCallThreadRecord("userProfile").contains(false))
        #expect(runtime.syncCallThreadRecord("userProfile").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("accountRelayLists").contains(false))
        #expect(runtime.syncCallThreadRecord("accountRelayLists").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("notificationSettings").contains(false))
        #expect(runtime.syncCallThreadRecord("notificationSettings").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("telemetryInstallId").contains(false))
        #expect(runtime.syncCallThreadRecord("telemetryInstallId").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("setAuditLogTrackerConfig").contains(false))
        #expect(runtime.syncCallThreadRecord("setAuditLogTrackerConfig").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("relayTelemetrySettings").contains(false))
        #expect(runtime.syncCallThreadRecord("relayTelemetrySettings").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("auditLogSettings").contains(false))
        #expect(runtime.syncCallThreadRecord("auditLogSettings").allSatisfy { !$0 })
        #expect(runtime.syncCallThreadRecord("auditLogFiles").contains(false))
        #expect(runtime.syncCallThreadRecord("auditLogFiles").allSatisfy { !$0 })
    }

    @MainActor
    @Test func addingSecondAccountViaLoginBringsItOnlineWithoutRelaunch() async throws {
        // Regression for #74: the Settings → Add Account flow reuses login()/
        // signUp() while the runtime is already running. The new account must be
        // brought online immediately (its worker started, transport subscribed)
        // rather than staying offline until the next app launch.
        let primary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        let state = WorkspaceState(clientFactory: { runtime })

        // First launch brings the runtime online once for the existing account.
        await state.bootstrap()
        #expect(state.phase == .ready)
        #expect(runtime.startCallCount == 1)
        #expect(state.accounts.map(\.isRunning) == [true])

        // Add a second account via the Settings → Add Account login path.
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            running: false
        )
        runtime.createdAccount = secondary
        state.showLogin()
        state.loginIdentity = "nsec1backup"
        await state.login()

        // The runtime must have been brought online again so the newly added
        // account's worker/transport sync starts now — not after a relaunch.
        #expect(runtime.startCallCount == 2)
        #expect(state.accounts.count == 2)
        let backup = try #require(state.accounts.first { $0.accountIdHex == secondary.accountIdHex })
        #expect(backup.isRunning == true)
        #expect(state.accounts.allSatisfy(\.isRunning))
        #expect(state.activeAccountId == "Backup Account")
    }

    @MainActor
    @Test func addingSecondAccountViaSignUpBringsItOnlineWithoutRelaunch() async throws {
        // Companion to the login case above: the Create Identity button in
        // Settings → Add Account must also bring the new account online. See #74.
        let primary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(runtime.startCallCount == 1)

        let secondary = AccountSummaryFfi(
            label: "Second Identity",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            running: false
        )
        runtime.createdAccount = secondary
        await state.signUp()

        #expect(runtime.startCallCount == 2)
        #expect(state.accounts.count == 2)
        let added = try #require(state.accounts.first { $0.accountIdHex == secondary.accountIdHex })
        #expect(added.isRunning == true)
        #expect(state.accounts.allSatisfy(\.isRunning))
    }

    @MainActor
    @Test func failedLoginScrubsEnteredNsecFromMemory() async throws {
        // No createdAccount => FakeMarmotRuntime.login throws, exercising the failure path.
        let runtime = FakeMarmotRuntime(accounts: [])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1faketestkeyfaketestkeyfaketestkeyfaketestkeyfaketest"

        await state.login()

        // Login failed (no account materialised) but the private key must not linger.
        #expect(state.loginIdentity == "")
        #expect(state.accounts.isEmpty)
        #expect(state.lastError != nil)
    }

    @MainActor
    @Test func successfulLoginScrubsEnteredNsecFromMemory() async throws {
        let summary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: summary)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1faketestkeyfaketestkeyfaketestkeyfaketestkeyfaketest"

        await state.login()

        #expect(state.phase == .ready)
        #expect(state.loginIdentity == "")
    }

    @MainActor
    @Test func navigatingAwayFromAddAccountScrubsEnteredNsec() async throws {
        let summary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [summary])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        // Simulate a typed-but-unsubmitted key in the Add Account field.
        state.loginIdentity = "nsec1faketestkeyfaketestkeyfaketestkeyfaketestkeyfaketest"

        state.showSettings(.accounts)
        #expect(state.loginIdentity == "")

        // And again when leaving for a chat.
        state.loginIdentity = "nsec1anotherfakekeyanotherfakekeyanotherfakekeyanotherfake"
        if let chat = state.activeChats.first {
            state.selectChat(chat)
            #expect(state.loginIdentity == "")
        }
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
    @Test func removeNonActiveAccountLeavesActiveSessionUntouched() async throws {
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
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        await state.removeAccount(backupAccount)

        #expect(runtime.removedAccountRefs == ["Backup Account"])
        #expect(state.accounts.map(\.id) == ["Desktop Account"])
        // Removing a background identity must not switch the active account.
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.chatsByAccount["Backup Account"] == nil)
    }

    @MainActor
    @Test func removingBackgroundAccountSelectedMidFlightRecoversActiveAccount() async throws {
        // Regression for the account-switch/remove race: if the user selects the
        // background account that is currently being removed while removal is in flight,
        // `activeAccountId` transiently points at the soon-to-be-removed id. The pre-await
        // `wasActive` snapshot is false, so naive code would skip recovery and leave
        // `activeAccountId`/UserDefaults dangling at a deleted account. Removal must
        // recompute against post-await state and reselect a surviving account.
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
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })

        // Simulate the racing UI selection of the account being removed, mid-await.
        runtime.onRemoveAccountMidFlight = { _ in
            await MainActor.run {
                state.selectAccountFromSettings(backupAccount)
            }
        }

        await state.removeAccount(backupAccount)

        #expect(runtime.removedAccountRefs == ["Backup Account"])
        #expect(state.accounts.map(\.id) == ["Desktop Account"])
        // The active account must never point at the removed identity; recovery must
        // reselect the surviving account.
        #expect(state.activeAccountId == "Desktop Account")
        #expect(UserDefaults.standard.string(forKey: "whitenoise.mac.activeAccountId") == "Desktop Account")
        #expect(state.chatsByAccount["Backup Account"] == nil)
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

    @Test func marmotStorageRootRejectsUnavailableApplicationSupportDirectory() throws {
        let underlying = NSError(
            domain: "MarmotStorageRootTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "blocked Application Support"]
        )

        do {
            _ = try MarmotStorageRoot.resolve(applicationSupportDirectory: { _ in throw underlying })
            Issue.record("Expected storage root resolution to fail")
        } catch let error as MarmotStorageRootError {
            let message = error.localizedDescription
            #expect(message.contains("Unable to resolve a durable Application Support directory"))
            #expect(message.contains("blocked Application Support"))
            #expect(!message.contains(NSTemporaryDirectory()))
        } catch {
            Issue.record("Expected MarmotStorageRootError, got \(error)")
        }
    }

    @MainActor
    @Test func bootstrapSurfacesStorageRootResolutionFailures() async throws {
        let underlying = NSError(
            domain: "MarmotStorageRootTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "blocked Application Support"]
        )
        let state = WorkspaceState(clientFactory: {
            throw MarmotStorageRootError.applicationSupportUnavailable(underlying)
        })

        await state.bootstrap()

        guard case .failed(let message) = state.phase else {
            Issue.record("Expected bootstrap to fail when storage root resolution fails")
            return
        }
        #expect(message.contains("Unable to resolve a durable Application Support directory"))
        #expect(state.lastError == message)
        #expect(!state.showsMessengerChrome)
    }

    @Test func marmotStorageRootPropagatesDirectoryCreationFailures() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-storage-root-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let blockedParent = sandbox.appendingPathComponent("White Noise", isDirectory: false)
        try Data().write(to: blockedParent)

        let expectedRoot = sandbox
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Marmot", isDirectory: true)
            .path

        do {
            _ = try MarmotStorageRoot.resolve(baseURL: sandbox, fileManager: fileManager)
            Issue.record("Expected storage root creation to fail")
        } catch let error as MarmotStorageRootError {
            let message = error.localizedDescription
            #expect(message.contains("Unable to create durable Marmot storage directory"))
            #expect(message.contains(expectedRoot))
        } catch {
            Issue.record("Expected MarmotStorageRootError, got \(error)")
        }

        #expect(!fileManager.fileExists(atPath: expectedRoot))
    }

    @Test func marmotStorageRootRejectsFileAtExpectedRoot() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-storage-root-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let whiteNoiseDirectory = sandbox.appendingPathComponent("White Noise", isDirectory: true)
        try fileManager.createDirectory(at: whiteNoiseDirectory, withIntermediateDirectories: true)

        let marmotRoot = whiteNoiseDirectory.appendingPathComponent("Marmot", isDirectory: false)
        try Data().write(to: marmotRoot)

        do {
            _ = try MarmotStorageRoot.resolve(baseURL: sandbox, fileManager: fileManager)
            Issue.record("Expected storage root resolution to reject a file at the Marmot root")
        } catch let error as MarmotStorageRootError {
            guard case .rootIsNotDirectory(let path) = error else {
                Issue.record("Expected rootIsNotDirectory, got \(error)")
                return
            }
            #expect(path == marmotRoot.path)
        } catch {
            Issue.record("Expected MarmotStorageRootError, got \(error)")
        }
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
        AppLanguage.refreshCachedLocale()

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
        AppLanguage.refreshCachedLocale()

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
    @Test func messageActionEligibilityTracksOwnershipAndState() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let outgoing = MessageItem(
            id: "outgoing",
            senderName: "Jeff",
            body: "Ship it",
            sentAt: sentAt,
            isOutgoing: true
        )
        let incoming = MessageItem(
            id: "incoming",
            senderName: "Alice",
            body: "Looks good",
            sentAt: sentAt,
            isOutgoing: false
        )
        let deleted = MessageItem(
            id: "deleted",
            senderName: "Jeff",
            body: "Message deleted",
            sentAt: sentAt,
            isDeleted: true,
            isOutgoing: true
        )
        let failed = MessageItem(
            id: "failed",
            senderName: "Jeff",
            body: "Message did not reach the group",
            sentAt: sentAt,
            invalidationStatus: "signature-check-failed",
            isOutgoing: true
        )
        let systemNotice = MessageItem(
            id: "system",
            senderName: "System",
            body: "Member added",
            sentAt: sentAt,
            isOutgoing: false,
            presentation: .groupSystem
        )

        #expect(outgoing.supportsChatActions)
        #expect(outgoing.canCopyText)
        #expect(outgoing.canReact)
        #expect(outgoing.canReply)
        #expect(outgoing.canDelete)

        #expect(incoming.supportsChatActions)
        #expect(incoming.canCopyText)
        #expect(incoming.canReact)
        #expect(incoming.canReply)
        #expect(!incoming.canDelete)

        for message in [deleted, failed] {
            #expect(!message.supportsChatActions)
            #expect(!message.canCopyText)
            #expect(!message.canReact)
            #expect(!message.canReply)
            #expect(!message.canDelete)
        }

        #expect(!systemNotice.supportsChatActions)
        #expect(systemNotice.canCopyText)
        #expect(!systemNotice.canReact)
        #expect(!systemNotice.canReply)
        #expect(!systemNotice.canDelete)
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
    @Test func timelineMappingPreservesRuntimeWindowOrder() async throws {
        // Regression for #7: the runtime page already carries the authoritative
        // timeline order, including any hidden same-second tie-break from storage.
        // The client mapper must not re-sort the page by second-granular
        // `timelineAt`, or subscription refreshes can reshuffle colliding rows.
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "runtime-third",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "storage order 3",
                    recordedAt: 1_700_000_001
                ),
                timelineMessage(
                    id: "runtime-first",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "storage order 1",
                    recordedAt: 1_700_000_000
                ),
                timelineMessage(
                    id: "runtime-second",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "storage order 2",
                    recordedAt: 1_700_000_000
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: "self"
        )

        #expect(messages.map(\.id) == [
            "runtime-third",
            "runtime-first",
            "runtime-second"
        ])
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
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

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
    @Test func selectedChatDoesNotMarkReadWhileConversationWindowIsHidden() async throws {
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
        // The app process can stay active while its only window is minimized or has no
        // key window; a selected chat is still not visible in that state.
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { false },
            clientFactory: { runtime }
        )

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
        let state = WorkspaceState(
            appActivityProvider: { isActive },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(runtime.markedReadMessageIds.isEmpty)

        isActive = true
        await state.handleConversationVisibilityChange()

        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func restoringConversationWindowFlushesDeferredReadMarking() async throws {
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
        var isWindowVisible = false
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { isWindowVisible },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(runtime.markedReadMessageIds.isEmpty)

        isWindowVisible = true
        await state.handleConversationVisibilityChange()

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
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

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
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

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
    @Test func incompletePeerProfileLookupIsNotPinnedForTheSession() async throws {
        // Regression for #8: an incomplete first sender-profile lookup (relay has not
        // propagated the profile yet, or the lookup failed) must not be cached as a
        // terminal answer. A later pass that has the data available must re-resolve and
        // pick up the real name instead of leaving the contact pinned to its hex fallback.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        // Blank group-member display name so the only name source is the profile lookup,
        // and mark alice's profile as not-yet-available for the first pass.
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "",
            otherProfile: UserProfileMetadataFfi(
                name: nil,
                displayName: nil,
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.accountIdsMissingProfiles.insert(aliceId)
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<150).map { index in
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

        let firstPass = state.messagesByChat["direct-group"] ?? []
        let firstAliceName = firstPass.first?.senderName
        // The relay had not propagated the profile, so the contact falls back to a
        // shortened hex id rather than a real display name.
        #expect(firstAliceName != "Alice Cooper")
        #expect(firstAliceName == DisplayText.short(aliceId))

        // The profile becomes available; a subsequent render must re-resolve it.
        runtime.accountIdsMissingProfiles.remove(aliceId)
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        await state.loadOlderMessages(groupIdHex: "direct-group")

        let secondPass = state.messagesByChat["direct-group"] ?? []
        #expect(secondPass.first?.senderName == "Alice Cooper")
    }

    @MainActor
    @Test func completePeerProfileIsRefreshedAfterCacheTTLExpires() async throws {
        // Regression for #8: a complete sender-profile lookup is cached, but the cache is
        // not a permanent "seen" flag. Once the TTL elapses the profile is re-resolved so
        // a contact's later display-name change is picked up within the same session.
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
            otherDisplayName: "",
            otherProfile: UserProfileMetadataFfi(
                name: nil,
                displayName: nil,
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<350).map { index in
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
        // Drive the cache clock from the test so TTL expiry is deterministic.
        let clock = MutableClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let state = WorkspaceState(nowProvider: { clock.now }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")

        // Alice renames herself. A render inside the TTL keeps the cached name.
        runtime.installProfile(
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
        clock.now = clock.now.addingTimeInterval(60)
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")

        // Once the TTL elapses, the next render re-resolves and reflects the new name.
        clock.now = clock.now.addingTimeInterval(600)
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice Renamed")
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
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
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
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
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
    @Test func sendDraftDropsOverlappingDuplicateInvocation() async throws {
        // Issue #78: sendDraft() must guard against reentrancy. `isSending` flips synchronously,
        // but the model only suspends (and draftText is only cleared) at the `await sendText(...)`.
        // A second invocation delivered before SwiftUI re-renders the disabled send button
        // (⌘-Return auto-repeat, double events) would otherwise observe the still-unchanged
        // draftText and re-send the same message. Repro: hold the first send in-flight at the
        // FFI gate, fire an overlapping second send, then release. Only one text must be sent.
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
        state.draftText = "only once"

        // Arm the gate so the first send suspends inside sendText(); start it concurrently.
        runtime.messageActionGateEnabled = true
        async let firstSend: Void = state.sendDraft()

        // Spin the main actor until the first send is in-flight (isSending set, FFI reached).
        while !(state.isSending && runtime.didReachMessageActionGate) {
            await Task.yield()
        }

        // Overlapping second invocation: it must hit the `!isSending` guard and return immediately.
        await state.sendDraft()
        #expect(runtime.sendTextCallCount == 1)

        // Release the gate and let the first send finish.
        runtime.releaseMessageActionGate()
        await firstSend

        #expect(runtime.sendTextCallCount == 1)
        #expect(runtime.sentText == SentText(groupIdHex: "direct-group", text: "only once"))
        #expect(state.draftText.isEmpty)
        #expect(state.isSending == false)
    }

    @MainActor
    @Test func reactDropsOverlappingDuplicateButAllowsDifferentEmoji() async throws {
        // Issue #78: react(to:emoji:) must drop a duplicate of the *same* in-flight reaction
        // (same target + emoji) while still allowing a different emoji on the same message.
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
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
        )

        await state.bootstrap()

        // Hold the first react in-flight at the FFI gate.
        runtime.messageActionGateEnabled = true
        async let firstReact: Void = state.react(to: message, emoji: "👍")
        while !runtime.didReachMessageActionGate {
            await Task.yield()
        }

        // Duplicate same-emoji react is dropped by the per-target guard.
        await state.react(to: message, emoji: "👍")
        #expect(runtime.reactToMessageCallCount == 1)

        // A different emoji on the same message is a legitimate, distinct action and is allowed.
        await state.react(to: message, emoji: "🎉")
        #expect(runtime.reactToMessageCallCount == 2)

        runtime.releaseMessageActionGate()
        await firstReact

        #expect(runtime.reactToMessageCallCount == 2)
    }

    @MainActor
    @Test func deleteMessageDropsOverlappingDuplicateInvocation() async throws {
        // Issue #78: deleteMessage(_:) must drop a repeated delete of the same in-flight message.
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
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
        )

        await state.bootstrap()

        runtime.messageActionGateEnabled = true
        async let firstDelete: Void = state.deleteMessage(message)
        while !runtime.didReachMessageActionGate {
            await Task.yield()
        }

        // Overlapping repeated delete of the same message is dropped by the per-target guard.
        await state.deleteMessage(message)
        #expect(runtime.deleteMessageCallCount == 1)

        runtime.releaseMessageActionGate()
        await firstDelete

        #expect(runtime.deleteMessageCallCount == 1)
    }

    @MainActor
    @Test func incomingMessageDeleteActionDoesNotPublishDeletion() async throws {
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
            id: "incoming-parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )

        await state.bootstrap()
        await state.deleteMessage(message)

        #expect(runtime.deletedMessage == nil)
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
        var copiedConcealed = false
        let state = WorkspaceState(copyTextHandler: { copiedText = $0; copiedConcealed = $1 })

        state.copyText(of: MessageItem(
            id: "message",
            senderName: "Alice",
            body: "Copy this",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        ))

        #expect(copiedText == "Copy this")
        // Decrypted message bodies are private content and must be marked concealed so
        // clipboard managers / Universal Clipboard treat them as transient.
        #expect(copiedConcealed)
    }

    @MainActor
    @Test func copyingTextDefaultsToConcealed() async throws {
        var copiedConcealed = false
        let state = WorkspaceState(copyTextHandler: { _, concealed in copiedConcealed = concealed })

        state.copyText("anything-copied-from-this-app")

        #expect(copiedConcealed)
    }

    @MainActor
    @Test func deletedAndFailedMessageTextDoesNotCopyPlaceholder() async throws {
        var copiedText = "initial"
        let state = WorkspaceState(copyTextHandler: { text, _ in copiedText = text })
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)

        state.copyText(of: MessageItem(
            id: "deleted",
            senderName: "Alice",
            body: "Message deleted",
            sentAt: sentAt,
            isDeleted: true,
            isOutgoing: false
        ))
        state.copyText(of: MessageItem(
            id: "failed",
            senderName: "Alice",
            body: "Message did not reach the group",
            sentAt: sentAt,
            invalidationStatus: "signature-check-failed",
            isOutgoing: true
        ))

        #expect(copiedText == "initial")
    }

    @MainActor
    @Test func copyingPlainSettingsTextUsesConfiguredClipboardWriter() async throws {
        var copiedText = ""
        let state = WorkspaceState(copyTextHandler: { text, _ in copiedText = text })

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
    @Test func incrementalChatRowUpdateEnrichesDirectChatTitle() async throws {
        // Regression for #40: single-row chat-list deltas go through the incremental
        // enrichment path (startChatListEnrichment(replacingCurrent: false)). After the fix
        // these tasks are tracked and coalesced per group, but the happy path must still
        // enrich the row — verify a `.row` delta for a direct chat resolves the peer profile.
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
        let didEnrichIncrementally = await waitFor {
            state.activeChats.first?.title == "Alice Actual"
                && state.activeChats.first?.preview == "See you soon."
        }

        #expect(didEnrichIncrementally)
        #expect(state.activeChats.first?.isDirect == true)
        #expect(state.activeChats.first?.pictureURL == "https://example.com/alice.png")
        // The incremental row reuses the initial membership lookup for non-membership triggers;
        // it must not re-query group details just to refresh the last-message preview (#9).
        #expect((runtime.groupDetailsCallCounts["direct-group"] ?? 0) == 1)
    }

    @MainActor
    @Test func timelineSenderProfilesReusePrimedGroupMemberDetails() async throws {
        // Regression for #9: loading/reprojecting a timeline should not hit `groupDetails`
        // again after chat-list enrichment has already cached the group's members. The
        // timeline only needs member display names as sender-name fallbacks.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didPrimeMemberCache = await waitFor {
            (runtime.groupDetailsCallCounts["group"] ?? 0) >= 1
                && !state.selectedTimelineIsLoadingInitialPage
        }
        #expect(didPrimeMemberCache)
        let groupDetailsCallsAfterBootstrap = runtime.groupDetailsCallCounts["group"] ?? 0
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected an active group chat")
            return
        }

        // Leave the auto-selected empty timeline so a fresh selection below reloads the
        // subscription snapshot after installing messages, while retaining the member cache
        // primed by chat-list enrichment.
        state.showSettings()
        runtime.installMessages([
            appMessage(
                id: "alice-message",
                groupIdHex: "group",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                plaintext: "Timeline sender should reuse cached members.",
                kind: 9,
                recordedAt: 1_700_000_000
            )
        ], groupIdHex: "group")

        state.selectChat(groupChat)
        let didLoadTimelineMessage = await waitFor {
            state.messagesByChat["group"]?.map(\.id) == ["alice-message"]
        }

        #expect(didLoadTimelineMessage)
        #expect((runtime.groupDetailsCallCounts["group"] ?? 0) == groupDetailsCallsAfterBootstrap)
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
        #expect(state.groupImageSearchQuery.isEmpty)
        await state.searchGroupImages()
        let emptyImageSearchQueries = await imageSearchClient.queries
        #expect(emptyImageSearchQueries.isEmpty)

        state.groupImageSearchQuery = "aurora"
        await state.searchGroupImages()
        guard let result = state.groupImageResults.first else {
            Issue.record("Expected an image result")
            return
        }
        await state.setGroupImage(result)

        let imageSearchQueries = await imageSearchClient.queries
        #expect(imageSearchQueries == ["aurora"])
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

    @Test func conversationHeaderChatInfoButtonOpensGroupDetailsSheet() throws {
        // The header is a private SwiftUI view, so this source-shape regression
        // guards the user-facing toolbar affordance directly: the info button
        // must remain wired to the group details sheet instead of an empty action.
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let messengerShellURL = projectRootURL
            .appendingPathComponent("whitenoise-mac")
            .appendingPathComponent("Views")
            .appendingPathComponent("MessengerShellView.swift")
        let source = try String(contentsOf: messengerShellURL, encoding: .utf8)
        let headerStart = try #require(source.range(of: "private struct ConversationHeader: View {"))
        let headerEnd = try #require(source.range(of: "private struct GroupDetailsSheet: View {"))
        let headerSource = String(source[headerStart.lowerBound..<headerEnd.lowerBound])

        #expect(headerSource.contains("Task { await workspace.showGroupDetails(for: chat) }"))
        #expect(headerSource.contains("Image(systemName: \"info.circle\")"))
        #expect(headerSource.contains(".sheet(isPresented: $workspace.isGroupDetailsPresented)"))
        #expect(headerSource.contains("GroupDetailsSheet(chat: chat)"))
        #expect(!headerSource.contains("Button {} label: {\n                        Image(systemName: \"info.circle"))
        #expect(!headerSource.contains("Button {} label: {\n                        Image(systemName: \"info.circle.fill"))
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
            copyTextHandler: { text, _ in copiedText = text },
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

    @Test func remoteImagePolicyAllowsOnlyHttpsWithHost() async throws {
        // Allowed: https with a real host.
        #expect(RemoteImageURLPolicy.isAllowed(URL(string: "https://example.com/avatar.png")!))
        #expect(RemoteImageURLPolicy.isAllowed(URL(string: "HTTPS://Example.com/a.jpg")!))

        // Rejected: cleartext http (network observers can see the request).
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "http://example.com/avatar.png")!))
        // Rejected: non-web schemes that could exfiltrate or hit local resources.
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "file:///etc/passwd")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "data:image/png;base64,AAAA")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "ftp://example.com/a.png")!))
        // Rejected: https without a host.
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https:///nohost")!))
    }

    @Test func remoteImageCollectorReturnsAllBytesUnderCap() async throws {
        // Several chunks spanning typical OS delivery sizes should round-trip byte-for-byte.
        let chunkSize = 64 * 1024
        let payload = (0..<(chunkSize * 2 + 123)).map { UInt8($0 & 0xFF) }
        var collector = CappedDataCollector(cap: Int64(payload.count) + 1)
        // Feed the payload in chunks the way URLSession would deliver it.
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            #expect(collector.append(Data(payload[offset..<end])))
            offset = end
        }
        #expect(!collector.exceededCap)
        #expect(Array(collector.data) == payload)
    }

    @Test func remoteImageCollectorAcceptsExactlyCapBytes() async throws {
        // Exactly `cap` bytes is allowed (the check rejects only when total exceeds cap).
        let payload = [UInt8](repeating: 0xAB, count: 64 * 1024 + 7)
        var collector = CappedDataCollector(cap: Int64(payload.count))
        #expect(collector.append(Data(payload)))
        #expect(!collector.exceededCap)
        #expect(collector.data.count == payload.count)
    }

    @Test func remoteImageCollectorRejectsOverCap() async throws {
        // One byte past the cap aborts the download (unbounded-response protection): the
        // over-cap chunk is rejected, the flag is set, and subsequent chunks are ignored.
        let cap = 64 * 1024
        var collector = CappedDataCollector(cap: Int64(cap))
        #expect(collector.append(Data([UInt8](repeating: 0x01, count: cap))))
        #expect(!collector.append(Data([0x02])))
        #expect(collector.exceededCap)
        // Further appends stay rejected and do not grow the buffer.
        #expect(!collector.append(Data([0x03, 0x04])))
        #expect(collector.data.count == cap)
    }

    @Test func remoteImageCollectorHandlesEmptyResponse() async throws {
        let collector = CappedDataCollector(cap: 1024)
        #expect(collector.data.isEmpty)
        #expect(!collector.exceededCap)
    }

    @Test func remoteImageSanitizedURLRejectsUntrustedInput() async throws {
        // nil / empty / whitespace-only -> nil (no request issued).
        #expect(RemoteImageURLPolicy.sanitizedURL(from: nil) == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "   \n ") == nil)

        // Disallowed schemes -> nil.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "http://tracker.example/pixel.gif") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "javascript:alert(1)") == nil)

        // Allowed https with surrounding whitespace -> trimmed, valid URL.
        let sanitized = RemoteImageURLPolicy.sanitizedURL(from: "  https://cdn.example/p.png  ")
        #expect(sanitized?.absoluteString == "https://cdn.example/p.png")
    }

    @MainActor
    @Test func loadRemoteImagesDefaultsOffAndPersists() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "whitenoise.mac.loadRemoteImages")
        defer { restoreDefault(previous, forKey: "whitenoise.mac.loadRemoteImages") }

        // Privacy-preserving default: off when no preference has been stored.
        defaults.removeObject(forKey: "whitenoise.mac.loadRemoteImages")
        let state = WorkspaceState.preview()
        #expect(!state.loadRemoteImages)

        // Opting in persists to UserDefaults so a fresh instance honours it.
        state.loadRemoteImages = true
        #expect(defaults.bool(forKey: "whitenoise.mac.loadRemoteImages"))
        let reloaded = WorkspaceState.preview()
        #expect(reloaded.loadRemoteImages)
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
    @Test func chatSwitchPreservesDraftTextPerConversation() async throws {
        let state = WorkspaceState.preview()
        let design = ChatItem.samples[0]
        let nvk = ChatItem.samples[1]

        #expect(state.selectedChat?.id == design.id)
        state.draftText = "Design reply in progress"

        state.selectChat(nvk)
        #expect(state.draftText.isEmpty)
        state.draftText = "NVK reply in progress"

        state.selectChat(design)
        #expect(state.draftText == "Design reply in progress")

        state.selectChat(nvk)
        #expect(state.draftText == "NVK reply in progress")
    }

    @MainActor
    @Test func chatSwitchPreservesReplyDraftContextPerConversation() async throws {
        let state = WorkspaceState.preview()
        let design = ChatItem.samples[0]
        let nvk = ChatItem.samples[1]
        let designReply = MessageItem(
            id: "design-parent",
            senderName: "NVK",
            body: "Design plan",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        let nvkReply = MessageItem(
            id: "nvk-parent",
            senderName: "NVK",
            body: "Direct ping",
            sentAt: Date(timeIntervalSince1970: 1_700_000_010),
            isOutgoing: false
        )

        #expect(state.selectedChat?.id == design.id)
        state.startReply(to: designReply)

        state.selectChat(nvk)
        #expect(state.replyDraftContext == nil)
        state.startReply(to: nvkReply)

        state.selectChat(design)
        #expect(state.replyDraftContext == MessageReplyContext(
            targetMessageId: "design-parent",
            senderName: "NVK",
            body: "Design plan"
        ))

        state.selectChat(nvk)
        #expect(state.replyDraftContext == MessageReplyContext(
            targetMessageId: "nvk-parent",
            senderName: "NVK",
            body: "Direct ping"
        ))
    }

    @MainActor
    @Test func accountSwitchRestoresDraftTextWhenReturningToConversation() async throws {
        let state = WorkspaceState.preview()
        let design = ChatItem.samples[0]

        #expect(state.selectedChat?.id == design.id)
        state.draftText = "draft survives account hop"

        state.selectAccount(AccountItem.samples[1])
        #expect(state.activeAccountId == AccountItem.samples[1].id)
        #expect(state.draftText.isEmpty)

        state.selectAccount(AccountItem.samples[0])
        #expect(state.activeAccountId == AccountItem.samples[0].id)
        #expect(state.selectedChat?.id == design.id)
        #expect(state.draftText == "draft survives account hop")
    }

    @MainActor
    @Test func sharedConversationDraftsAreIsolatedPerAccount() async throws {
        let state = WorkspaceState.preview()
        let sharedChat = ChatItem.samples[1]

        state.selectChat(sharedChat)
        state.draftText = "primary account draft"

        state.selectAccount(AccountItem.samples[1])
        #expect(state.selectedChat?.id == sharedChat.id)
        #expect(state.draftText.isEmpty)
        state.draftText = "backup account draft"

        state.selectAccount(AccountItem.samples[0])
        state.selectChat(sharedChat)
        #expect(state.draftText == "primary account draft")

        state.selectAccount(AccountItem.samples[1])
        #expect(state.selectedChat?.id == sharedChat.id)
        #expect(state.draftText == "backup account draft")
    }

    @MainActor
    @Test func reloadChatsPrunesDraftsForRemovedConversations() async throws {
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
        let didLoadBothChats = await waitFor {
            Set(state.activeChats.map(\.id)) == ["group", "direct-group"]
        }
        #expect(didLoadBothChats)

        guard let groupChat = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected group chat")
            return
        }
        state.selectChat(groupChat)
        state.draftText = "draft for removed group"

        runtime.installGroups([directGroup()])
        await state.reloadChats()
        #expect(state.activeChats.map(\.id) == ["direct-group"])

        runtime.installGroups([messageGroup(), directGroup()])
        await state.reloadChats()
        guard let restoredGroupChat = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected restored group chat")
            return
        }
        state.selectChat(restoredGroupChat)

        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func newChatComposerOpensInChatColumnWithoutChangingDetailSelection() async throws {
        let state = WorkspaceState.preview()
        let selection = state.selection
        state.draftText = "half-written message"

        state.showNewChat()

        #expect(state.isNewChatComposerVisible)
        #expect(state.selection == selection)
        #expect(state.draftText == "half-written message")
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
        AppLanguage.refreshCachedLocale()

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
    @Test func concurrentSettingsLoadsForSameAccountCoalesce() async throws {
        // Issue #4: settings loading is driven from more than one entry point (the settings
        // view's `.task(id: activeAccountId)` and explicit reloads), so two overlapping
        // `loadSettingsData()` calls for the same account must coalesce onto a single in-flight
        // load rather than duplicating the per-account profile / relay fetches.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let baselineProfileCalls = runtime.userProfileCallCount
        let baselineRelayCalls = runtime.accountRelayListsCallCount

        // Two concurrent loads for the same active account. The first to run installs the
        // in-flight task before suspending; the second observes it and awaits the same task.
        async let first: Void = state.loadSettingsData()
        async let second: Void = state.loadSettingsData()
        _ = await (first, second)

        // Exactly one additional profile + relay fetch despite two concurrent callers.
        #expect(runtime.userProfileCallCount == baselineProfileCalls + 1)
        #expect(runtime.accountRelayListsCallCount == baselineRelayCalls + 1)
        #expect(state.isLoadingSettings == false)
    }

    @MainActor
    @Test func sequentialSettingsLoadsForSameAccountStillReload() async throws {
        // Coalescing must not turn a later, intentionally-sequential reload into a no-op: once a
        // load has finished, a fresh `loadSettingsData()` performs a new fetch.
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
        let afterFirst = runtime.userProfileCallCount
        await state.loadSettingsData()

        #expect(runtime.userProfileCallCount == afterFirst + 1)
    }

    @MainActor
    @Test func cancellingInFlightSettingsLoadWithNoActiveAccountClearsSpinner() async throws {
        // Issue #4 (adversarial-review blocking finding): a settings load that is cancelled
        // *without* a replacement load starting must not leave `isLoadingSettings` stuck `true`.
        // Repro: hold a load suspended mid-flight (at `refreshNotificationAuthorizationStatus()`),
        // clear the active account (as account removal of the last account does), then let the
        // stale load resume. The resumed task must NOT own the spinner (a newer generation has
        // superseded it); the no-active-account reset path owns clearing it.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let gate = GatedLocalNotificationCenter()
        let state = WorkspaceState(
            localNotificationCenter: gate,
            clientFactory: { runtime }
        )

        await state.bootstrap()

        // Arm the gate so the next settings load suspends inside refreshNotificationAuthorizationStatus().
        gate.gateEnabled = true
        async let inflight: Void = state.loadSettingsData()

        // Spin the main actor until the suspended load has set the spinner and reached the gate.
        while !(state.isLoadingSettings && gate.didReachGate) {
            await Task.yield()
        }
        #expect(state.isLoadingSettings)

        // Clear the active account with no replacement load — the no-active-account branch of
        // loadSettingsData() runs synchronously, cancels the in-flight task, and resets to defaults.
        state.activeAccountId = nil
        await state.loadSettingsData()

        // The spinner must already be cleared by the reset path, even before the stale load resumes.
        #expect(state.isLoadingSettings == false)

        // Release the gate so the stale load resumes; its defer must see the bumped generation and
        // leave the (already-false) spinner untouched rather than resurrecting it.
        gate.releaseGate()
        _ = await inflight

        #expect(state.isLoadingSettings == false)
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
    @Test func observabilityRuntimeConfigurationSkipsUnchangedRequests() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.activeAccountId")

        let primary = AccountSummaryFfi(
            label: "primary-account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "secondary-account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        runtime.installProfile(
            accountIdHex: primary.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "primary",
                displayName: "Primary Account",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: secondary.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "secondary",
                displayName: "Secondary Account",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
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

        #expect(runtime.telemetryInstallIdCallCount == 1)
        #expect(runtime.relayTelemetryRuntimeConfigSetCallCount == 1)
        #expect(runtime.auditLogTrackerConfigSetCallCount == 1)
        #expect(runtime.auditLogTrackerConfig?.source.accountLabel == "Primary Account")

        let secondaryItem = try #require(state.accounts.first { $0.accountRef == secondary.label })
        state.selectAccount(secondaryItem)
        let didRefreshAccountLabel = await waitFor {
            runtime.auditLogTrackerConfig?.source.accountLabel == "Secondary Account"
        }

        #expect(didRefreshAccountLabel)
        #expect(runtime.telemetryInstallIdCallCount == 1)
        #expect(runtime.relayTelemetryRuntimeConfigSetCallCount == 1)
        #expect(runtime.auditLogTrackerConfigSetCallCount == 2)
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
    @Test func notificationListenerRestartsWhenStreamEnds() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationStreamEndsImmediately = true
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didRestart = await waitFor {
            runtime.notificationSubscriptionCount >= 2
        }

        #expect(didRestart)
        await state.deleteAllData()
    }

    @MainActor
    @Test func chatListListenerRestartsWhenUpdateStreamEnds() async throws {
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
        runtime.chatListStreamEndsAfterUpdates = true
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didRestart = await waitFor {
            runtime.chatListSubscriptionCount >= 2
        }

        #expect(didRestart)
        await state.deleteAllData()
    }

    @MainActor
    @Test func timelineListenerRestartsWhenLiveStreamEndsForSelectedChat() async throws {
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
                id: "initial",
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Initial message",
                kind: 9,
                recordedAt: 1_700_000_000
            )
        ], groupIdHex: "direct-group")
        runtime.timelineStreamEndsAfterUpdates = true
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didRestart = await waitFor {
            runtime.timelineSubscriptionCount >= 2
        }

        #expect(didRestart)
        await state.deleteAllData()
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
    @Test func senderOnlyPreviewModeOmitsDecryptedMessageBody() async throws {
        // Issue #30: notification body must never leak decrypted plaintext when
        // the user opts into sender-only previews. DM => body is generic, group
        // => body is just the sender name; neither contains the message text.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.notificationPreviewMode = .senderOnly

        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "dm-notice",
            groupIdHex: "direct-group",
            senderName: "Alice",
            previewText: "Top secret plaintext."
        ))
        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "group-notice",
            groupIdHex: "team-group",
            senderName: "Bob",
            previewText: "More secret plaintext.",
            isDm: false,
            groupName: "Engineering"
        ))

        #expect(notificationCenter.postedRequests.count == 2)
        let dm = notificationCenter.postedRequests[0]
        #expect(dm.title == "Alice")
        #expect(dm.body == "New message")
        #expect(!dm.body.contains("Top secret plaintext."))

        let group = notificationCenter.postedRequests[1]
        #expect(group.title == "Engineering")
        #expect(group.body == "Bob")
        #expect(!group.body.contains("More secret plaintext."))
    }

    @MainActor
    @Test func hiddenPreviewModeRevealsNeitherSenderNorContents() async throws {
        // Issue #30: hidden mode must reveal nothing about who or what — generic
        // title and body for both DMs and groups.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.notificationPreviewMode = .hidden

        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "dm-notice",
            groupIdHex: "direct-group",
            senderName: "Alice",
            previewText: "Top secret plaintext."
        ))
        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "group-notice",
            groupIdHex: "team-group",
            senderName: "Bob",
            previewText: "More secret plaintext.",
            isDm: false,
            groupName: "Engineering"
        ))

        #expect(notificationCenter.postedRequests.count == 2)
        for request in notificationCenter.postedRequests {
            #expect(request.title == "White Noise")
            #expect(request.body == "New message")
            #expect(!request.body.contains("plaintext"))
            #expect(request.title != "Alice")
            #expect(request.title != "Engineering")
        }
    }

    @MainActor
    @Test func fullPreviewModeIsDefaultAndPreservesLegacyBody() async throws {
        // Backward-compatible default: full previews keep the prior behavior so
        // existing users see no change unless they opt into a stricter mode.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.notificationPreviewMode == .full)

        await state.handleNotificationUpdate(notificationUpdate(
            account: account,
            notificationKey: "group-notice",
            groupIdHex: "team-group",
            senderName: "Bob",
            previewText: "The launch plan is ready.",
            isDm: false,
            groupName: "Engineering"
        ))

        #expect(notificationCenter.postedRequests.count == 1)
        #expect(notificationCenter.postedRequests.first?.title == "Engineering")
        #expect(notificationCenter.postedRequests.first?.body == "Bob: The launch plan is ready.")
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
            conversationWindowVisibilityProvider: { true },
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
    @Test func activeSelectedChatNotificationPostsLocalAlertWhenConversationWindowIsHidden() async throws {
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
            conversationWindowVisibilityProvider: { false },
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
        #expect(notificationCenter.postedRequests.map(\.identifier) == ["notice-1"])
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

    // MARK: - Relay URL validation (issue #18)

    @Test func relayValidatorAcceptsSecureWssRelays() async throws {
        #expect(RelayURLValidator.classify("wss://relay.example.com") == .secure)
        #expect(RelayURLValidator.classify("wss://relay.us.whitenoise.chat") == .secure)
        #expect(RelayURLValidator.classify("WSS://Relay.Example.com") == .secure)
        #expect(RelayURLValidator.isAcceptable("wss://relay.example.com"))
        #expect(!RelayURLValidator.isInsecure("wss://relay.example.com"))
    }

    @Test func relayValidatorRejectsCleartextWsOnPublicHosts() async throws {
        #expect(RelayURLValidator.classify("ws://relay.example.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://192.168.1.10:7777") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://10.0.0.1") == .insecureRejected)
        #expect(!RelayURLValidator.isAcceptable("ws://relay.example.com"))
        // Rejected relays are not "insecure-but-allowed" — they simply cannot be saved.
        #expect(!RelayURLValidator.isInsecure("ws://relay.example.com"))
    }

    @Test func relayValidatorAllowsCleartextWsOnLoopbackForDev() async throws {
        for url in [
            "ws://localhost",
            "ws://localhost:7000",
            "ws://127.0.0.1",
            "ws://127.0.0.1:8080/relay",
            "ws://127.1.2.3",
            "ws://[::1]:7000"
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureLoopback, "expected loopback for \(url)")
            #expect(RelayURLValidator.isAcceptable(url), "expected acceptable for \(url)")
            #expect(RelayURLValidator.isInsecure(url), "expected insecure flag for \(url)")
        }
    }

    @Test func relayValidatorRejectsNonRelaySchemesAndJunk() async throws {
        for url in ["", "   ", "https://relay.example.com", "relay.example.com", "wssx://foo", "ws://"] {
            #expect(!RelayURLValidator.isAcceptable(url), "expected rejection for \(String(reflecting: url))")
        }
        // Leading/trailing whitespace is trimmed before classification, so a
        // surrounded wss:// relay is still accepted as secure.
        #expect(RelayURLValidator.classify("  wss://relay.example.com  ") == .secure)
        #expect(RelayURLValidator.isAcceptable(" wss://relay.example.com "))
    }

    @Test func relayValidatorFlagsAllCleartextWsAsInsecureForUI() async throws {
        // Loopback dev relays are cleartext.
        #expect(RelayURLValidator.isCleartext("ws://127.0.0.1:7000"))
        #expect(RelayURLValidator.isCleartext("ws://localhost"))
        // Pre-existing public ws:// relays loaded from a saved list are also
        // cleartext and must be flagged, even though they cannot be saved again.
        #expect(RelayURLValidator.isCleartext("ws://relay.example.com"))
        #expect(RelayURLValidator.isCleartext("ws://192.168.1.10:7777"))
        // wss:// and junk are not cleartext.
        #expect(!RelayURLValidator.isCleartext("wss://relay.example.com"))
        #expect(!RelayURLValidator.isCleartext("https://relay.example.com"))
        #expect(!RelayURLValidator.isCleartext(""))
    }

    @Test func relayValidatorRejectsSchemeOnlyAndHostlessURLs() async throws {
        // Regression: a scheme prefix with no host must be malformed, not secure.
        // Previously `wss://` was accepted as `.secure` purely on its prefix.
        #expect(RelayURLValidator.classify("wss://") == .invalid)
        #expect(RelayURLValidator.classify("ws://") == .invalid)
        #expect(RelayURLValidator.classify("wss://  ") == .invalid)
        #expect(!RelayURLValidator.isAcceptable("wss://"))
        #expect(!RelayURLValidator.isInsecure("wss://"))
        #expect(!RelayURLValidator.isCleartext("wss://"))
    }

    @Test func relayValidatorRejectsSpoofedLoopbackHosts() async throws {
        // Hostnames that merely *contain* a loopback token must not be treated as loopback.
        #expect(RelayURLValidator.classify("ws://127.0.0.1.evil.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://localhost.evil.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://notlocalhost") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://127.0.0.256") == .insecureRejected)
    }

    @MainActor
    @Test func addRelayDraftRejectsCleartextPublicWsRelay() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let before = state.relayDraft
        state.newRelayURL = "ws://relay.example.com"
        state.addRelayDraftURL()

        #expect(state.relayDraft == before)
        #expect(state.lastError != nil)
    }

    @MainActor
    @Test func addRelayDraftAcceptsSecureAndLoopbackRelays() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.relayDraft = []

        state.newRelayURL = "wss://relay.example.com"
        state.addRelayDraftURL()
        state.newRelayURL = "ws://127.0.0.1:7000"
        state.addRelayDraftURL()

        #expect(state.relayDraft == ["wss://relay.example.com", "ws://127.0.0.1:7000"])
        #expect(!state.isInsecureRelay("wss://relay.example.com"))
        #expect(state.isInsecureRelay("ws://127.0.0.1:7000"))
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
    /// The account that `login` / `createIdentity` will materialise. `var` so a
    /// test can point the next add at a different account (multi-account flows).
    var createdAccount: AccountSummaryFfi?
    private(set) var startCallCount = 0
    var didStart: Bool { startCallCount > 0 }
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
    private(set) var sentText: SentText?
    // Issue #78 reentrancy-test support: count message-action FFI calls so a test can prove
    // an overlapping duplicate was dropped by the WorkspaceState guard before reaching the runtime.
    private(set) var sendTextCallCount = 0
    private(set) var replyToMessageCallCount = 0
    private(set) var reactToMessageCallCount = 0
    private(set) var deleteMessageCallCount = 0
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
    /// Number of times `userProfile` was queried — used to assert settings-load coalescing
    /// (issue #4 regression): overlapping `loadSettingsData()` calls for the same account must
    /// not duplicate the per-account profile fetch.
    private(set) var userProfileCallCount = 0
    private(set) var accountRelayListsCallCount = 0
    /// Per-group call count for `groupDetails`, used to assert chat-list enrichment runs
    /// through the incremental per-row path (issue #40 regression).
    private(set) var groupDetailsCallCounts: [String: Int] = [:]
    private(set) var chatListSubscriptionCount = 0
    private(set) var notificationSubscriptionCount = 0
    private(set) var timelineSubscriptionCount = 0
    private(set) var lastTimelineSubscription: FakeTimelineMessagesSubscription?
    var chatListStreamEndsAfterUpdates = false
    var notificationStreamEndsImmediately = false
    var timelineStreamEndsAfterUpdates = false
    private(set) var timelineMessageQueries: [TimelineMessageQueryFfi] = []
    var profileRefreshDelaysByAccountId: [String: UInt64] = [:]
    var accountIdsMissingProfiles = Set<String>()
    var timelineMessagesHandler: ((TimelineMessageQueryFfi) -> TimelinePageFfi)?
    private let syncCallThreadLock = NSLock()
    private var syncCallThreads: [String: [Bool]] = [:]
    /// When set, `subscribeNotifications()` throws this error, simulating a background
    /// notification-listener failure for routing tests.
    var subscribeNotificationsError: Error?
    /// Simulates the async relay/runtime delay before the first timeline snapshot is available.
    var timelineSubscriptionDelayNanoseconds: UInt64 = 0
    var timelineUpdateDelayNanoseconds: UInt64 = 0
    /// Issue #78 reentrancy-test support: when armed, the first message-action FFI call
    /// (`sendText`/`replyToMessage`/`reactToMessage`/`deleteMessage`) suspends until
    /// `releaseMessageActionGate()` is invoked, holding the first invocation in-flight so a
    /// test can issue an overlapping second call and assert the WorkspaceState guard dropped it.
    var messageActionGateEnabled = false
    private(set) var didReachMessageActionGate = false
    private var messageActionGateContinuation: CheckedContinuation<Void, Never>?
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
    private(set) var auditLogTrackerConfigSetCallCount = 0
    private(set) var deletedAuditLogFilePaths: [String] = []
    private(set) var didPostAuditLogTrackerUpdate = false
    private(set) var relayTelemetryRuntimeConfig: RelayTelemetryRuntimeConfigFfi?
    private(set) var relayTelemetryRuntimeConfigSetCallCount = 0
    private(set) var telemetryInstallIdCallCount = 0
    private(set) var removedAccountRefs: [String] = []
    private(set) var didDeleteAllLocalData = false
    /// Optional hook fired inside `removeAccount` after the ref is recorded but before the
    /// account is actually dropped, used to simulate a racing UI action (e.g. the user
    /// selecting the account currently being removed) mid-await.
    var onRemoveAccountMidFlight: (@Sendable (String) async -> Void)?

    init(accounts: [AccountSummaryFfi], createdAccount: AccountSummaryFfi? = nil) {
        self.storedAccounts = accounts
        self.createdAccount = createdAccount
    }

    func start() async throws {
        startCallCount += 1
        storedAccounts = storedAccounts.map { account in
            var runningAccount = account
            runningAccount.running = true
            return runningAccount
        }
    }

    func listAccounts() throws -> [AccountSummaryFfi] {
        recordSyncCall("listAccounts")
        return storedAccounts
    }

    func clearSyncCallThreadRecords() {
        syncCallThreadLock.lock()
        syncCallThreads = [:]
        syncCallThreadLock.unlock()
    }

    func syncCallThreadRecord(_ name: String) -> [Bool] {
        syncCallThreadLock.lock()
        let threads = syncCallThreads[name] ?? []
        syncCallThreadLock.unlock()
        return threads
    }

    private func recordSyncCall(_ name: String) {
        syncCallThreadLock.lock()
        syncCallThreads[name, default: []].append(Thread.isMainThread)
        syncCallThreadLock.unlock()
    }

    func npub(accountIdHex: String) -> String? {
        recordSyncCall("npub")
        return "npub1\(accountIdHex.prefix(12))"
    }

    func displayName(accountIdHex: String) -> String? {
        recordSyncCall("displayName")
        guard !accountIdsMissingProfiles.contains(accountIdHex) else { return nil }
        let resolvedProfile = profilesByAccountId[accountIdHex] ?? profile
        return resolvedProfile.displayName ?? resolvedProfile.name
    }

    func userProfile(accountIdHex: String) throws -> UserProfileMetadataFfi? {
        userProfileCallCount += 1
        recordSyncCall("userProfile")
        guard !accountIdsMissingProfiles.contains(accountIdHex) else { return nil }
        return profilesByAccountId[accountIdHex] ?? profile
    }

    func normalizeMemberRef(memberRef: String) throws -> MemberRefFfi {
        recordSyncCall("normalizeMemberRef")
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
        addOrReplaceAccount(createdAccount)
        return createdAccount
    }

    func login(identity: String, defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        guard let createdAccount else { throw FakeMarmotRuntimeError.missingCreatedAccount }
        addOrReplaceAccount(createdAccount)
        return createdAccount
    }

    /// Mirrors the real runtime: `login` / `createIdentity` add the account to
    /// the known set (replacing any existing entry with the same id) rather
    /// than discarding accounts already brought up this session. The account is
    /// not marked `running` here — only `start()` brings accounts online, which
    /// is the behaviour issues #31 / #74 exercise.
    private func addOrReplaceAccount(_ account: AccountSummaryFfi) {
        if let index = storedAccounts.firstIndex(where: { $0.accountIdHex == account.accountIdHex }) {
            storedAccounts[index] = account
        } else {
            storedAccounts.append(account)
        }
    }

    func publishUserProfile(accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]) async throws -> UserProfileMetadataFfi {
        lastPublishedProfileDefaultRelays = defaultRelays
        lastPublishedProfileBootstrapRelays = bootstrapRelays
        self.profile = profile
        return profile
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        accountRelayListsCallCount += 1
        recordSyncCall("accountRelayLists")
        return relayLists
    }

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        accountKeyPackagesCallCount += 1
        lastPackageFetchBootstrapRelays = bootstrapRelays
        return keyPackages
    }

    func auditLogFiles() throws -> [AuditLogFileFfi] {
        recordSyncCall("auditLogFiles")
        return storedAuditLogFiles
    }

    func auditLogSettings() throws -> AuditLogSettingsFfi {
        recordSyncCall("auditLogSettings")
        return storedAuditLogSettings
    }

    func deleteAuditLogFile(path: String) async throws -> AuditLogDeleteResultFfi {
        deletedAuditLogFilePaths.append(path)
        storedAuditLogFiles.removeAll { $0.path == path }
        return AuditLogDeleteResultFfi(stillRecording: storedAuditLogSettings.enabled)
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        recordSyncCall("notificationSettings")
        return notificationSettings
    }

    func postAuditLogTrackerUpdate() async throws -> AuditLogTrackerUpdateResultFfi {
        didPostAuditLogTrackerUpdate = true
        return nextAuditLogTrackerUpdate
    }

    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi {
        recordSyncCall("relayTelemetrySettings")
        return storedRelayTelemetrySettings
    }

    func setAuditLogSettings(settings: AuditLogSettingsFfi) async throws -> AuditLogSettingsFfi {
        storedAuditLogSettings = settings
        return storedAuditLogSettings
    }

    func setAuditLogTrackerConfig(config: AuditLogTrackerConfigFfi) throws -> AuditLogTrackerConfigFfi {
        auditLogTrackerConfigSetCallCount += 1
        recordSyncCall("setAuditLogTrackerConfig")
        auditLogTrackerConfig = config
        return config
    }

    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi {
        recordSyncCall("setLocalNotificationsEnabled")
        localNotificationsEnabledSet = enabled
        notificationSettings.localNotificationsEnabled = enabled
        return notificationSettings
    }

    func setRelayTelemetryRuntimeConfig(config: RelayTelemetryRuntimeConfigFfi) async throws {
        relayTelemetryRuntimeConfigSetCallCount += 1
        relayTelemetryRuntimeConfig = config
    }

    func setRelayTelemetrySettings(settings: RelayTelemetrySettingsFfi) async throws -> RelayTelemetrySettingsFfi {
        storedRelayTelemetrySettings = settings
        return storedRelayTelemetrySettings
    }

    func telemetryInstallId() throws -> String {
        telemetryInstallIdCallCount += 1
        recordSyncCall("telemetryInstallId")
        return "test-install-id"
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
        if let onRemoveAccountMidFlight {
            await onRemoveAccountMidFlight(accountRef)
        }
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
        groupDetailsCallCounts[groupIdHex, default: 0] += 1
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
            updates: chatListUpdates,
            endsWhenExhausted: chatListStreamEndsAfterUpdates
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
        notificationSubscriptionCount += 1
        if let subscribeNotificationsError {
            throw subscribeNotificationsError
        }
        return FakeNotificationsSubscription(endsImmediately: notificationStreamEndsImmediately)
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        recordSyncCall("timelineMessages")
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
            updateDelayNanoseconds: timelineUpdateDelayNanoseconds,
            endsWhenExhausted: timelineStreamEndsAfterUpdates
        )
        lastTimelineSubscription = subscription
        return subscription
    }

    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi? {
        recordSyncCall("initializeChatReadState")
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi? {
        recordSyncCall("markTimelineMessageRead")
        markedReadMessageIds.append(messageIdHex)
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        sendTextCallCount += 1
        sentText = SentText(groupIdHex: groupIdHex, text: text)
        await passMessageActionGateIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["text"])
    }

    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws -> SendSummaryFfi {
        replyToMessageCallCount += 1
        repliedMessage = SentReply(groupIdHex: groupIdHex, targetMessageId: targetMessageId, text: text)
        await passMessageActionGateIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["reply"])
    }

    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws -> SendSummaryFfi {
        reactToMessageCallCount += 1
        reactedMessage = SentReaction(groupIdHex: groupIdHex, targetMessageId: targetMessageId, emoji: emoji)
        await passMessageActionGateIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["reaction"])
    }

    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        deleteMessageCallCount += 1
        deletedMessage = DeletedMessage(groupIdHex: groupIdHex, targetMessageId: targetMessageId)
        await passMessageActionGateIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["delete"])
    }

    /// Suspends the first message-action FFI call when the gate is armed, recording arrival so a
    /// test can spin until the first invocation is in-flight, then issue the overlapping second call.
    private func passMessageActionGateIfArmed() async {
        guard messageActionGateEnabled, messageActionGateContinuation == nil, !didReachMessageActionGate else { return }
        didReachMessageActionGate = true
        await withCheckedContinuation { continuation in
            messageActionGateContinuation = continuation
        }
    }

    func releaseMessageActionGate() {
        messageActionGateContinuation?.resume()
        messageActionGateContinuation = nil
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

private struct SentText: Equatable {
    let groupIdHex: String
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

private func awaitSubscriptionCancellation<T>() async -> T? {
    while !Task.isCancelled {
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            break
        }
    }
    return nil
}

private final class FakeChatListSubscription: ChatListSubscription {
    private let rows: [ChatListRowFfi]
    private var updates: [ChatListSubscriptionUpdateFfi]
    private let endsWhenExhausted: Bool

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.rows = []
        self.updates = []
        self.endsWhenExhausted = true
        super.init(unsafeFromRawPointer: pointer)
    }

    init(
        rows: [ChatListRowFfi],
        updates: [ChatListSubscriptionUpdateFfi] = [],
        endsWhenExhausted: Bool = false
    ) {
        self.rows = rows
        self.updates = updates
        self.endsWhenExhausted = endsWhenExhausted
        super.init(noPointer: NoPointer())
    }

    override func snapshot() -> [ChatListRowFfi] {
        rows
    }

    override func next() async -> ChatListRowFfi? {
        if endsWhenExhausted { return nil }
        return await awaitSubscriptionCancellation()
    }

    override func nextUpdate() async -> ChatListSubscriptionUpdateFfi? {
        guard !updates.isEmpty else {
            if endsWhenExhausted { return nil }
            return await awaitSubscriptionCancellation()
        }
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
    private let endsWhenExhausted: Bool
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
        self.endsWhenExhausted = true
        super.init(unsafeFromRawPointer: pointer)
    }

    init(
        messages: [TimelineMessageRecordFfi],
        limit: Int,
        windowCap: Int,
        updates: [TimelineSubscriptionUpdateFfi] = [],
        updateDelayNanoseconds: UInt64 = 0,
        endsWhenExhausted: Bool = false
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
        self.endsWhenExhausted = endsWhenExhausted
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
        guard !updates.isEmpty else {
            if endsWhenExhausted { return nil }
            return await awaitSubscriptionCancellation()
        }
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
        guard !updates.isEmpty else {
            if endsWhenExhausted { return nil }
            return await awaitSubscriptionCancellation()
        }
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

/// A notification center whose `authorizationStatus()` can be suspended on demand, used to hold a
/// settings load at its `await refreshNotificationAuthorizationStatus()` point so a test can mutate
/// state (e.g. clear the active account) before the load resumes. Issue #4 regression support.
@MainActor
private final class GatedLocalNotificationCenter: LocalNotificationCenter {
    /// When false, `authorizationStatus()` returns immediately (e.g. during `bootstrap()`); when
    /// true, it suspends on the first call until `releaseGate()` is invoked.
    var gateEnabled = false
    private(set) var didReachGate = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var responseHandler: (@MainActor ([String: String]) -> Void)?

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        if gateEnabled {
            didReachGate = true
            await withCheckedContinuation { continuation in
                gateContinuation = continuation
            }
        }
        return .authorized
    }

    func releaseGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus {
        .authorized
    }

    func post(_ notification: LocalNotificationRequest) async throws {}

    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void) {
        responseHandler = handler
    }
}

private final class FakeNotificationsSubscription: NotificationsSubscription {
    private let endsImmediately: Bool

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.endsImmediately = true
        super.init(unsafeFromRawPointer: pointer)
    }

    init(endsImmediately: Bool = false) {
        self.endsImmediately = endsImmediately
        super.init(noPointer: NoPointer())
    }

    override func next() async -> NotificationUpdateFfi? {
        if endsImmediately { return nil }
        return await awaitSubscriptionCancellation()
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
    isDm: Bool = true,
    groupName: String? = nil,
    isFromSelf: Bool = false
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: notificationKey,
        conversationKey: groupIdHex,
        trigger: .newMessage,
        accountRef: account.label,
        accountIdHex: account.accountIdHex,
        groupIdHex: groupIdHex,
        groupName: groupName,
        isDm: isDm,
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

/// A trivial mutable clock for driving time-dependent cache behaviour deterministically
/// in tests (whitenoise-mac#8). `@MainActor` so it matches `WorkspaceState`'s isolation
/// when injected via `nowProvider`.
@MainActor
private final class MutableClock {
    var now: Date
    init(now: Date) { self.now = now }
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
    // Tests mutate `UserDefaults` directly (bypassing `WorkspaceState`), so the
    // in-memory locale cache must be invalidated when the language key is
    // restored — otherwise a stale cached locale leaks into later tests.
    if key == AppLanguage.storageKey {
        AppLanguage.refreshCachedLocale()
    }
}
