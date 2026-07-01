//
//  whitenoise_macTests.swift
//  whitenoise-macTests
//
//  Created by Jeff Gardner on 26/05/2026.
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

/// Reference-typed boolean so a `@Sendable`/`@MainActor` provider closure can capture an
/// immutable reference whose value the test flips later, without tripping the "mutated after
/// capture by sendable closure" diagnostic that a captured `var` would.
private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class BlockingFfiGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var semaphore: DispatchSemaphore?
    private var reached = false

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    var didReach: Bool {
        lock.withLock { reached }
    }

    func passIfArmed() {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            guard enabled, self.semaphore == nil, !reached else { return nil }
            reached = true
            let semaphore = DispatchSemaphore(value: 0)
            self.semaphore = semaphore
            return semaphore
        }
        semaphore?.wait()
    }

    func release() {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            let semaphore = self.semaphore
            self.semaphore = nil
            return semaphore
        }
        semaphore?.signal()
    }
}

private final class OneShotKeyProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let keyData: Data
    private var shouldBlock = true

    init(keyData: Data = Data(repeating: 0x42, count: 32)) {
        self.keyData = keyData
    }

    func symmetricKey() throws -> SymmetricKey {
        let shouldWait = lock.withLock {
            let value = shouldBlock
            shouldBlock = false
            return value
        }
        if shouldWait {
            reached.signal()
            release.wait()
        }
        return SymmetricKey(data: keyData)
    }

    func waitUntilReached() {
        reached.wait()
    }

    func releaseGate() {
        release.signal()
    }
}

private final class ObservationInvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    func markInvalidated() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        storedValue += 1
        let value = storedValue
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private struct TranscriptPerformanceRows: View {
    let messages: [MessageItem]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(messages) { message in
                ConversationMessageRow(
                    message: message,
                    isSelectable: false,
                    showsDebugMetadata: false,
                    onActivateSelection: { _ in }
                ) { _ in }
                .equatable()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(width: 760)
    }
}

@Suite(.serialized)
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
        let allAccountsRunning = state.accounts.allSatisfy { $0.isRunning }
        #expect(allAccountsRunning)
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
            signedOut: false,
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
            signedOut: false,
            running: false
        )
        runtime.createdAccount = secondary
        await state.signUp()

        #expect(runtime.startCallCount == 2)
        #expect(state.accounts.count == 2)
        let added = try #require(state.accounts.first { $0.accountIdHex == secondary.accountIdHex })
        #expect(added.isRunning == true)
        let allAccountsRunning = state.accounts.allSatisfy { $0.isRunning }
        #expect(allAccountsRunning)
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
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
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        RemoteImageLoader.shared.clearCache()
        defer { RemoteImageLoader.shared.clearCache() }
        let cacheKey = "removed-background-account-avatar"
        let imageData = try Self.testPNGData(width: 64, height: 64)
        let decoded = try #require(
            await RemoteImageLoader.shared.image(
                for: imageData,
                cacheKey: cacheKey,
                maxPixelSize: 32
            )
        )
        let cachedBeforeRemoval = try #require(
            await RemoteImageLoader.shared.image(
                for: Data([0x00]),
                cacheKey: cacheKey,
                maxPixelSize: 32
            )
        )
        #expect(cachedBeforeRemoval.nsImage === decoded.nsImage)

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        await state.removeAccount(backupAccount)

        #expect(runtime.removedAccountRefs == ["Backup Account"])
        #expect(state.accounts.map(\.id) == ["Desktop Account"])
        // Removing a background identity must not switch the active account.
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.chatsByAccount["Backup Account"] == nil)
        #expect(
            await RemoteImageLoader.shared.image(
                for: Data([0x00]),
                cacheKey: cacheKey,
                maxPixelSize: 32
            ) == nil
        )
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
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
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
            signedOut: false,
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
    @Test func deleteAllDataClearsAccountUnreadBadges() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        runtime.accountUnreadSummaryRows = [
            AccountUnreadFfi(
                accountIdHex: primary.accountIdHex,
                unreadCount: 7,
                unreadConversations: 1,
                hasUnread: true
            )
        ]
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: primary.accountIdHex) == 7)

        await state.deleteAllData()

        // The per-account unread cache must not survive a full local-data wipe. See #213.
        #expect(state.unreadCount(forAccountIdHex: primary.accountIdHex) == 0)
    }

    @MainActor
    @Test func resetActiveAccountUIStateClearsAccountUnreadBadges() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        runtime.accountUnreadSummaryRows = [
            AccountUnreadFfi(
                accountIdHex: primary.accountIdHex,
                unreadCount: 4,
                unreadConversations: 1,
                hasUnread: true
            )
        ]
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: primary.accountIdHex) == 4)

        state.resetActiveAccountUIState()

        // Sign-out and active-account removal share this reset path. See #213.
        #expect(state.unreadCount(forAccountIdHex: primary.accountIdHex) == 0)
    }

    @MainActor
    @Test func resetActiveAccountUIStateClearsReadMarkersAndDeliveredNotificationKeys() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        let marker = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageId: "m0"
        )
        state.lastMarkedReadMarkers["group-a"] = marker
        state.lastConfirmedReadMarkers["group-a"] = marker
        state.deliveredNotificationKeys.insert("notif-1")
        state.deliveredNotificationKeyOrder.append("notif-1")

        state.resetActiveAccountUIState()

        // Sign-out and active-account removal share this reset path; per-group read
        // markers and delivered-notification keys must not survive it. See #241.
        #expect(state.lastMarkedReadMarkers.isEmpty)
        #expect(state.lastConfirmedReadMarkers.isEmpty)
        #expect(state.deliveredNotificationKeys.isEmpty)
        #expect(state.deliveredNotificationKeyOrder.isEmpty)
    }

    @MainActor
    @Test func removeNonActiveAccountClearsItsUnreadBadge() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        runtime.accountUnreadSummaryRows = [
            AccountUnreadFfi(
                accountIdHex: primary.accountIdHex,
                unreadCount: 3,
                unreadConversations: 1,
                hasUnread: true
            ),
            AccountUnreadFfi(
                accountIdHex: secondary.accountIdHex,
                unreadCount: 5,
                unreadConversations: 1,
                hasUnread: true
            ),
        ]
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: secondary.accountIdHex) == 5)

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        await state.removeAccount(backupAccount)

        // Removing a background identity must drop its unread badge without
        // disturbing the surviving active account's count. See #213.
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.unreadCount(forAccountIdHex: secondary.accountIdHex) == 0)
        #expect(state.unreadCount(forAccountIdHex: primary.accountIdHex) == 3)
    }

    @Test func deleteAllLocalDataWipesStorageWhenAccountCleanupFails() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-delete-all-data-\(UUID().uuidString)", isDirectory: true)
        let secretFile = root.appendingPathComponent("private-identity.sqlite")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("private key material".utf8).write(to: secretFile)
        defer { try? fileManager.removeItem(at: root) }

        var removedRefs: [String] = []
        var didShutdown = false

        try await MarmotClient.deleteAllLocalData(
            listAccountRefs: { ["Desktop Account", "Relay-Failing Account", "Backup Account"] },
            removeAccount: { accountRef in
                removedRefs.append(accountRef)
                if accountRef == "Relay-Failing Account" {
                    throw FakeMarmotRuntimeError.unused
                }
            },
            shutdown: { didShutdown = true },
            rootPath: root.path,
            fileManager: fileManager
        )

        #expect(removedRefs == ["Desktop Account", "Relay-Failing Account", "Backup Account"])
        #expect(didShutdown)
        #expect(fileManager.fileExists(atPath: root.path))
        #expect(!fileManager.fileExists(atPath: secretFile.path))
        #expect(try fileManager.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func deleteAllLocalDataWipesStorageWhenAccountListingFails() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-delete-all-data-\(UUID().uuidString)", isDirectory: true)
        let secretFile = root.appendingPathComponent("mls-state.sqlite")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("mls group state".utf8).write(to: secretFile)
        defer { try? fileManager.removeItem(at: root) }

        var didAttemptRemove = false
        var didShutdown = false

        try await MarmotClient.deleteAllLocalData(
            listAccountRefs: { throw FakeMarmotRuntimeError.unused },
            removeAccount: { _ in didAttemptRemove = true },
            shutdown: { didShutdown = true },
            rootPath: root.path,
            fileManager: fileManager
        )

        #expect(!didAttemptRemove)
        #expect(didShutdown)
        #expect(fileManager.fileExists(atPath: root.path))
        #expect(!fileManager.fileExists(atPath: secretFile.path))
        #expect(try fileManager.contentsOfDirectory(atPath: root.path).isEmpty)
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

        let expectedRoot =
            sandbox
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

    @Test func mediaPlaybackTempStoreLivesInsideAppContainerNotSharedTemp() {
        let base = URL(fileURLWithPath: "/Container", isDirectory: true)
        let directory = MediaPlaybackTempStore.directoryURL(baseURL: base)

        #expect(
            directory.path == "/Container/White Noise/WhiteNoiseMediaPlayback"
        )
        #expect(!directory.path.contains(FileManager.default.temporaryDirectory.path))
    }

    @Test func mediaPlaybackTempStoreMaterializesIndependentConsumerFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let firstConsumer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondConsumer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let url = try MediaPlaybackTempStore.materialize(
            data: Data("secret".utf8),
            id: "attachment-id/with:illegal",
            fileName: "report.pdf",
            fallbackExtension: "bin",
            directory: directory,
            uniqueID: firstConsumer
        )

        #expect(fileManager.fileExists(atPath: url.path))
        #expect(url.lastPathComponent.hasSuffix("-report.pdf"))
        #expect(url.lastPathComponent.contains(firstConsumer.uuidString))
        #expect(url.deletingLastPathComponent().path == directory.path)

        // Re-materializing the same attachment for a later consumer must not reuse the
        // previous URL; an older cleanup timer could otherwise delete the later handoff.
        let again = try MediaPlaybackTempStore.materialize(
            data: Data("different".utf8),
            id: "attachment-id/with:illegal",
            fileName: "report.pdf",
            fallbackExtension: "bin",
            directory: directory,
            uniqueID: secondConsumer
        )
        #expect(again != url)
        #expect(again.lastPathComponent.contains(secondConsumer.uuidString))
        #expect(try Data(contentsOf: url) == Data("secret".utf8))
        #expect(try Data(contentsOf: again) == Data("different".utf8))
    }

    @Test func mediaPlaybackTempStoreUsesFullIdHashInStem() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let sharedPrefix = String(repeating: "a", count: 64)
        let firstID = "\(sharedPrefix)-one"
        let secondID = "\(sharedPrefix)-two"
        let firstStem = MediaPlaybackTempStore.stableStem(for: firstID)
        let secondStem = MediaPlaybackTempStore.stableStem(for: secondID)
        let first = try MediaPlaybackTempStore.materialize(
            data: Data("first".utf8),
            id: firstID,
            fileName: "report.pdf",
            fallbackExtension: "bin",
            directory: directory,
            uniqueID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        let second = try MediaPlaybackTempStore.materialize(
            data: Data("second".utf8),
            id: secondID,
            fileName: "report.pdf",
            fallbackExtension: "bin",
            directory: directory,
            uniqueID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )

        #expect(firstStem.prefix(32) == secondStem.prefix(32))
        #expect(firstStem != secondStem)
        #expect(first.lastPathComponent.hasPrefix("\(firstStem)-"))
        #expect(second.lastPathComponent.hasPrefix("\(secondStem)-"))
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test func mediaPlaybackTempStoreExcludesScratchDirectoryFromBackups() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        _ = try MediaPlaybackTempStore.materialize(
            data: Data("secret".utf8),
            id: "attachment",
            fileName: "report.pdf",
            fallbackExtension: "bin",
            directory: directory
        )

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func mediaPlaybackTempStoreRemovesSingleFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let url = try MediaPlaybackTempStore.materialize(
            data: Data("bytes".utf8),
            id: "video",
            fileName: "clip.mp4",
            fallbackExtension: "mp4",
            directory: directory
        )
        #expect(fileManager.fileExists(atPath: url.path))

        MediaPlaybackTempStore.remove(at: url)
        #expect(!fileManager.fileExists(atPath: url.path))

        // Removing a missing file is a no-op.
        MediaPlaybackTempStore.remove(at: url)
        #expect(!fileManager.fileExists(atPath: url.path))
    }

    @Test func mediaPlaybackTempStorePurgesDirectory() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        _ = try MediaPlaybackTempStore.materialize(
            data: Data("a".utf8),
            id: "one",
            fileName: "a.txt",
            fallbackExtension: "txt",
            directory: directory
        )
        _ = try MediaPlaybackTempStore.materialize(
            data: Data("b".utf8),
            id: "two",
            fileName: "b.txt",
            fallbackExtension: "txt",
            directory: directory
        )
        #expect(fileManager.fileExists(atPath: directory.path))

        let legacyDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-legacy-playback-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDirectory.appendingPathComponent("old-video.mp4"))
        defer { try? fileManager.removeItem(at: legacyDirectory) }

        MediaPlaybackTempStore.purge(directory: directory, legacyDirectory: legacyDirectory)
        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(!fileManager.fileExists(atPath: legacyDirectory.path))

        // Purging a missing directory is a no-op.
        MediaPlaybackTempStore.purge(directory: directory, legacyDirectory: legacyDirectory)
        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(!fileManager.fileExists(atPath: legacyDirectory.path))
    }

    @Test func messageMediaDiskCacheRoundTripsEncryptedPayload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("durable cached media bytes".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "photo.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        await cache.store(download, for: key)

        let restored = try #require(await cache.cachedDownload(for: key))
        #expect(restored.data == plaintext)
        #expect(restored.fileName == "photo.png")
        #expect(restored.mediaType == "image/png")
        #expect(restored.sizeBytes == UInt64(plaintext.count))
        #expect(restored.payload.id == key.payloadID)

        let cacheFiles = try fileManager.subpathsOfDirectory(atPath: root.path)
        #expect(cacheFiles.contains { $0.hasSuffix("metadata.bin") })
        #expect(cacheFiles.contains { $0.hasSuffix("payload.bin") })
        for relativePath in cacheFiles where relativePath.hasSuffix(".bin") {
            let bytes = try Data(contentsOf: root.appendingPathComponent(relativePath))
            #expect(!dataContains(bytes, plaintext))
        }
    }

    @Test func messageMediaDiskCacheEvictsCorruptEntries() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("media that will be corrupted".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        await cache.store(download, for: key)
        let entryDirectory = try #require(cache.entryDirectory(for: key))
        try Data("not a sealed payload".utf8).write(to: entryDirectory.appendingPathComponent("payload.bin"))

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(!fileManager.fileExists(atPath: entryDirectory.path))
    }

    @Test func messageMediaDiskCachePurgesByAccountAndFullWipeDeletesKey() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let didDeleteKey = MutableFlag(false)
        let cache = messageMediaDiskCache(root: root) {
            didDeleteKey.value = true
        }
        let firstPlaintext = Data("first account media".utf8)
        let secondPlaintext = Data("second account media".utf8)
        let firstKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: firstPlaintext, ciphertextByte: 0xaa)
        )
        let secondKey = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: secondPlaintext, ciphertextByte: 0xbb)
        )

        await cache.store(
            MessageMediaDownload(
                data: firstPlaintext,
                fileName: "a.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(firstPlaintext.count),
                payloadId: "first"
            ),
            for: firstKey
        )
        await cache.store(
            MessageMediaDownload(
                data: secondPlaintext,
                fileName: "b.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(secondPlaintext.count),
                payloadId: "second"
            ),
            for: secondKey
        )

        await cache.purgeAccount("account-a")
        #expect(await cache.cachedDownload(for: firstKey) == nil)
        #expect(try #require(await cache.cachedDownload(for: secondKey)).data == secondPlaintext)

        await cache.purgeAll(removeEncryptionKey: true)
        #expect(await cache.cachedDownload(for: secondKey) == nil)
        #expect(didDeleteKey.value)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @Test func messageMediaDiskCacheRejectsDirectStoreDuringFullWipe() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderCalls = AtomicCounter()
        let deleterEntered = DispatchSemaphore(value: 0)
        let releaseDeleter = DispatchSemaphore(value: 0)
        let cache = MessageMediaDiskCache(
            directoryResolver: { root },
            keyProvider: {
                keyProviderCalls.increment()
                return SymmetricKey(data: Data(repeating: 0x42, count: 32))
            },
            keyDeleter: {
                deleterEntered.signal()
                _ = releaseDeleter.wait(timeout: .now() + 5)
            }
        )
        let plaintext = Data("store racing full wipe".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "race.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        let purge = Task {
            await cache.purgeAll(removeEncryptionKey: true)
        }
        #expect(deleterEntered.wait(timeout: .now() + 2) == .success)

        await cache.store(download, for: key)
        #expect(keyProviderCalls.value == 0)
        #expect(!fileManager.fileExists(atPath: root.path))

        releaseDeleter.signal()
        await purge.value
        #expect(keyProviderCalls.value == 0)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @MainActor
    @Test func chatSearchMatchesTitleSubtitleAndPreview() async throws {
        let chats = ChatItem.samples

        #expect(ChatFilter.filtered(chats, query: "relay").map(\.id) == ["chat-relays"])
        #expect(ChatFilter.filtered(chats, query: "desktop").map(\.id) == ["chat-design"])
        #expect(ChatFilter.filtered(chats, query: "direct").map(\.id) == ["chat-nvk"])

        // A query is matched against each field independently and never across
        // field boundaries, so "NVK Direct" does not match the chat whose title
        // is "NVK" and subtitle is "Direct message".
        #expect(ChatFilter.filtered(chats, query: "NVK Direct").isEmpty)
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
    @Test func localizedStringUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        #expect(L10n.string("Save") == "Guardar")
    }

    @MainActor
    @Test func localizedStringBundleCacheInvalidatesOnLanguageChange() async throws {
        // Regression for the residual half of #28 (#117): `L10n.string` caches the
        // resolved `.lproj` bundle to avoid a per-call filesystem stat + `Bundle`
        // allocation. The cache must be invalidated by `refreshCachedLocale()` when
        // the language preference changes, otherwise a stale bundle keeps serving
        // the previous language. Switch between two non-source languages and assert
        // each read reflects the current preference.
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        // Prime the cache while Spanish is selected.
        #expect(L10n.string("Save") == "Guardar")

        UserDefaults.standard.set(AppLanguage.german.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        // The cache must have been cleared, so this resolves the German bundle.
        #expect(L10n.string("Save") == "Speichern")

        // And back again, confirming the cache tracks the preference in both directions.
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        #expect(L10n.string("Save") == "Guardar")
    }

    @MainActor
    @Test func systemLocaleChangeInvalidatesLocalizedStringCacheWhenPreferenceIsSystem() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer {
            AppLanguage.setSystemLocaleOverrideForTesting(nil)
            restoreDefault(previousLanguage, forKey: AppLanguage.storageKey)
        }

        UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
        AppLanguage.setSystemLocaleOverrideForTesting(Locale(identifier: AppLanguage.spanish.rawValue))
        AppLanguage.refreshCachedLocale()
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        // Prime the system-preference cache while the effective system language is Spanish.
        #expect(L10n.string("Save") == "Guardar")

        state.refreshSystemLanguageIfNeeded()
        #expect(state.systemLocaleRefreshRevision == 0)

        AppLanguage.setSystemLocaleOverrideForTesting(Locale(identifier: AppLanguage.german.rawValue))

        state.refreshSystemLanguageIfNeeded()

        #expect(L10n.string("Save") == "Speichern")
        #expect(state.systemLocaleRefreshRevision == 1)
    }

    @MainActor
    @Test func systemLocaleChangeDoesNotOverrideSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer {
            AppLanguage.setSystemLocaleOverrideForTesting(nil)
            restoreDefault(previousLanguage, forKey: AppLanguage.storageKey)
        }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.setSystemLocaleOverrideForTesting(Locale(identifier: AppLanguage.german.rawValue))
        AppLanguage.refreshCachedLocale()
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })

        state.refreshSystemLanguageIfNeeded()

        #expect(state.languagePreference == .spanish)
        #expect(L10n.string("Save") == "Guardar")
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
            updatedAt: projectionRefreshedAt
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
            updatedAt: 1_700_000_000
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.pendingConfirmation)
        #expect(chat.subtitle == "Planning")
        #expect(chat.preview == "Alice: Welcome in")
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
    @Test func messageItemEqualityAndHashingIgnoreDerivedMarkdownAST() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let plain = MessageItem(
            id: "m1",
            senderName: "Alice",
            body: "Hello",
            contentMarkdown: nil,
            sentAt: sentAt,
            isOutgoing: false
        )
        let withMarkdown = MessageItem(
            id: "m1",
            senderName: "Alice",
            body: "Hello",
            contentMarkdown: MarkdownDocumentFfi(
                blocks: [.paragraph(inlines: [.text(content: "Hello")])],
                truncated: false
            ),
            sentAt: sentAt,
            isOutgoing: false
        )
        // `contentMarkdown` is a deterministic projection of the content-bearing fields,
        // so it is intentionally excluded from equality/hashing to keep timeline diffing
        // off the recursive AST. Items agreeing on those fields are equal regardless.
        #expect(plain == withMarkdown)
        #expect(plain.hashValue == withMarkdown.hashValue)

        let differentBody = MessageItem(
            id: "m1",
            senderName: "Alice",
            body: "Goodbye",
            sentAt: sentAt,
            isOutgoing: false
        )
        #expect(plain != differentBody)

        let differentSender = MessageItem(
            id: "m1",
            senderName: "Bob",
            body: "Hello",
            sentAt: sentAt,
            isOutgoing: false
        )
        #expect(plain != differentSender)
    }

    @MainActor
    @Test func markdownPlainTextFastPathKeepsEscapedAndPlaceholderContentCorrect() async throws {
        let plainTokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.text(content: "Hello")])],
            truncated: false
        )
        let escapedTokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.text(content: "*")])],
            truncated: false
        )
        let richTokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.strong(children: [.text(content: "Failed")])])],
            truncated: false
        )
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "plain",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Hello",
                    recordedAt: 1_800_000_000,
                    contentTokens: plainTokens
                ),
                timelineMessage(
                    id: "escaped",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "\\*",
                    recordedAt: 1_800_000_001,
                    contentTokens: escapedTokens
                ),
                timelineMessage(
                    id: "failed",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "**Failed**",
                    recordedAt: 1_800_000_002,
                    contentTokens: richTokens,
                    invalidationStatus: "signature-check-failed"
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages[0].body == "Hello")
        #expect(messages[0].contentMarkdown == nil)
        #expect(messages[1].body == "\\*")
        #expect(messages[1].contentMarkdown != nil)
        #expect(messages[2].body == "Message did not reach the group")
        #expect(messages[2].contentMarkdown == nil)
    }

    @MainActor
    @Test func deeplyNestedMarkdownBlocksCollapseInsteadOfRecursing() async throws {
        // Regression for whitenoise-mac#231: contentTokens is parsed from untrusted peer
        // content. A block quote nested far beyond the Swift-side depth bound must collapse
        // the over-depth remainder to empty display rather than recursing the full attacker
        // chain (which can overflow the stack).
        let document = MarkdownDocumentFfi(
            blocks: [nestedBlockQuote(depth: 256, leaf: .paragraph(inlines: [.text(content: "deep")]))],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        // The display tree stops nesting at the bound, so the deepest preserved quote holds
        // no further blocks instead of the attacker's remaining 200+ levels.
        let preservedDepth = blockQuoteNestingDepth(display.blocks)
        #expect(preservedDepth <= 32)
        #expect(preservedDepth >= 1)
    }

    @MainActor
    @Test func deeplyNestedMarkdownInlinesCollapseInsteadOfRecursing() async throws {
        // Inline emphasis/strong/strikethrough/link/image-alt recurse proportionally to
        // attacker-chosen nesting. Past the bound the inline subtree must collapse to empty
        // safe display rather than recursing the full chain.
        let document = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [nestedStrong(depth: 256, leaf: .text(content: "deep"))])],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        guard case .paragraph(let text) = display.blocks.first?.block else {
            Issue.record("expected a paragraph block")
            return
        }
        // The leaf text sits below the bound, so it is dropped entirely rather than the
        // renderer recursing through every wrapper to reach it.
        #expect(String(text.characters).isEmpty)
    }

    @MainActor
    @Test func boundedNestedMarkdownStillStylesAndLinks() async throws {
        // Normal Markdown nesting (well within the bound) must keep its styles and links:
        // the depth guard only collapses the over-depth remainder.
        let document = MarkdownDocumentFfi(
            blocks: [
                nestedBlockQuote(
                    depth: 3,
                    leaf: .paragraph(inlines: [
                        .strong(children: [
                            .link(
                                dest: "https://example.com",
                                title: nil,
                                children: [.text(content: "link text")]
                            )
                        ])
                    ])
                )
            ],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        guard let paragraph = firstParagraph(in: display.blocks) else {
            Issue.record("expected a nested paragraph block")
            return
        }
        #expect(String(paragraph.characters) == "link text")
        let run = paragraph.runs.first
        #expect(run?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(run?.link == URL(string: "https://example.com"))
    }

    @MainActor
    @Test func transcriptRowStackLayoutPerformanceGuard() async throws {
        let messages = performanceMessageItems(count: 160)
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        let warmHost = NSHostingView(rootView: TranscriptPerformanceRows(messages: messages).environment(state))
        warmHost.frame = NSRect(x: 0, y: 0, width: 760, height: 9_000)
        let warmSize = warmHost.fittingSize
        #expect(warmSize.height > 1_000)

        var accumulatedHeight: CGFloat = 0
        let layoutMilliseconds = measuredMilliseconds {
            for _ in 0..<3 {
                let host = NSHostingView(rootView: TranscriptPerformanceRows(messages: messages).environment(state))
                host.frame = NSRect(x: 0, y: 0, width: 760, height: 9_000)
                host.invalidateIntrinsicContentSize()
                accumulatedHeight += host.fittingSize.height
            }
        }

        #expect(accumulatedHeight > 3_000)
        print("PERF transcript_row_stack_layout_ms=\(formatMilliseconds(layoutMilliseconds)) rows=\(messages.count)")
        #expect(layoutMilliseconds < 4_000 * performanceSlack)
    }

    @MainActor
    @Test func timelineStoreProjectionApplyPerformanceGuard() async throws {
        let messages = performanceMessageItems(count: 200)
        let store = MessageTimelineStore.loaded(with: messages)
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

        let projectionMilliseconds = measuredMilliseconds {
            for index in 0..<2_000 {
                let messageIndex = index % messages.count
                let updated = MessageItem(
                    id: "perf-\(messageIndex)",
                    groupIdHex: "perf-group",
                    senderAccountIdHex: messageIndex.isMultiple(of: 2) ? "self" : "alice",
                    senderName: messageIndex.isMultiple(of: 2) ? "Jeff" : "Alice",
                    body: "Edited projection body \(index)",
                    contentMarkdown: nil,
                    sentAt: sentAt.addingTimeInterval(TimeInterval(messageIndex)),
                    timelineAt: UInt64(1_800_000_000 + messageIndex),
                    isOutgoing: messageIndex.isMultiple(of: 2)
                )
                _ = store.applyProjection(
                    upserts: [updated],
                    removals: [],
                    anchoredToNewest: true,
                    windowLimit: WorkspaceState.timelineWindowLimit
                )
            }
        }

        print("PERF timeline_projection_apply_ms=\(formatMilliseconds(projectionMilliseconds)) updates=2000")
        #expect(store.messageIDs.count == 200)
        #expect(store.messages[199].body == "Edited projection body 1999")
        #expect(projectionMilliseconds < 1_500 * performanceSlack)
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
                        MessageTagFfi(values: ["route", "quic"]),
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
                    plaintext:
                        #"{"v":1,"event_type":"tool_call","status":"started","name":"search","preview":"glp-1"}"#,
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
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: "self"
        )

        #expect(
            messages.map(\.presentation) == [
                .agentStreamStart,
                .agentActivity,
                .agentOperation,
                .groupSystem,
            ])
        #expect(
            messages.map(\.body) == [
                "Agent started a live response",
                "Thinking",
                "glp-1",
                "Group renamed",
            ])
        #expect(messages.allSatisfy { !$0.supportsChatActions })
        #expect(messages.allSatisfy { $0.statusLabel == nil })
    }

    @MainActor
    @Test func mediaOnlyTimelineMessageMapsAttachmentWithoutUnsupportedText() async throws {
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "media-message",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(for: reference)
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.presentation == .chat)
        #expect(message.body.isEmpty)
        #expect(message.replyPreviewText == "Photo")
        #expect(message.mediaAttachments.count == 1)
        #expect(message.mediaAttachments.first?.reference.plaintextSha256 == reference.plaintextSha256)
        #expect(message.canReply)
        #expect(!message.canCopyText)
    }

    @MainActor
    @Test func mediaOnlyChatPreviewShowsAttachmentLabelInsteadOfUnsupported() async throws {
        // Regression for whitenoise-mac#175: `ChatListMessagePreviewFfi` carries no media
        // payload, so a media-only chat message arrives with empty plaintext. The chat-list
        // preview must fall back to "Attachment" rather than "Unsupported message".
        let directRow = ChatListRowFfi(
            groupIdHex: "direct-group",
            archived: false,
            pendingConfirmation: false,
            title: "Alice",
            groupName: "",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "media-preview",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "",
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
            updatedAt: 1_700_000_000
        )

        let directChat = ChatItem(row: directRow, activeAccountIdHex: "self")
        #expect(directChat.preview == "Attachment")

        let groupRow = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "media-preview",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "",
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
            updatedAt: 1_700_000_000
        )

        let groupChat = ChatItem(row: groupRow, activeAccountIdHex: "self")
        #expect(groupChat.preview == "Attachment")
    }

    @MainActor
    @Test func literalUnsupportedChatPreviewPreservesMessageText() async throws {
        // A valid chat body can equal the localized unsupported-message label. That
        // literal text must not be mistaken for the empty media-only preview sentinel.
        let literalText = L10n.string("Unsupported message")
        let row = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: literalText,
            sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
            timelineAt: 1_700_000_001
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")
        #expect(chat.preview == literalText)
    }

    @MainActor
    @Test func imetaInsideJSONReadsSourceEpochInBothSpellings() async throws {
        // Regression for whitenoise-mac#137: the imeta-within-object branch must
        // accept both snake_case `source_epoch` and camelCase `sourceEpoch` so a
        // camelCase payload does not silently default the epoch to 0.
        let reference = mediaAttachmentReference(sourceEpoch: 7, mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "snake-epoch",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(for: reference, sourceEpochKey: "source_epoch")
                ),
                timelineMessage(
                    id: "camel-epoch",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_001,
                    mediaJson: mediaJson(for: reference, sourceEpochKey: "sourceEpoch")
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.mediaAttachments.first?.reference.sourceEpoch == 7 })
    }

    @MainActor
    @Test func imetaBlurhashFieldDoesNotDropAttachment() async throws {
        // Regression for whitenoise-mac#208: `blurhash` is a standard optional NIP-92
        // imeta field. The macOS client does not consume it, but its presence must not
        // make the local-parse fallback discard the whole media attachment.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "blurhash-imeta",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(
                        for: reference,
                        appendingIMetaField: "blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj"
                    )
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(message.mediaAttachments.first?.reference.fileName == reference.fileName)
        #expect(message.mediaAttachments.first?.reference.thumbhash == nil)
    }

    @MainActor
    @Test func invalidNumericSourceEpochFallsBackToZeroInsteadOfWrapping() async throws {
        // Regression for whitenoise-mac#179: a peer-controlled `source_epoch` is the MLS
        // decryption epoch, so a negative (`-1` would wrap to `UInt64.max`), fractional
        // (`3.9` would truncate to `3`), out-of-range (`1e30` would saturate), or boolean
        // (`true` would parse as `1`) JSON value must be rejected by `unsignedInteger(_:)`
        // instead of flowing through as a garbage epoch. Rejected values default the parsed
        // attachment epoch to 0, matching `nil` from `unsignedInteger`.
        let reference = mediaAttachmentReference(sourceEpoch: 0, mediaType: "image/png", fileName: "photo.png")
        let invalidEpochs: [NSNumber] = [
            NSNumber(value: -1),
            NSNumber(value: 3.9),
            NSNumber(value: 1e30),
            NSNumber(value: true),
            NSNumber(value: false),
        ]
        let page = TimelinePageFfi(
            messages: invalidEpochs.enumerated().flatMap { index, rawEpoch in
                ["source_epoch", "sourceEpoch"].enumerated().map { keyIndex, key in
                    timelineMessage(
                        id: "invalid-epoch-\(index)-\(keyIndex)",
                        groupIdHex: "group",
                        sender: "alice",
                        plaintext: "",
                        recordedAt: 1_700_000_000 + UInt64(index * 2 + keyIndex),
                        mediaJson: mediaJson(for: reference, sourceEpochKey: key, rawSourceEpoch: rawEpoch)
                    )
                }
            },
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == invalidEpochs.count * 2)
        #expect(messages.allSatisfy { $0.mediaAttachments.count == 1 })
        #expect(messages.allSatisfy { $0.mediaAttachments.first?.reference.sourceEpoch == 0 })
    }

    @MainActor
    @Test func mediaJSONObjectWithIMetaAndFlatKeysMapsSingleAttachment() async throws {
        // Regression for whitenoise-mac#185: a single peer-controlled object carrying
        // both an `imeta` array and the flat direct-reference keys must not emit both the
        // imeta-derived reference and a separate direct reference for the same logical
        // attachment. Object branches are mutually exclusive (`imeta`, else `media`, else
        // flat), so the object maps to exactly one attachment instead of rendering twice.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "imeta-and-flat",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJsonWithIMetaAndFlatKeys(for: reference)
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(message.mediaAttachments.first?.reference.plaintextSha256 == reference.plaintextSha256)
        #expect(message.mediaAttachments.first?.reference.fileName == reference.fileName)
    }

    @Test func mediaGridPresentationUsesSquareFourTileLayout() {
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 6) == 4)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 6) == 2)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.tileSide(totalCount: 1, maxWidth: 360, spacing: 3) == 360)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 1, maxWidth: 360, spacing: 3) == 360)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 4) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 4) == 2)
        #expect(MessageMediaGridPresentation.tileSide(totalCount: 4, maxWidth: 360, spacing: 3) == 178.5)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 4, maxWidth: 360, spacing: 3) == 360)
    }

    @MainActor
    @Test func messageItemPrecomputesBubbleRenderContent() async throws {
        let image = MessageMediaAttachment(
            id: "image",
            reference: mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        )
        let audio = MessageMediaAttachment(
            id: "audio",
            reference: mediaAttachmentReference(mediaType: "audio/mp4", fileName: "clip.m4a")
        )
        let video = MessageMediaAttachment(
            id: "video",
            reference: mediaAttachmentReference(mediaType: "video/mp4", fileName: "clip.mp4")
        )
        let file = MessageMediaAttachment(
            id: "file",
            reference: mediaAttachmentReference(mediaType: "application/pdf", fileName: "notes.pdf")
        )
        let replyContext = MessageReplyContext(
            targetMessageId: "parent",
            senderName: "Alice",
            body: "Earlier note"
        )

        let message = MessageItem(
            id: "mixed-media",
            senderName: "Bob",
            body: "  Render once  ",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: false,
            replyContext: replyContext,
            mediaAttachments: [image, audio, video, file]
        )

        #expect(message.trimmedBody == "Render once")
        #expect(message.hasBubbleContent)
        #expect(message.visualMediaAttachments.map(\.id) == ["image", "video"])
        #expect(message.nonvisualMediaAttachments.map(\.id) == ["audio", "file"])

        let attachmentOnly = MessageItem(
            id: "attachment-only",
            senderName: "Bob",
            body: "  \n  ",
            sentAt: Date(timeIntervalSince1970: 1_800_000_001),
            isOutgoing: false,
            mediaAttachments: [image]
        )
        #expect(attachmentOnly.trimmedBody.isEmpty)
        #expect(!attachmentOnly.hasBubbleContent)
        #expect(attachmentOnly.replyPreviewText == "Photo")
        #expect(!attachmentOnly.canCopyText)
    }

    @Test func pendingMediaAttachmentDurationLabelFormatsSubhourHourBoundaryAndClampsNegative() {
        let longAttachment = PendingMediaAttachment(
            fileName: "long.m4a",
            mediaType: "audio/mp4",
            data: Data(),
            dim: nil,
            durationSeconds: 4_500.9
        )
        let shortAttachment = PendingMediaAttachment(
            fileName: "short.m4a",
            mediaType: "audio/mp4",
            data: Data(),
            dim: nil,
            durationSeconds: 65.9
        )
        let negativeAttachment = PendingMediaAttachment(
            fileName: "negative.m4a",
            mediaType: "audio/mp4",
            data: Data(),
            dim: nil,
            durationSeconds: -2
        )

        #expect(longAttachment.durationLabel == "1:15:00")
        #expect(shortAttachment.durationLabel == "1:05")
        #expect(negativeAttachment.durationLabel == "0:00")
        #expect(MediaDurationLabel.string(for: 3_599) == "59:59")
        #expect(MediaDurationLabel.string(for: 3_600) == "1:00:00")
    }

    @MainActor
    @Test func deeplyNestedMediaJSONDoesNotProduceAttachments() async throws {
        // Regression for whitenoise-mac#120: mediaJson is decrypted peer content.
        // Overly deep objects/arrays must be ignored instead of recursively walking
        // attacker-controlled nesting on the timeline mapping path.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "nested.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "deep-media-objects",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(for: reference, mediaObjectDepth: 40)
                ),
                timelineMessage(
                    id: "deep-media-arrays",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_001,
                    mediaJson: mediaJson(for: reference, arrayDepth: 40)
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.mediaAttachments.isEmpty })
        #expect(messages.allSatisfy { $0.body == "Unsupported message" })
    }

    @MainActor
    @Test func boundedNestedMediaJSONStillProducesAttachments() async throws {
        // Base helper shape is object + imeta array + tag array, so 29 wrappers
        // reaches the current raw nesting limit of 32 without exceeding it.
        let reference = mediaAttachmentReference(
            mediaType: "image/png",
            fileName: "bounded-[literal-{brackets}].png"
        )
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "bounded-media-objects",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_002,
                    mediaJson: mediaJson(for: reference, mediaObjectDepth: 29)
                ),
                timelineMessage(
                    id: "bounded-media-arrays",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_003,
                    mediaJson: mediaJson(for: reference, arrayDepth: 29)
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.body.isEmpty })
        #expect(messages.allSatisfy { $0.mediaAttachments.count == 1 })
        #expect(messages.allSatisfy { $0.mediaAttachments.first?.reference.fileName == reference.fileName })
    }

    @MainActor
    @Test func workspaceDownloadsMediaAttachmentAndCachesResult() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: false
        )
        let timelineReference = mediaAttachmentReference(sourceEpoch: 0, mediaType: "audio/mp4", fileName: "voice.m4a")
        let fullReference = mediaAttachmentReference(sourceEpoch: 7, mediaType: "audio/mp4", fileName: "voice.m4a")
        let download = MediaDownloadResultFfi(
            plaintext: Data([0x00, 0x01, 0x02, 0x03]),
            fileName: "voice.m4a",
            mediaType: "audio/mp4",
            sizeBytes: 4
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: fullReference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: download
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.selectChat(
            ChatItem(
                id: "group",
                title: "Test Group",
                subtitle: "Group message",
                preview: "Attachment",
                updatedAt: nil,
                avatarSeed: "group",
                pictureURL: nil,
                unreadCount: 0
            ))
        let message = MessageItem(
            id: "media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "media-message#0#\(timelineReference.plaintextSha256)",
                    reference: timelineReference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)

        await state.loadMediaAttachment(attachment, for: message)
        let stateAfterFirstLoad = state.mediaDownloadState(for: message, attachment: attachment)

        guard case .loaded(let loaded) = stateAfterFirstLoad else {
            Issue.record("Expected media download to load")
            return
        }
        #expect(loaded.data == download.plaintext)
        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)

        await state.loadMediaAttachment(attachment, for: message)

        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)
    }

    @MainActor
    @Test func workspaceLoadsMediaAttachmentFromDurableCacheWithoutRuntimeDownload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0x10, 0x20, 0x30, 0x40])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "cached.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let mediaDiskCache = messageMediaDiskCache(root: root)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: AccountItem(summary: account).id,
            groupIdHex: "group",
            reference: reference
        )
        await mediaDiskCache.store(
            MessageMediaDownload(
                data: plaintext,
                fileName: "cached.png",
                mediaType: "image/png",
                sizeBytes: UInt64(plaintext.count),
                payloadId: "preseeded"
            ),
            for: cacheKey
        )

        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(
            mediaDiskCache: mediaDiskCache,
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let message = MessageItem(
            id: "media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "media-message#0#\(reference.plaintextSha256)",
                    reference: reference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)

        await state.loadMediaAttachment(attachment, for: message)

        guard case .loaded(let loaded) = state.mediaDownloadState(for: message, attachment: attachment) else {
            Issue.record("Expected cached media download to load")
            return
        }
        #expect(loaded.data == plaintext)
        #expect(loaded.payload.id == cacheKey.payloadID)
        #expect(runtime.listMediaCallCount == 0)
        #expect(runtime.downloadMediaCallCount == 0)
    }

    @MainActor
    @Test func mediaDownloadFinishingAfterDeleteAllDataDoesNotRecreateDiskCache() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0xde, 0xad, 0xbe, 0xef])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "late.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let download = MediaDownloadResultFfi(
            plaintext: plaintext,
            fileName: "late.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count)
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "late-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: reference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: download
        )
        let mediaDiskCache = messageMediaDiskCache(root: root)
        let state = WorkspaceState(
            mediaDiskCache: mediaDiskCache,
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let message = MessageItem(
            id: "late-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "late-media-message#0#\(reference.plaintextSha256)",
                    reference: reference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        let stateStore = state.mediaDownloadStateStore(for: message, attachment: attachment)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: AccountItem(summary: account).id,
            groupIdHex: "group",
            reference: reference
        )

        runtime.mediaDownloadGateEnabled = true
        async let load: Void = state.loadMediaAttachment(attachment, for: message)
        while !runtime.didReachMediaDownloadGate {
            await Task.yield()
        }

        await state.deleteAllData()
        #expect(!fileManager.fileExists(atPath: root.path))

        runtime.releaseMediaDownloadGate()
        await load
        for _ in 0..<20 where !state.mediaDiskStoreTasks.isEmpty {
            await Task.yield()
        }

        #expect(state.mediaDiskStoreTasks.isEmpty)
        if case .loaded = stateStore.state {
            Issue.record("Late download should not update loaded state after deleteAllData()")
        }
        #expect(await mediaDiskCache.cachedDownload(for: cacheKey) == nil)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @Test func messageMediaDiskCacheCancelledStoreDoesNotCommitAfterKeyProviderReturns() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderGate = OneShotKeyProviderGate()
        let cache = MessageMediaDiskCache(
            directoryResolver: { root },
            keyProvider: keyProviderGate.symmetricKey,
            keyDeleter: {}
        )
        let plaintext = Data("late store should not commit".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "late.bin",
            mediaType: "application/octet-stream",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "late-store"
        )

        let storeTask = Task {
            await cache.store(download, for: key)
        }
        await Task.detached {
            keyProviderGate.waitUntilReached()
        }.value
        storeTask.cancel()
        keyProviderGate.releaseGate()
        await storeTask.value

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @Test func messageAudioMetadataCacheCoalescesAndCachesPayloadAnalysis() async throws {
        let analysisCount = AtomicCounter()
        let expected = MediaWaveformAnalyzer.Metadata(
            durationSeconds: 12.5,
            samples: Array(repeating: 0.42, count: MediaWaveformAnalyzer.sampleCount)
        )
        let cache = MessageAudioMetadataCache(entryLimit: 4) { _, _ in
            analysisCount.increment()
            Thread.sleep(forTimeInterval: 0.02)
            return expected
        }
        let payload = DownloadedMediaPayload(id: "audio-payload", data: Data(repeating: 0x7f, count: 1024))

        async let first = cache.metadata(for: payload, mediaType: "audio/mp4")
        async let second = cache.metadata(for: payload, mediaType: "audio/mp4")
        async let third = cache.metadata(for: payload, mediaType: "audio/mp4")

        let values = await [first, second, third]

        #expect(values == [expected, expected, expected])
        #expect(analysisCount.value == 1)
        #expect(await cache.metadata(for: payload, mediaType: "audio/mp4") == expected)
        #expect(analysisCount.value == 1)
    }

    @Test func messageMediaDownloadDetailTextPerformanceGuard() {
        let download = MessageMediaDownload(
            data: Data(repeating: 0x52, count: 8 * 1024 * 1024),
            fileName: "image.png",
            mediaType: "image/png",
            sizeBytes: 8 * 1024 * 1024,
            payloadId: "detail-performance"
        )
        var cachedTotal = 0
        var repeatedFormatterTotal = 0

        let cachedMilliseconds = measuredMilliseconds {
            for _ in 0..<100_000 {
                cachedTotal += download.detailText(fallbackMediaType: "image/png").count
            }
        }

        let repeatedFormatterMilliseconds = measuredMilliseconds {
            for _ in 0..<100_000 {
                let size = ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: download.sizeBytes),
                    countStyle: .file
                )
                repeatedFormatterTotal += "\(download.mediaType) - \(size)".count
            }
        }

        print(
            """
            PERF media_detail_cached_ms=\(formatMilliseconds(cachedMilliseconds)) \
            repeated_formatter_ms=\(formatMilliseconds(repeatedFormatterMilliseconds)) calls=100000
            """
        )
        #expect(cachedTotal == repeatedFormatterTotal)
        #expect(cachedMilliseconds < repeatedFormatterMilliseconds)
    }

    @MainActor
    @Test func mediaDownloadStateStoreAutoloadGateStartsOnlyFromIdle() {
        let store = MediaDownloadStateStore()
        let download = MessageMediaDownload(
            data: Data([0x01, 0x02, 0x03]),
            fileName: "image.png",
            mediaType: "image/png",
            sizeBytes: 3,
            payloadId: "autoload-gate"
        )

        #expect(store.shouldStartAutomaticDownload)
        store.update(.loading)
        #expect(!store.shouldStartAutomaticDownload)
        store.update(.loaded(download))
        #expect(!store.shouldStartAutomaticDownload)
        store.update(.failed("boom"))
        #expect(!store.shouldStartAutomaticDownload)
        store.update(.idle)
        #expect(store.shouldStartAutomaticDownload)
    }

    @Test func messageAudioMetadataCacheHitPerformanceGuard() async throws {
        let analysisCount = AtomicCounter()
        let expected = MediaWaveformAnalyzer.Metadata(
            durationSeconds: 3,
            samples: Array(repeating: 0.5, count: MediaWaveformAnalyzer.sampleCount)
        )
        let cache = MessageAudioMetadataCache(entryLimit: 4) { _, _ in
            analysisCount.increment()
            return expected
        }
        let payload = DownloadedMediaPayload(id: "audio-cache-hit", data: Data(repeating: 0x41, count: 8 * 1024 * 1024))

        #expect(await cache.metadata(for: payload, mediaType: "audio/mp4") == expected)
        let hitMilliseconds = await measuredMillisecondsAsync {
            for _ in 0..<5_000 {
                _ = await cache.metadata(for: payload, mediaType: "audio/mp4")
            }
        }

        print("PERF audio_metadata_cache_hit_ms=\(formatMilliseconds(hitMilliseconds)) hits=5000")
        #expect(analysisCount.value == 1)
        #expect(hitMilliseconds < 60 * performanceSlack)
    }

    @MainActor
    @Test func mediaDownloadStateStoresDoNotInvalidateWorkspaceObservationForUnrelatedDownloads() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: false
        )
        let firstReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "first.png",
            ciphertextSha256: String(repeating: "1", count: 64),
            plaintextSha256: String(repeating: "2", count: 64)
        )
        let firstDownloadReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "first.png",
            ciphertextSha256: firstReference.ciphertextSha256,
            plaintextSha256: firstReference.plaintextSha256
        )
        let secondReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "second.png",
            ciphertextSha256: String(repeating: "3", count: 64),
            plaintextSha256: String(repeating: "4", count: 64)
        )
        let secondDownloadReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "second.png",
            ciphertextSha256: secondReference.ciphertextSha256,
            plaintextSha256: secondReference.plaintextSha256
        )
        let secondDownload = MediaDownloadResultFfi(
            plaintext: Data([0x10, 0x20, 0x30, 0x40]),
            fileName: "second.png",
            mediaType: "image/png",
            sizeBytes: 4
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        func mediaRecord(
            messageId: String,
            reference: MediaAttachmentReferenceFfi,
            recordedAt: UInt64
        ) -> MediaRecordFfi {
            MediaRecordFfi(
                messageIdHex: messageId,
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: reference,
                caption: nil,
                recordedAt: recordedAt,
                receivedAt: recordedAt
            )
        }
        runtime.installMediaRecord(
            mediaRecord(
                messageId: "first-media-message",
                reference: firstDownloadReference,
                recordedAt: 1_700_000_000
            ),
            download: MediaDownloadResultFfi(
                plaintext: Data([0x01, 0x02, 0x03, 0x04]),
                fileName: "first.png",
                mediaType: "image/png",
                sizeBytes: 4
            )
        )
        runtime.installMediaRecord(
            mediaRecord(
                messageId: "second-media-message",
                reference: secondDownloadReference,
                recordedAt: 1_700_000_001
            ),
            download: secondDownload
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let firstMessage = MessageItem(
            id: "first-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "first-media-message#0#\(firstReference.plaintextSha256)",
                    reference: firstReference
                )
            ]
        )
        let secondMessage = MessageItem(
            id: "second-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "second-media-message#0#\(secondReference.plaintextSha256)",
                    reference: secondReference
                )
            ]
        )
        let firstAttachment = try #require(firstMessage.mediaAttachments.first)
        let secondAttachment = try #require(secondMessage.mediaAttachments.first)
        let firstStore = state.mediaDownloadStateStore(for: firstMessage, attachment: firstAttachment)
        let sameFirstStore = state.mediaDownloadStateStore(for: firstMessage, attachment: firstAttachment)
        let secondStore = state.mediaDownloadStateStore(for: secondMessage, attachment: secondAttachment)

        #expect(firstStore === sameFirstStore)
        #expect(firstStore !== secondStore)

        let workspaceInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.mediaDownloadStateStore(for: firstMessage, attachment: firstAttachment)
        } onChange: {
            workspaceInvalidated.markInvalidated()
        }

        let firstStoreInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = firstStore.state
        } onChange: {
            firstStoreInvalidated.markInvalidated()
        }

        await state.loadMediaAttachment(secondAttachment, for: secondMessage)

        #expect(!workspaceInvalidated.value)
        #expect(!firstStoreInvalidated.value)
        #expect(firstStore.state == .idle)
        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)
        guard case .loaded(let loaded) = secondStore.state else {
            Issue.record("Expected the unrelated download store to receive the loaded state")
            return
        }
        #expect(loaded.data == secondDownload.plaintext)
        await state.deleteAllData()
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
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: "self"
        )

        #expect(
            messages.map(\.id) == [
                "runtime-third",
                "runtime-first",
                "runtime-second",
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
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMessages(
            [
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
                ),
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        #expect(state.messagesByChat["group"]?.count == 1)
        #expect(state.messagesByChat["group"]?.first?.body == "The launch plan is ready.")
        #expect(
            state.messagesByChat["group"]?.first?.reactions == [
                MessageReaction(emoji: "👍", count: 1, isOwn: true, ownReactionMessageId: "reaction")
            ])
    }

    @MainActor
    @Test func loadingMessagesOmitsDeletedReactions() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        runtime.installMessages(
            [
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
                ),
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
            signedOut: false,
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
        runtime.installMessages(
            [
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
                        MessageTagFfi(values: ["q", "parent"]),
                    ],
                    recordedAt: 1_700_000_001
                ),
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        let messages = state.messagesByChat["group"] ?? []
        #expect(messages.map(\.id) == ["parent", "reply"])
        #expect(
            messages.last?.replyContext
                == MessageReplyContext(
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
            signedOut: false,
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
        runtime.installMessages(
            [
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
                                .remove(messageIdHex: "stale", reason: .noLongerMatchesQuery),
                                .upsert(trigger: .agentStreamStarted, message: projected),
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
    @Test func selectedMessagesObservationIgnoresUnselectedChatMutations() async throws {
        // Regression for #176: observing the visible transcript must not subscribe the
        // conversation view to the whole messagesByChat dictionary. A background-chat
        // timeline delta should leave the selected transcript's observation token alone,
        // while a selected-chat replacement must still invalidate it.
        let account = AccountItem.samples[0]
        let selectedChat = ChatItem.samples[0]
        let backgroundChat = ChatItem.samples[1]
        let selectedMessage = MessageItem(
            id: "selected-1",
            groupIdHex: selectedChat.id,
            senderName: "Alice",
            body: "Visible",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        let backgroundMessage = MessageItem(
            id: "background-1",
            groupIdHex: backgroundChat.id,
            senderName: "Bob",
            body: "Background",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [selectedChat, backgroundChat]],
            messagesByChat: [
                selectedChat.id: [selectedMessage],
                backgroundChat.id: [backgroundMessage],
            ],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.selection = .chat(selectedChat.id)

        #expect(state.selectedMessages.map(\.id) == ["selected-1"])

        let backgroundInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.selectedMessages.map(\.id)
        } onChange: {
            backgroundInvalidated.markInvalidated()
        }

        let backgroundUpdatedMessage = MessageItem(
            id: "background-2",
            groupIdHex: backgroundChat.id,
            senderName: "Bob",
            body: "Background update",
            sentAt: Date(timeIntervalSince1970: 1_700_000_002),
            isOutgoing: false
        )
        let backgroundTimelineStore = state.ensureMessageTimelineStore(for: backgroundChat.id)
        state.cachedMessageChatIds.insert(backgroundChat.id)
        backgroundTimelineStore.replace(with: [backgroundUpdatedMessage])

        #expect(!backgroundInvalidated.value)
        #expect(backgroundTimelineStore.messages.map(\.id) == ["background-2"])
        #expect(state.selectedMessages.map(\.id) == ["selected-1"])

        let selectedInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.selectedMessages.map(\.id)
        } onChange: {
            selectedInvalidated.markInvalidated()
        }

        state.replaceMessages(
            [
                MessageItem(
                    id: "selected-2",
                    groupIdHex: selectedChat.id,
                    senderName: "Alice",
                    body: "Visible update",
                    sentAt: Date(timeIntervalSince1970: 1_700_000_003),
                    isOutgoing: false
                )
            ],
            groupIdHex: selectedChat.id
        )

        #expect(selectedInvalidated.value)
        #expect(state.selectedMessages.map(\.id) == ["selected-2"])
    }

    @MainActor
    @Test func timelineMessageResolvesFromStoreLookup() async throws {
        // The per-chat id → message lookup lives on `MessageTimelineStore` (not a parallel
        // `messageLookupByChat` dict); `timelineMessage(groupIdHex:messageId:)` resolves through
        // it and stays in sync across window replacements.
        let account = AccountItem.samples[0]
        let chat = ChatItem.samples[0]
        let first = MessageItem(
            id: "m1",
            groupIdHex: chat.id,
            senderName: "Alice",
            body: "First",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [chat]],
            messagesByChat: [chat.id: [first]],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.selection = .chat(chat.id)

        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "m1")?.body == "First")
        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "missing") == nil)

        let second = MessageItem(
            id: "m2",
            groupIdHex: chat.id,
            senderName: "Alice",
            body: "Second",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false
        )
        state.replaceMessages([second], groupIdHex: chat.id)
        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "m2")?.body == "Second")
        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "m1") == nil)
    }

    @MainActor
    @Test func selectedMessageIDsCacheStaysInSyncAcrossTimelineMutations() async throws {
        // Regression for #44: selectedMessageIDs is served from the selected timeline
        // store's cached id array. Verify the cached ids always equal the live message ids
        // before and after the timeline window is replaced via a projection.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        // Keep the live projection from racing ahead of the post-load cache assertion below.
        runtime.timelineUpdateDelayNanoseconds = 100_000_000
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
        runtime.installMessages(
            [
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
                ),
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
                                .remove(messageIdHex: "m1", reason: .noLongerMatchesQuery),
                                .upsert(trigger: .agentStreamStarted, message: projected),
                            ],
                            chatListRow: streamingChatRow,
                            chatListTrigger: .newLastMessage
                        )
                    ))
            ], groupIdHex: "direct-group")
        runtime.installChatListUpdates([
            .row(trigger: .newLastMessage, row: streamingChatRow)
        ])
        // Deliver the queued projection on a delay so the pre-projection assertions below run
        // deterministically against the initial window. Without this the listener can apply the
        // projection (`-m1, +stream`) before the synchronous `["m1", "m2"]` check, flaking the
        // test on faster/loaded CI runners.
        runtime.timelineUpdateDelayNanoseconds = 300_000_000
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

    @Test func failedReadMarkerRollbackUsesLastConfirmedMarker() {
        let committed = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageId: "m0"
        )
        let firstAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_010),
            messageId: "m1"
        )
        let secondAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_020),
            messageId: "m2"
        )

        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: secondAttempt,
                attempted: firstAttempt,
                confirmed: committed
            ) == secondAttempt
        )
        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: secondAttempt,
                attempted: secondAttempt,
                confirmed: committed
            ) == committed
        )
        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: nil,
                attempted: firstAttempt,
                confirmed: committed
            ) == nil
        )
        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: firstAttempt,
                attempted: firstAttempt,
                confirmed: nil
            ) == nil
        )
    }

    @Test func successfulReadMarkerCommitAdvancesConfirmedMarkerAndPreservesNewerOptimisticSlot() {
        let committed = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageId: "m0"
        )
        let firstAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_010),
            messageId: "m1"
        )
        let secondAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_020),
            messageId: "m2"
        )

        let restoredAfterNewerFailure = ReadMarker.afterSuccessfulCommit(
            current: committed,
            confirmed: committed,
            attempted: firstAttempt
        )
        #expect(restoredAfterNewerFailure.current == firstAttempt)
        #expect(restoredAfterNewerFailure.confirmed == firstAttempt)

        let newerStillInFlight = ReadMarker.afterSuccessfulCommit(
            current: secondAttempt,
            confirmed: committed,
            attempted: firstAttempt
        )
        #expect(newerStillInFlight.current == secondAttempt)
        #expect(newerStillInFlight.confirmed == firstAttempt)

        let olderSuccessAfterNewerCommit = ReadMarker.afterSuccessfulCommit(
            current: secondAttempt,
            confirmed: secondAttempt,
            attempted: firstAttempt
        )
        #expect(olderSuccessAfterNewerCommit.current == secondAttempt)
        #expect(olderSuccessAfterNewerCommit.confirmed == secondAttempt)
    }

    @MainActor
    @Test func olderTimelineProjectionDeltaDoesNotMoveReadMarkerBackward() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        runtime.installMessages(
            [
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
                ),
            ], groupIdHex: "direct-group")
        let reprojectedOlder = timelineMessage(
            id: "older",
            groupIdHex: "direct-group",
            sender: aliceId,
            plaintext: "Earlier message edited by projection",
            recordedAt: 1_700_000_000
        )
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
            state.messagesByChat["direct-group"]?.first(where: { $0.id == "older" })?.body
                == "Earlier message edited by projection"
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
        // Start inactive so the initial open defers marking, then flip to active and
        // simulate the app regaining focus.
        let isActive = MutableFlag(false)
        let state = WorkspaceState(
            appActivityProvider: { isActive.value },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(runtime.markedReadMessageIds.isEmpty)

        isActive.value = true
        await state.handleConversationVisibilityChange()

        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func restoringConversationWindowFlushesDeferredReadMarking() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        let isWindowVisible = MutableFlag(false)
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { isWindowVisible.value },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(runtime.markedReadMessageIds.isEmpty)

        isWindowVisible.value = true
        await state.handleConversationVisibilityChange()

        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func chatListUsesSubscriptionSnapshotAndTypedDeltas() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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
    @Test func concurrentReloadChatsForSameAccountCoalesces() async throws {
        // Issue #210: reloadChats() is reachable from independently-spawned Tasks. Two overlapping
        // same-account reloads must share one in-flight subscription/snapshot pass instead of
        // duplicating FFI work and churn-cancelling the chat-list listener the first reload started.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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
    @Test func bootstrapSelectsMostRecentChatAndLoadsTimeline() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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
                    plaintext: "Older group message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
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
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "group-message",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Group cache candidate",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
        runtime.installMessages(
            [
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
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "group-message",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Group history should not look empty while loading",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
        runtime.installMessages(
            [
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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

        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-150", "message-249", "message-349"],
                newMessageIsOutgoing: false,
                paging: historicalPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: "message-249",
                newMessageId: "message-349",
                isPinnedToBottom: false
            ) == .restorePendingAppendAnchor("message-249"))
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-350", "message-449"],
                newMessageIsOutgoing: false,
                paging: historicalPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: "message-249",
                newMessageId: "message-449",
                isPinnedToBottom: false
            ) == .clearPendingAppendAnchor)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-350", "message-449"],
                newMessageIsOutgoing: false,
                paging: historicalPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-449",
                isPinnedToBottom: true
            ) == .none)
        #expect(
            timelineNewestMessageScrollAction(
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

        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: false,
                paging: longLiveEdgePaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: true
            ) == .scrollToBottom)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: false,
                paging: longLiveEdgePaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: false
            ) == .none)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: true,
                paging: longLiveEdgePaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: false
            ) == .scrollToBottom)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: false,
                paging: detachedHistoryPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: true
            ) == .none)
        #expect(
            timelineNewestMessageScrollAction(
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
            signedOut: false,
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
        runtime.installTimelineUpdates(
            [
                .page(
                    page: TimelinePageFfi(
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
            signedOut: false,
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
        runtime.installTimelineUpdates(
            [
                .projection(
                    update: RuntimeProjectionUpdateFfi(
                        accountIdHex: account.accountIdHex,
                        accountLabel: account.label,
                        update: TimelineProjectionUpdateFfi(
                            groupIdHex: "direct-group",
                            messages: [visibleUpdate, offscreenLatest],
                            changes: [
                                .upsert(trigger: .reactionAdded, message: visibleUpdate),
                                .upsert(trigger: .newMessage, message: offscreenLatest),
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
        #expect(
            loadedMessages.first(where: { $0.id == "message-120" })?.body == "Visible message updated by projection")
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
    @Test func freshlyResolvedPeerProfileIsStampedAfterTheFfiBatch() async throws {
        // Regression for #181: `messageSenderProfiles` must stamp newly-resolved cache
        // entries with a timestamp sampled *after* the off-main resolution batch, not
        // before it. Sampling before means a slow batch (cold cache, relay-backed
        // directory lookups) is charged against the entry's TTL the instant it is written.
        // In the pathological case where one batch exceeds the 300 s TTL, a pre-batch stamp
        // makes the entry stale on arrival, forcing an immediate re-resolution and defeating
        // the cache. The fix keeps a freshly-resolved entry fresh.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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

        // Drive the cache clock from the test via a thread-safe clock so the off-main batch
        // hook can advance it. Model a pathologically slow batch: the single timeline-sender
        // resolution burns more wall-clock time than the whole 300 s TTL. A pre-batch stamp
        // would be born already-expired; a post-batch stamp survives.
        let clock = ConcurrentClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let slowBatchSeconds = WorkspaceState.peerProfileCacheTTL + 100
        let state = WorkspaceState(nowProvider: { clock.now }, clientFactory: { runtime })

        await state.bootstrap()
        // Bootstrap enriches the direct-chat row through `resolvedPeerFFI`; clear that cache
        // entry so this regression exercises `messageSenderProfiles` itself. Page an older
        // timeline window after clearing the cache: reloading the already-open conversation
        // can reuse the current window and avoid the sender-profile path entirely.
        state.peerProfileFFICache.removeAll()
        runtime.onUserProfileLookup = { [clock] _ in
            clock.advance(by: slowBatchSeconds)
        }
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")

        // The entry must be stamped at (or after) the moment resolution finished, i.e. after
        // the clock was advanced by the slow batch — never with the pre-batch timestamp.
        let resolvedAt = try #require(state.peerProfileFFICache[aliceId]?.resolvedAt)
        #expect(resolvedAt.timeIntervalSince1970 >= 2_000_000_000 + slowBatchSeconds)

        // The cache is no longer warming, so further passes don't advance the clock. With a
        // correct post-batch stamp the entry is still fresh, so no re-resolution occurs.
        runtime.onUserProfileLookup = nil
        let userProfileCallsAfterFirstResolve = runtime.userProfileCallCount
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")
        #expect(runtime.userProfileCallCount == userProfileCallsAfterFirstResolve)
    }

    @MainActor
    @Test func messageActionsDoNotRestartLiveSubscriptions() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
            signedOut: false,
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
        state.startReply(
            to: MessageItem(
                id: "parent",
                senderName: "Alice",
                body: "The launch plan is ready.",
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: false
            ))
        state.draftText = "Looks good to me."
        await state.sendDraft()

        #expect(
            runtime.repliedMessage
                == SentReply(
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
            signedOut: false,
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

        #expect(
            runtime.reactedMessage
                == SentReaction(
                    groupIdHex: "direct-group",
                    targetMessageId: "parent",
                    emoji: "👍"
                ))
        #expect(
            runtime.deletedMessage
                == DeletedMessage(
                    groupIdHex: "direct-group",
                    targetMessageId: "parent"
                ))
    }

    @MainActor
    @Test func mediaAttachmentEnablesSendAndUploadsWithCaption() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachmentURL = directory.appendingPathComponent("notes.txt")
        try Data("hello media".utf8).write(to: attachmentURL)

        await state.bootstrap()
        await state.addMediaAttachments(from: [attachmentURL])
        state.draftText = "Project notes"

        #expect(state.pendingMediaAttachments.count == 1)
        #expect(state.canSend)

        await state.sendDraft()

        #expect(runtime.uploadMediaCallCount == 1)
        #expect(runtime.sendTextCallCount == 0)
        #expect(runtime.uploadedMedia?.groupIdHex == "direct-group")
        #expect(runtime.uploadedMedia?.request.caption == "Project notes")
        #expect(runtime.uploadedMedia?.request.send == true)
        #expect(runtime.uploadedMedia?.request.attachments.first?.fileName == "notes.txt")
        #expect(runtime.uploadedMedia?.request.attachments.first?.mediaType == "text/plain")
        #expect(runtime.uploadedMedia?.request.attachments.first?.plaintext == Data("hello media".utf8))
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func preparedMediaAttachmentIsDiscardedWhenSelectionChangesDuringPrep() async throws {
        // Issue #245: media/voice prep captures the composer draft key before an async prep
        // step. If the user switches chats while prep is in flight, the finished attachment
        // must be discarded rather than filed under the chat they just left. The append is
        // gated by `appendPendingMediaAttachmentIfSelectionUnchanged`, which discards when the
        // live selection no longer matches the captured key.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        guard let chatA = state.activeChats.first(where: { $0.id == "group" }),
            let chatB = state.activeChats.first(where: { $0.id == "direct-group" })
        else {
            Issue.record("Expected both test chats")
            return
        }

        state.selectChat(chatA)
        guard let staleKey = state.selectedComposerDraftKey else {
            Issue.record("Expected a composer draft key for chat A")
            return
        }

        let attachment = PendingMediaAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("hello media".utf8),
            dim: nil
        )

        // Simulate the user switching to chat B while prep is in flight, then the prep
        // completing with chat A's captured key.
        state.selectChat(chatB)
        let appended = state.appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: staleKey)

        #expect(!appended)
        // Nothing lands in the chat the user left, nor in the chat they are now viewing.
        #expect(state.pendingMediaAttachmentsByConversation[staleKey] == nil)
        #expect(state.pendingMediaAttachments.isEmpty)

        // Sanity check the positive path: with selection unchanged the attachment is appended.
        state.selectChat(chatA)
        let appendedAgain = state.appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: staleKey)
        #expect(appendedAgain)
        #expect(state.pendingMediaAttachments.map(\.fileName) == ["notes.txt"])
    }

    @MainActor
    @Test func mediaSendRefreshesSelectedTimelineImmediately() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        let reference = mediaAttachmentReference(mediaType: "text/plain", fileName: "notes.txt")
        runtime.timelineMessagesHandler = { query in
            return TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: "media",
                        direction: "outbound",
                        groupIdHex: "direct-group",
                        sender: account.accountIdHex,
                        plaintext: "Project notes",
                        recordedAt: 1_700_000_010,
                        mediaJson: mediaJson(for: reference)
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }
        let state = WorkspaceState(clientFactory: { runtime })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachmentURL = directory.appendingPathComponent("notes.txt")
        try Data("hello media".utf8).write(to: attachmentURL)

        await state.bootstrap()
        await state.addMediaAttachments(from: [attachmentURL])
        state.draftText = "Project notes"
        await state.sendDraft()

        #expect(runtime.uploadMediaCallCount == 1)
        #expect(runtime.timelineMessageQueries.last?.groupIdHex == "direct-group")
        #expect(state.messagesByChat["direct-group"]?.map(\.id) == ["media"])
        #expect(state.messagesByChat["direct-group"]?.first?.mediaAttachments.count == 1)
        #expect(state.messagesByChat["direct-group"]?.first?.body == "Project notes")
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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

        #expect(
            runtime.deletedMessage
                == DeletedMessage(
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
        let state = WorkspaceState(copyTextHandler: {
            copiedText = $0
            copiedConcealed = $1
        })

        state.copyText(
            of: MessageItem(
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

        state.copyText(
            of: MessageItem(
                id: "deleted",
                senderName: "Alice",
                body: "Message deleted",
                sentAt: sentAt,
                isDeleted: true,
                isOutgoing: false
            ))
        state.copyText(
            of: MessageItem(
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
            ),
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

    @Test func conversationTranscriptExportFailsWhenEmptyPageReportsMoreHistory() throws {
        // Regression for #139: an empty page returned with `hasMoreBefore == true` cannot
        // advance the `before` cursor, so the export must fail loudly rather than silently
        // truncating older history. The first page returns one message with more before it,
        // then the second page comes back empty while still claiming more history exists.
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let firstId = String(repeating: "1", count: 64)
        runtime.timelineMessagesHandler = { query in
            if query.before == nil {
                return TimelinePageFfi(
                    messages: [
                        timelineMessage(
                            id: firstId,
                            groupIdHex: "group",
                            sender: String(repeating: "a", count: 64),
                            plaintext: "newest",
                            recordedAt: 10
                        )
                    ],
                    hasMoreBefore: true,
                    hasMoreAfter: false
                )
            }
            return TimelinePageFfi(messages: [], hasMoreBefore: true, hasMoreAfter: false)
        }

        #expect(throws: ConversationTranscriptExport.ExportError.self) {
            try ConversationTranscriptExport.fetchAllMessages(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group"
            )
        }
    }

    @Test func conversationTranscriptExportStopsCleanlyWhenEmptyPageHasNoMoreHistory() throws {
        // The companion to the regression above: an empty page with `hasMoreBefore == false`
        // is genuinely done and must terminate the loop without throwing.
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        let messages = try ConversationTranscriptExport.fetchAllMessages(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group"
        )
        #expect(messages.isEmpty)
    }

    @MainActor
    @Test func directChatUsesOtherMemberProfileForTitleAndAvatar() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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
            encryptedMedia: encryptedMediaComponent(),
            disappearingMessageSecs: 0,
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
        let didEnrichIncrementally = await waitFor(attempts: 300) {
            state.activeChats.first?.title == "Alice Actual"
                && state.activeChats.first?.preview == "See you soon."
        }

        if !didEnrichIncrementally {
            let chat = state.activeChats.first
            Issue.record(
                """
                Expected incremental direct-chat enrichment. \
                title=\(chat?.title ?? "nil") preview=\(chat?.preview ?? "nil") \
                pictureURL=\(chat?.pictureURL ?? "nil") \
                detailsCalls=\(runtime.groupDetailsCallCounts["direct-group"] ?? 0)
                """
            )
        }
        #expect(didEnrichIncrementally)
        #expect(state.activeChats.first?.isDirect == true)
        #expect(state.activeChats.first?.pictureURL == "https://example.com/alice.png")
        // The incremental row reuses the initial membership lookup for non-membership triggers;
        // it must not re-query group details just to refresh the last-message preview (#9).
        #expect((runtime.groupDetailsCallCounts["direct-group"] ?? 0) == 1)
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
            pendingConfirmation: true
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
    }

    @MainActor
    @Test func readMarkerChatRowPreservesResolvedDirectMetadataWhenSkippingEnrichment() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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
        #expect(state.activeChats.first?.preview == "Alice Actual: Latest message")
    }

    @MainActor
    @Test func repeatedReadMarkerRowsWithMissingMetadataDoNotRepeatGroupDetailsLookups() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
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

    @MainActor
    @Test func timelineSenderProfilesReusePrimedGroupMemberDetails() async throws {
        // Regression for #9: loading/reprojecting a timeline should not hit `groupDetails`
        // again after chat-list enrichment has already cached the group's members. The
        // timeline only needs member display names as sender-name fallbacks.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        runtime.installMessages(
            [
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

    @MainActor
    @Test func timelineSenderProfilesSkipMemberFetchWhenSendersResolve() async throws {
        // Regression for #171: when every non-local sender already resolves from its cached
        // profile display/name, `messageSenderProfiles` must not fetch the group member list or
        // build the member-name fallback map. The fallback is only ever consulted for senders
        // with a blank resolved name, so in the all-resolved steady state the member fetch and
        // dictionary allocation are wasted work on the timeline hot path.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        // Alice has a real profile, so the timeline resolves her name from the profile lookup and
        // never needs the group-member-name fallback.
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
        runtime.installMessages(
            (0..<150).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: 1_700_000_000 + UInt64(index)
                )
            },
            groupIdHex: "group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        // Bootstrap auto-selects the only chat and applies its initial timeline window; the
        // explicit pagination call below applies a second window. Both run through
        // `messageSenderProfiles`, exercising the steady-state hot path.
        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")
        await state.loadOlderMessages(groupIdHex: "group")

        let messages = state.messagesByChat["group"] ?? []
        #expect(messages.first?.senderName == "Alice Cooper")
        // The optimization: no member fetch for the sender-name fallback across any window,
        // because every sender resolved from its profile. Before the #171 fix this would be >= 1.
        #expect(state.timelineSenderMemberFallbackFetchCount == 0)
    }

    @MainActor
    @Test func timelineSenderProfilesFallBackToMemberNameWhenProfileBlank() async throws {
        // Companion to #171: behavior for blank profile names is preserved. When a non-local
        // sender's resolved profile display/name is blank but the group exposes a member display
        // name, the timeline must still fall back to the member name (ahead of the directory
        // display name), which requires fetching the member list.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        // `groupDetailsFixture` exposes Alice with member display name "Alice".
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        // No profile/directory name for Alice, so the only usable name is the group member name.
        runtime.accountIdsMissingProfiles.insert(aliceId)
        runtime.installMessages(
            [
                appMessage(
                    id: "alice-message",
                    groupIdHex: "group",
                    sender: aliceId,
                    plaintext: "Member-name fallback still applies.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        // Bootstrap auto-selects the only chat and applies its initial timeline window.
        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        let messages = state.messagesByChat["group"] ?? []
        #expect(messages.first?.senderName == "Alice")
        // The blank-profile sender needs the fallback, so the member list is fetched at least once.
        #expect(state.timelineSenderMemberFallbackFetchCount >= 1)
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
    @Test func groupImageSearchSelectionUpdatesGroupAvatarUrl() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        #expect(
            runtime.updatedGroupAvatar
                == UpdatedGroupAvatar(
                    groupIdHex: "group",
                    url: "https://example.com/aurora.jpg",
                    dim: "1024x680",
                    thumbhash: nil
                ))
        #expect(!state.isGroupImagePickerPresented)
        #expect(state.activeChats.first?.pictureURL == "https://example.com/aurora.jpg")
    }

    @MainActor
    @Test func groupImageUpdateDropsOverlappingDuplicateInvocation() async throws {
        // Issue #134: set/clear group image both funnel through an async avatar update.
        // The in-flight flag must guard the entry point itself so a second control action
        // delivered before SwiftUI disables the UI does not publish a conflicting update.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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

        let result = GroupImageSearchResult(
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

        state.showGroupImagePicker(for: groupChat)
        runtime.groupAvatarUpdateGateEnabled = true
        async let firstUpdate: Void = state.setGroupImage(result)

        while !(state.isSavingGroupImage && runtime.didReachGroupAvatarUpdateGate) {
            await Task.yield()
        }

        // Closing/reopening the picker while the first update is suspended must not clear the
        // in-flight guard; an overlapping clear action still has to be dropped.
        state.closeGroupImagePicker()
        #expect(!state.isGroupImagePickerPresented)
        #expect(state.isSavingGroupImage)
        state.showGroupImagePicker(for: groupChat)
        await state.clearGroupImage()
        #expect(runtime.updateGroupAvatarUrlCallCount == 1)

        runtime.releaseGroupAvatarUpdateGate()
        await firstUpdate

        #expect(runtime.updateGroupAvatarUrlCallCount == 1)
        #expect(
            runtime.updatedGroupAvatar
                == UpdatedGroupAvatar(
                    groupIdHex: "group",
                    url: "https://example.com/aurora.jpg",
                    dim: "1024x680",
                    thumbhash: nil
                ))
        #expect(!state.isSavingGroupImage)
    }

    @MainActor
    @Test func groupImagePickerDismissesWhenSelectionClears() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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

    @Test func conversationHeaderChatInfoOpensSlideInGroupDetails() throws {
        // These are private SwiftUI views, so this source-shape regression guards
        // the user-facing wiring directly. The chat-info affordance is now the
        // header's avatar/title button (works for direct chats too), and the
        // details screen slides in over the transcript from ConversationView
        // rather than presenting as a header sheet.
        let viewsDirURL =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-mac")
            .appendingPathComponent("Views")
        // ConversationHeader lives in the composer views after the shell-view
        // split; fall back to the shell file so the guard survives further
        // extraction. Bound the snippet by the next top-level declaration so it
        // does not depend on which sibling struct happens to follow it.
        let candidateFiles = ["ComposerViews.swift", "MessengerShellView.swift"]
        var extractedHeader: String?
        for fileName in candidateFiles {
            let url = viewsDirURL.appendingPathComponent(fileName)
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                let headerStart = source.range(of: "struct ConversationHeader: View {")
            else { continue }
            let rest = source[headerStart.upperBound...]
            let nextDeclIndex =
                [
                    rest.range(of: "\nprivate struct ")?.lowerBound,
                    rest.range(of: "\nstruct ")?.lowerBound,
                ]
                .compactMap { $0 }.min() ?? source.endIndex
            extractedHeader = String(source[headerStart.lowerBound..<nextDeclIndex])
            break
        }
        let headerSource = try #require(extractedHeader)

        // Tapping the header avatar/title opens the chat info screen.
        #expect(headerSource.contains("Task { await workspace.showGroupDetails(for: chat) }"))
        // The details screen is no longer a modal sheet hung off the header.
        #expect(!headerSource.contains(".sheet(isPresented: $workspace.isGroupDetailsPresented)"))

        // ConversationView presents the details panel inline as a slide-in,
        // gated on the same flag, so it replaces the transcript in place.
        let shellURL = viewsDirURL.appendingPathComponent("MessengerShellView.swift")
        let shellSource = try String(contentsOf: shellURL, encoding: .utf8)
        #expect(shellSource.contains("if workspace.isGroupDetailsPresented"))
        #expect(shellSource.contains("GroupDetailsSheet(chat: chat)"))
        #expect(shellSource.contains(".move(edge: .trailing)"))
    }

    @MainActor
    @Test func staleGroupDetailsLoadDoesNotClobberNewerSnapshotOrDropSpinner() async throws {
        // Issue #135: `loadGroupDetails` is reachable concurrently for the same group, and the FFI
        // pair it awaits is completion-ordered, not request-ordered. An older, slower load must not
        // overwrite a newer snapshot, must not report a stale error, and an older completion must
        // not clear `isLoadingGroupDetails` while a newer load is still running.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        var olderDetails = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        olderDetails.group.name = "Older Snapshot"
        runtime.installGroupDetails(olderDetails)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }
        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.name == "Older Snapshot")

        // Arm the gate so the next `groupDetails` FFI call (the older load) suspends in-flight after
        // capturing the older details.
        runtime.groupDetailsGateEnabled = true
        async let older: Void = state.reloadSelectedGroupDetails()
        while !(state.isLoadingGroupDetails && runtime.didReachGroupDetailsGate) {
            await Task.yield()
        }
        #expect(state.isLoadingGroupDetails)

        // While the older load is held, install a newer snapshot and run a newer load to completion.
        // The gate only holds the first call, so this newer load is not gated.
        var newerDetails = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        newerDetails.group.name = "Newer Snapshot"
        runtime.installGroupDetails(newerDetails)
        await state.reloadSelectedGroupDetails()

        // The newer load applied its snapshot and, owning the spinner, cleared it.
        #expect(state.groupDetailsSnapshot?.name == "Newer Snapshot")
        #expect(state.isLoadingGroupDetails == false)

        // Release the older load. Its completion is now superseded, so it must neither overwrite the
        // newer snapshot, report an error, nor resurrect the spinner.
        runtime.releaseGroupDetailsGate()
        _ = await older

        #expect(state.groupDetailsSnapshot?.name == "Newer Snapshot")
        #expect(state.isLoadingGroupDetails == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func closingGroupDetailsInvalidatesInFlightLoad() async throws {
        // Issue #135: closing group details must invalidate any in-flight load so a stale completion
        // cannot repopulate the closed snapshot or resurrect the shared spinner.
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
        #expect(state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot?.name == "Test Group")

        // Hold a reload in-flight at the gate, then close group details before it completes.
        // Opening first avoids the chat-list enrichment task racing to consume the test gate.
        runtime.groupDetailsGateEnabled = true
        async let inflight: Void = state.reloadSelectedGroupDetails()
        while !(state.isLoadingGroupDetails && runtime.didReachGroupDetailsGate) {
            await Task.yield()
        }

        state.closeGroupDetails()
        #expect(!state.isGroupDetailsPresented)
        #expect(state.isLoadingGroupDetails == false)
        #expect(state.groupDetailsSnapshot == nil)

        // Releasing the now-invalidated load must not repopulate the closed UI or set the spinner.
        runtime.releaseGroupDetailsGate()
        _ = await inflight

        #expect(!state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot == nil)
        #expect(state.isLoadingGroupDetails == false)
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

        #expect(
            runtime.updatedGroupProfile
                == UpdatedGroupProfile(
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
    @Test func groupInviteAcceptUsesBindingAndClearsPendingState() async throws {
        let account = desktopAccount()
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }
        #expect(groupChat.pendingConfirmation)

        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.pendingConfirmation == true)

        await state.acceptSelectedGroupInvite()

        #expect(runtime.acceptedInviteGroupIds == ["group"])
        #expect(state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot?.pendingConfirmation == false)
        #expect(state.activeChats.first?.pendingConfirmation == false)
    }

    @MainActor
    @Test func groupInviteDeclineUsesBindingAndRemovesChat() async throws {
        let account = desktopAccount()
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }
        await state.showGroupDetails(for: groupChat)

        await state.declineSelectedGroupInvite()

        #expect(runtime.declinedInviteGroupIds == ["group"])
        #expect(!state.isGroupDetailsPresented)
        #expect(state.activeChats.isEmpty)
        #expect(state.selectedChat == nil)
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
    @Test func secureDeleteExpiredMessagesDropsOverlappingDuplicateInvocation() async throws {
        // Issue #216: secure-delete is destructive, so overlapping invocations must be dropped
        // before they issue duplicate FFI calls.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        runtime.secureDeleteExpiredGateEnabled = true
        async let firstDelete: Void = state.secureDeleteExpiredMessages(groupIdHex: "group")
        while !(state.isSecureDeletingExpired && runtime.didReachSecureDeleteExpiredGate) {
            await Task.yield()
        }

        // The overlapping call should return at the WorkspaceState guard before suspending
        // in the fake FFI gate, so the runtime invocation count must stay unchanged.
        await state.secureDeleteExpiredMessages(groupIdHex: "group")
        #expect(runtime.secureDeleteExpiredCallCount == 1)

        runtime.releaseSecureDeleteExpiredGate()
        await firstDelete

        #expect(runtime.secureDeleteExpiredCallCount == 1)
        #expect(!state.isSecureDeletingExpired)
    }

    @MainActor
    @Test func groupDetailsSelfDemoteUsesDetailedMutation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(
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

    @Test func remoteImagePolicyRejectsPrivateAndLoopbackHosts() async throws {
        // SSRF guard: once a user opts into remote images, an attacker-controlled `picture`
        // URL must not be able to reach the viewer's internal network. Every URL below is a
        // valid `https://` URL with a non-empty host, so only the address check rejects them.

        // IPv4 loopback / private / link-local / "this host".
        let blockedV4 = [
            "https://127.0.0.1/x.png",
            "https://127.1.2.3/x.png",
            "https://10.0.0.5/x.png",
            "https://10.255.255.255/x.png",
            "https://172.16.0.1/x.png",
            "https://172.31.255.255/x.png",
            "https://192.168.1.1/x.png",
            "https://169.254.169.254/x.png",  // cloud metadata endpoint
            "https://0.0.0.0/x.png",
        ]
        for s in blockedV4 {
            #expect(!RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected SSRF rejection for \(s)")
        }

        // Obfuscated IPv4 forms that still resolve to loopback/private must also be rejected.
        // (Parser-level coverage of every BSD form lives in `ipAddressParserHandlesLiteralForms`;
        // here we assert the end-to-end URL path for the forms `URL(string:)` parses as a host.)
        let blockedV4Obfuscated = [
            "https://2130706433/x.png",  // decimal 127.0.0.1
            "https://127.1/x.png",  // shorthand 127.0.0.1
            "https://10.0.0.16/x.png",  // plain private, sanity
        ]
        for s in blockedV4Obfuscated {
            #expect(!RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected SSRF rejection for \(s)")
        }

        // IPv6 loopback / unspecified / ULA / link-local / IPv4-mapped private.
        let blockedV6 = [
            "https://[::1]/x.png",
            "https://[::]/x.png",
            "https://[fc00::1]/x.png",
            "https://[fd12:3456::1]/x.png",
            "https://[fe80::1]/x.png",
            "https://[::ffff:192.168.0.1]/x.png",
            "https://[::ffff:127.0.0.1]/x.png",
        ]
        for s in blockedV6 {
            #expect(!RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected SSRF rejection for \(s)")
        }

        // Local hostnames.
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://localhost/x.png")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://LOCALHOST/x.png")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://printer.local/x.png")!))

        // Allowed: genuine public hosts and public IP literals are not affected.
        let allowed = [
            "https://example.com/avatar.png",
            "https://cdn.example.org/p.jpg",
            "https://8.8.8.8/x.png",
            "https://1.1.1.1/x.png",
            "https://172.32.0.1/x.png",  // just outside 172.16/12
            "https://192.169.0.1/x.png",  // just outside 192.168/16
            "https://[2606:4700:4700::1111]/x.png",  // public IPv6 (Cloudflare)
            "https://[::ffff:8.8.8.8]/x.png",  // IPv4-mapped public address
        ]
        for s in allowed {
            #expect(RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected allow for \(s)")
        }
    }

    @Test func ipAddressParserHandlesLiteralForms() async throws {
        // IPv4: dotted-quad, decimal, hex, octal, and shorthand all normalize to the same octets.
        #expect(IPAddress.parseIPv4("127.0.0.1").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("8.8.8.8").map { [$0.0, $0.1, $0.2, $0.3] } == [8, 8, 8, 8])
        #expect(IPAddress.parseIPv4("203.0.113.5").map { [$0.0, $0.1, $0.2, $0.3] } == [203, 0, 113, 5])
        #expect(IPAddress.parseIPv4("2130706433").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("0x7f000001").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("0177.0.0.1").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("127.1").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("10.0.0.16").map { [$0.0, $0.1, $0.2, $0.3] } == [10, 0, 0, 16])
        // Not IPv4 literals.
        #expect(IPAddress.parseIPv4("example.com") == nil)
        #expect(IPAddress.parseIPv4("256.0.0.1") == nil)  // octet overflow
        #expect(IPAddress.parseIPv4("1.2.3.4.5") == nil)  // too many parts

        // IPv6: `::` compression, full form, and IPv4-mapped tail.
        #expect(IPAddress.parseIPv6("::1") == [0, 0, 0, 0, 0, 0, 0, 1])
        #expect(IPAddress.parseIPv6("fe80::1")?.first == 0xFE80)
        #expect(IPAddress.parseIPv6("::ffff:192.168.0.1") == [0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0001])
        #expect(IPAddress.parseIPv6("fe80:::1") == nil)  // malformed: empty group
        #expect(IPAddress.parseIPv6("example.com") == nil)
    }

    @Test func pendingMediaDraftThumbnailDecoderDownsamplesLargeImage() async throws {
        let data = try Self.jpegData(width: 640, height: 480)
        let productionTileMaxPixelSize = 148
        let image = try #require(
            PendingMediaDraftThumbnailDecoder.image(
                from: data,
                maxPixelSize: CGFloat(productionTileMaxPixelSize)
            )
        )
        let representation = try #require(image.representations.first)

        #expect(max(representation.pixelsWide, representation.pixelsHigh) <= productionTileMaxPixelSize)
        #expect(
            PendingMediaDraftThumbnailDecoder.decodedCost(for: image)
                <= productionTileMaxPixelSize * productionTileMaxPixelSize * 4
        )
    }

    @Test func pendingMediaDraftThumbnailDecoderRejectsInvalidImageData() async throws {
        let image = PendingMediaDraftThumbnailDecoder.image(
            from: Data([0x00, 0x01, 0x02, 0x03]),
            maxPixelSize: 74
        )

        #expect(image == nil)
    }

    @Test func remoteImageLoaderCoalescesConcurrentLoadsForSameCacheKey() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0.2)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))

        async let first = loader.image(for: url, maxPixelSize: 32)
        async let second = loader.image(for: url, maxPixelSize: 32)
        async let third = loader.image(for: url, maxPixelSize: 32)

        let results = await [first, second, third]

        #expect(results.allSatisfy { $0 != nil })
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    @Test func remoteImageLoaderCancelsCoalescedDownloadAfterLastWaiterCancels() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 2)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))

        let first = Task { await loader.image(for: url, maxPixelSize: 32) }

        let requestStarted = await waitFor { RemoteImageURLProtocolStub.requestCount() == 1 }
        #expect(requestStarted)

        let second = Task { await loader.image(for: url, maxPixelSize: 32) }

        let secondJoined = await waitFor {
            loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 2
                && RemoteImageURLProtocolStub.requestCount() == 1
        }
        #expect(secondJoined)

        first.cancel()
        let firstReleased = await waitFor {
            loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 1
        }
        #expect(firstReleased)
        #expect(RemoteImageURLProtocolStub.stopLoadingCount() == 0)

        second.cancel()

        let requestCancelled = await waitFor {
            RemoteImageURLProtocolStub.stopLoadingCount() == 1
                && loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 0
        }
        #expect(requestCancelled)

        let results = await [first.value, second.value]
        #expect(results.allSatisfy { $0 == nil })
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    @Test func remoteImageLoaderUsesBoundedDecodedCache() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))

        #expect(loader.decodedCacheCountLimit == RemoteImageLoader.defaultDecodedCacheCountLimit)
        #expect(loader.decodedCacheTotalCostLimit == RemoteImageLoader.defaultDecodedCacheTotalCostLimit)
        #expect(loader.decodedCacheCountLimit > 0)
        #expect(loader.decodedCacheTotalCostLimit > 0)
    }

    @Test func remoteImageLoaderDefaultSessionPinsMemoryOnlyURLCacheInvariant() async throws {
        let config = RemoteImageLoader.makeSessionConfiguration()
        let urlCache = try #require(config.urlCache)

        // Foundation does not expose a stable cross-platform seam for asserting URLCache disk
        // writes directly, so pin the privacy invariant that prevents them for the default loader.
        #expect(urlCache.memoryCapacity > 0)
        #expect(urlCache.diskCapacity == 0)
        #expect(config.requestCachePolicy == .useProtocolCachePolicy)
    }

    @Test func remoteImageLoaderDownsamplesAndCachesLocalAttachmentBytes() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let imageData = try Self.testPNGData(width: 400, height: 300)

        let small = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 64)
        )
        let smallSize = try #require(Self.pixelSize(of: small.nsImage))
        #expect(max(smallSize.width, smallSize.height) <= 64)

        let cached = try #require(
            await loader.image(for: Data([0x00]), cacheKey: "attachment-1", maxPixelSize: 64)
        )
        #expect(cached.nsImage === small.nsImage)

        let large = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 128)
        )
        let largeSize = try #require(Self.pixelSize(of: large.nsImage))
        #expect(max(largeSize.width, largeSize.height) <= 128)
        #expect(max(largeSize.width, largeSize.height) > max(smallSize.width, smallSize.height))
    }

    @Test func remoteImageLoaderClearCacheEvictsDecodedImages() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let imageData = try Self.testPNGData(width: 400, height: 300)

        let decoded = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 64)
        )
        let cached = try #require(
            await loader.image(for: Data([0x00]), cacheKey: "attachment-1", maxPixelSize: 64)
        )
        #expect(cached.nsImage === decoded.nsImage)

        loader.clearCache()

        // After a wipe the previously decoded bytes must be gone, so a cache-key-only lookup with
        // bogus bytes can no longer be served and a real re-decode produces a fresh instance.
        #expect(await loader.image(for: Data([0x00]), cacheKey: "attachment-1", maxPixelSize: 64) == nil)
        let reDecoded = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 64)
        )
        #expect(reDecoded.nsImage !== decoded.nsImage)
    }

    @Test func remoteImageLoaderClearCacheInvalidatesInFlightLoads() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0.2)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))

        let pending = Task { await loader.image(for: url, maxPixelSize: 32) }
        let requestStarted = await waitFor {
            RemoteImageURLProtocolStub.requestCount() == 1
                && loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 1
        }
        #expect(requestStarted)

        loader.clearCache()

        let inFlightCleared = await waitFor {
            loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 0
        }
        #expect(inFlightCleared)
        let requestCancelled = await waitFor {
            RemoteImageURLProtocolStub.stopLoadingCount() >= 1
        }
        #expect(requestCancelled)
        #expect(await pending.value == nil)

        let reloaded = try #require(await loader.image(for: url, maxPixelSize: 32))
        #expect(reloaded.nsImage.size.width > 0)
        #expect(RemoteImageURLProtocolStub.requestCount() == 2)
    }

    @Test func remoteImageLoaderSeparatesRemoteAndLocalCacheNamespaces() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))
        let localData = try Self.testPNGData(width: 64, height: 64)

        let remote = try #require(await loader.image(for: url, maxPixelSize: 32))
        let local = try #require(
            await loader.image(for: localData, cacheKey: url.absoluteString, maxPixelSize: 32)
        )
        let localCached = try #require(
            await loader.image(for: Data([0x00]), cacheKey: url.absoluteString, maxPixelSize: 32)
        )

        #expect(remote.nsImage !== local.nsImage)
        #expect(localCached.nsImage === local.nsImage)
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    private static let singlePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99,
        0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    private enum ImageFixtureError: Error {
        case failedToCreateContext
        case failedToCreateImage
        case failedToCreateDestination
        case failedToFinalize
    }

    private static func jpegData(width: Int, height: Int) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let cgImage = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return nil
            }
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        let image = try #require(cgImage)
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func testPNGData(width: Int, height: Int) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0xFF, count: height * bytesPerRow)

        return try pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                throw ImageFixtureError.failedToCreateContext
            }
            guard let image = context.makeImage() else {
                throw ImageFixtureError.failedToCreateImage
            }

            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                )
            else {
                throw ImageFixtureError.failedToCreateDestination
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ImageFixtureError.failedToFinalize
            }
            return data as Data
        }
    }

    private static func pixelSize(of image: NSImage) -> (width: Int, height: Int)? {
        guard let representation = image.representations.first else { return nil }
        return (representation.pixelsWide, representation.pixelsHigh)
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
            "wss://relay.us.whitenoise.chat",
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
        #expect(
            state.replyDraftContext
                == MessageReplyContext(
                    targetMessageId: "design-parent",
                    senderName: "NVK",
                    body: "Design plan"
                ))

        state.selectChat(nvk)
        #expect(
            state.replyDraftContext
                == MessageReplyContext(
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
            signedOut: false,
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
            signedOut: false,
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
    @Test func createNewChatIncludesPendingQueryAlongsideAddedMembers() async throws {
        // Regression: a pubkey typed into the input but not yet committed via
        // return/+ must not be silently dropped when confirmed members already
        // exist — createNewChat resolves the pending query and folds it in.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1alice", accountIdHex: aliceId, npub: "npub1alice")
        runtime.installNormalizedMemberRef(query: "npub1bob", accountIdHex: bobId, npub: "npub1bob")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()

        // Commit the first member the normal way (this clears the input).
        state.newChatQuery = "npub1alice"
        _ = await state.addCurrentNewChatRecipient()
        #expect(state.newChatRecipients.map(\.accountIdHex) == [aliceId])
        #expect(state.newChatQuery.isEmpty)

        // Leave the second pubkey pending in the input, then create directly.
        state.newChatQuery = "npub1bob"
        await state.createNewChat()

        #expect(runtime.createdGroupMemberRefs == ["npub1alice", "npub1bob"])
        #expect(state.selection == .chat("created-group"))
    }

    @MainActor
    @Test func createNewChatDoesNotGraftGroupOntoAccountSwitchedToMidCreate() async throws {
        // Issue #229: `createNewChat()` suspends across `createGroup`/`reloadChats`. If the active
        // account changes (e.g. a notification tap) while suspended, the group created under
        // account A must not be inserted into / selected / loaded under account B's context. The
        // post-await `activeAccountId == accountId` guard drops the stale UI mutations.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")

        state.showNewChat()
        state.newChatQuery = "npub1alice"
        state.newChatName = "Project Room"

        // Arm the gate so the create suspends in-flight inside `createGroup`.
        runtime.createGroupGateEnabled = true
        async let pendingCreate: Void = state.createNewChat()
        while !runtime.didReachCreateGroupGate {
            await Task.yield()
        }

        // Switch to account B while the create is suspended. Drop the runtime's shared group
        // fixture so B's own `reloadChats()` does not legitimately surface the created group —
        // isolating the assertion to the cross-account contamination path under test.
        runtime.installGroups([])
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")

        // Release the stale create. Its post-await mutations must be dropped under B's context.
        runtime.releaseCreateGroupGate()
        _ = await pendingCreate

        #expect(state.activeAccountId == "Backup Account")
        #expect(state.selection != .chat("created-group"))
        #expect(!state.activeChats.contains { $0.id == "created-group" })
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func resolvingNewChatRecipientUsesProfilePicture() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
    @Test func openingNostrProfileLinkShowsNewChatComposerAndResolvesRecipient() async throws {
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let nprofile = "nprofile1alice"
        let query = "nostr:\(nprofile)"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: query, accountIdHex: aliceId, npub: "npub1alice")
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Link",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.newChatQuery = "stale draft"
        state.newChatName = "Stale room"
        _ = state.handleMessageLinkOpen(URL(string: query)!)
        let resolved = await waitFor {
            state.resolvedNewChatRecipient?.sourceQuery == query
        }

        #expect(resolved)
        #expect(state.isNewChatComposerVisible)
        #expect(state.newChatQuery == query)
        #expect(state.newChatName.isEmpty)
        #expect(state.resolvedNewChatRecipient?.npub == "npub1alice")
        #expect(state.resolvedNewChatRecipient?.title == "Alice Link")
    }

    @MainActor
    @Test func staleNewChatRecipientLookupDoesNotReplaceCurrentResult() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
    @Test func newChatLookupQueryEditedMidFlightClearsSpinnerWithoutCommitting() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let slowId = "1111111111111111111111111111111111111111111111111111111111111111"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1slow", accountIdHex: slowId, npub: "npub1slow")
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
        #expect(state.isResolvingNewChat)

        // Edit the query mid-flight WITHOUT starting a newer lookup: the in-flight
        // lookup still owns the generation, so when it resumes its defer must clear
        // the spinner (keyed on generation ownership) even though the stricter
        // generation+query commit guard now fails and blocks the stale result.
        state.newChatQuery = "npub1edited"
        await slowLookup.value

        #expect(!state.isResolvingNewChat)
        #expect(state.resolvedNewChatRecipient == nil)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func settingsLoadUpdatesActiveAccountProfilePicture() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
    @Test func staleKeyPackageLoadDoesNotClobberSwitchedAccountList() async throws {
        // Issue #207: `loadKeyPackages` is driven by `.task(id: activeAccountId)` and awaits the
        // completion-ordered `accountKeyPackages` FFI. On an A→B account switch, account A's
        // slower-resolving load must not overwrite account B's key-package list.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installKeyPackages(
            accountRef: "Desktop Account",
            packages: [keyPackageFixture(accountRef: "Desktop Account", eventIdHex: "event-account-a")]
        )
        runtime.installKeyPackages(
            accountRef: "Backup Account",
            packages: [keyPackageFixture(accountRef: "Backup Account", eventIdHex: "event-account-b")]
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")

        // Arm the gate so account A's load suspends in-flight after capturing A's packages.
        runtime.accountKeyPackagesGateEnabled = true
        async let staleLoad: Void = state.loadKeyPackages()
        while !runtime.didReachAccountKeyPackagesGate {
            await Task.yield()
        }

        // Switch to account B and run a fresh load to completion. The gate only holds the first
        // call, so B's load is not gated.
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadKeyPackages()
        #expect(state.keyPackages.map(\.eventIdHex) == ["event-account-b"])

        // Release account A's stale load. Its completion is now superseded, so it must neither
        // overwrite B's list nor report an error.
        runtime.releaseAccountKeyPackagesGate()
        _ = await staleLoad

        #expect(state.keyPackages.map(\.eventIdHex) == ["event-account-b"])
        #expect(state.lastError == nil)
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
    @Test func staleNotificationSettingsLoadDoesNotClobberSwitchedAccountSettings() async throws {
        // Issue #228: `loadNotificationSettings()` reads over the non-cancellation-aware FFI
        // boundary. If account A's read completes after switching to account B, its result must not
        // overwrite B's published notification preference.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: true)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled)

        runtime.notificationSettingsGateEnabled = true
        async let staleLoad: Void = state.loadNotificationSettings()
        while !runtime.didReachNotificationSettingsGate {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadNotificationSettings()
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseNotificationSettingsGate()
        _ = await staleLoad

        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleNotificationSettingsLoadDoesNotClobberReenteredAccountSettings() async throws {
        // A monotonic notification-settings generation closes the A→B→A hole that an id-only stale
        // guard leaves open: the older A read must not overwrite a newer A snapshot after re-entry.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: true)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled)

        runtime.notificationSettingsGateEnabled = true
        async let staleLoad: Void = state.loadNotificationSettings()
        while !runtime.didReachNotificationSettingsGate {
            await Task.yield()
        }

        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        state.selectAccountFromSettings(desktopAccount)
        await state.loadNotificationSettings()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseNotificationSettingsGate()
        _ = await staleLoad

        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleLocalNotificationToggleDoesNotClobberSwitchedAccountSettings() async throws {
        // Issue #228: `setLocalNotificationsEnabled(_:)` also awaits an FFI write before publishing
        // the returned snapshot. A stale account A toggle must not overwrite account B's snapshot.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.setLocalNotificationsGateEnabled = true
        async let staleToggle: Void = state.setLocalNotificationsEnabled(true)
        while !runtime.didReachSetLocalNotificationsGate {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadNotificationSettings()
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseSetLocalNotificationsGate()
        _ = await staleToggle

        #expect(runtime.localNotificationsEnabledSet == true)
        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleLocalNotificationToggleDoesNotClobberReenteredAccountSettings() async throws {
        // The stale toggle returns an older A snapshot after the user has switched A→B→A and loaded
        // a newer A snapshot. The generation guard must keep the newer A value.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.setLocalNotificationsGateEnabled = true
        async let staleToggle: Void = state.setLocalNotificationsEnabled(true)
        while !runtime.didReachSetLocalNotificationsGate {
            await Task.yield()
        }

        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        state.selectAccountFromSettings(desktopAccount)
        await state.loadNotificationSettings()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseSetLocalNotificationsGate()
        _ = await staleToggle

        #expect(runtime.localNotificationsEnabledSet == true)
        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleLocalNotificationPermissionRequestDoesNotPublishAuthorizationAfterSwitch() async throws {
        // If account A is waiting on the macOS permission sheet and the user switches accounts, the
        // eventual permission result must not update the now-current account's UI snapshot.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let notificationCenter = FakeLocalNotificationCenter(
            status: .notDetermined,
            requestedStatus: .authorized
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationAuthorizationStatus == .notDetermined)

        notificationCenter.requestAuthorizationGateEnabled = true
        async let staleToggle: Void = state.setLocalNotificationsEnabled(true)
        while !notificationCenter.didReachRequestAuthorizationGate {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")

        notificationCenter.releaseRequestAuthorizationGate()
        _ = await staleToggle

        #expect(notificationCenter.didRequestAuthorization)
        #expect(runtime.localNotificationsEnabledSet == nil)
        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.notificationAuthorizationStatus == .notDetermined)
        #expect(state.lastError == nil)
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
                "CFBundleVersion": "12",
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
        #expect(runtimeConfig.resource?.deviceModelIdentifier == nil)

        let auditConfig = config.auditTrackerConfig()
        #expect(auditConfig.authorizationBearerToken == "audit-token")
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
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            ],
            environment: [
                "DARKMATTER_OTLP_ENDPOINT": "https://env.example/v1/metrics",
                "OTLP_TOKEN_DARKMATTER_MAC": "env-otlp-token",
                "AUDIT_LOG_TOKEN_DARKMATTER_MAC": "env-audit-token",
                "DARKMATTER_TELEMETRY_ENVIRONMENT": "staging",
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
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: true,
            exportIntervalSeconds: 120
        )
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: false, dataMode: .obfuscatedSensitiveData)
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
        #expect(telemetryResource?.deviceModelIdentifier == nil)
        #expect(runtime.auditLogTrackerConfig?.authorizationBearerToken == "audit-token")
        #expect(runtime.auditLogTrackerConfig?.source.deviceLabel == expectedDeviceModelIdentifier())

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
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "secondary-account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            signedOut: false,
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

        // Account identity now lives in the core's JSONL source_context (Goggles
        // contract), so the host-supplied audit tracker config is account-
        // independent. Switching accounts therefore produces an unchanged request
        // that is skipped — the set-call count stays at 1.
        let secondaryItem = try #require(state.accounts.first { $0.accountRef == secondary.label })
        state.selectAccount(secondaryItem)
        let didSwitch = await waitFor {
            state.activeAccountId == secondaryItem.id
        }

        #expect(didSwitch)
        #expect(runtime.telemetryInstallIdCallCount == 1)
        #expect(runtime.relayTelemetryRuntimeConfigSetCallCount == 1)
        #expect(runtime.auditLogTrackerConfigSetCallCount == 1)
    }

    @MainActor
    @Test func notificationResponseAccountSwitchClearsPeerProfileFFICache() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.activeAccountId")

        let primary = AccountSummaryFfi(
            label: "primary-account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "secondary-account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let senderId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: primary.accountIdHex,
            otherAccountIdHex: senderId,
            otherDisplayName: "Group Alias",
            otherProfile: UserProfileMetadataFfi(
                name: "sender-primary",
                displayName: "Primary Alias",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "initial",
                    groupIdHex: "direct-group",
                    sender: senderId,
                    plaintext: "Initial message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Primary Alias")
        let baselineProfileCalls = runtime.userProfileCallCount

        runtime.installProfile(
            accountIdHex: senderId,
            profile: UserProfileMetadataFfi(
                name: "sender-secondary",
                displayName: "Secondary Alias",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )

        state.handleNotificationResponse([
            "groupIdHex": "direct-group",
            "accountIdHex": secondary.accountIdHex,
            "accountRef": secondary.label,
        ])
        let didResolveWithSecondaryProfile = await waitFor {
            state.messagesByChat["direct-group"]?.first?.senderName == "Secondary Alias"
        }

        #expect(didResolveWithSecondaryProfile)
        #expect(runtime.userProfileCallCount > baselineProfileCalls)
    }

    @MainActor
    @Test func enablingPrivacySecurityTogglesRequireConfiguredTokens() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
        runtime.installMessages(
            [
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
            signedOut: false,
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
        await state.handleNotificationUpdate(
            notificationUpdate(
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
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: true, dataMode: .obfuscatedSensitiveData)
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
            ),
        ]
        runtime.nextAuditLogTrackerUpdate = AuditLogTrackerUpdateResultFfi(
            enabled: true,
            uploaded: [
                AuditLogUploadResultFfi(path: "/tmp/audit-1.jsonl", status: 200, bytesSent: 123),
                AuditLogUploadResultFfi(path: "/tmp/audit-2.jsonl", status: 200, bytesSent: 456),
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
    @Test func deleteAllAuditLogFilesRefreshesListAfterMidLoopFailure() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let firstFile = AuditLogFileFfi(
            accountRef: account.label,
            path: "/tmp/audit-1.jsonl",
            fileName: "audit-1.jsonl",
            sizeBytes: 123,
            modifiedAtMs: nil
        )
        let secondFile = AuditLogFileFfi(
            accountRef: account.label,
            path: "/tmp/audit-2.jsonl",
            fileName: "audit-2.jsonl",
            sizeBytes: 456,
            modifiedAtMs: nil
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedAuditLogFiles = [firstFile, secondFile]
        runtime.auditLogDeleteFailurePaths = [secondFile.path]
        let expectedDeleteError = FakeMarmotRuntimeError.auditLogDeleteFailed.localizedDescription
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.auditLogFiles.map(\.path) == [firstFile.path, secondFile.path])

        await state.deleteAllAuditLogFiles()

        #expect(runtime.deletedAuditLogFilePaths == [firstFile.path])
        #expect(state.auditLogFiles.map(\.path) == [secondFile.path])
        #expect(state.lastError == expectedDeleteError)
    }

    @MainActor
    @Test func enablingLocalNotificationsRequestsPermissionAndUpdatesRuntime() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
            signedOut: false,
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
        #expect(
            state.lastError
                == "Open System Settings > Notifications and allow White Noise notifications, then try again.")
    }

    @MainActor
    @Test func incomingNotificationPostsLocalAlertWhenEnabledAndInactive() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        await state.handleNotificationUpdate(
            notificationUpdate(
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
    @Test func incomingNotificationReadsSettingsOnceForActiveAccount() async throws {
        // Issue #111: `handleNotificationUpdate(_:)` previously read the account's
        // notification settings twice over the FFI boundary for the active account
        // — once to sync the published snapshot and once to gate delivery. The two
        // responsibilities now share a single `notificationSettings(accountRef:)`
        // read.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            signedOut: false,
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
        // Ignore any `notificationSettings` reads performed during bootstrap; only
        // the handler's own reads are under test.
        runtime.clearSyncCallThreadRecords()

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "notice-1",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "See you there."
            ))

        // Exactly one FFI read for the active-account path (was two before the fix),
        // and it still runs off the main thread.
        let reads = runtime.syncCallThreadRecord("notificationSettings")
        #expect(reads.count == 1)
        #expect(reads.allSatisfy { !$0 })
        // The single read still drives both the published snapshot and delivery.
        #expect(state.notificationSettings.localNotificationsEnabled)
        #expect(notificationCenter.postedRequests.count == 1)
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

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "dm-notice",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "Top secret plaintext."
            ))
        await state.handleNotificationUpdate(
            notificationUpdate(
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

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "dm-notice",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "Top secret plaintext."
            ))
        await state.handleNotificationUpdate(
            notificationUpdate(
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

        await state.handleNotificationUpdate(
            notificationUpdate(
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
            signedOut: false,
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
        await state.handleNotificationUpdate(
            notificationUpdate(
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
            signedOut: false,
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
        await state.handleNotificationUpdate(
            notificationUpdate(
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
            signedOut: false,
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
        await state.handleNotificationUpdate(
            notificationUpdate(
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
            signedOut: false,
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
            "groupIdHex": "direct-group",
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
            signedOut: false,
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
        ),
    ]
    private var groups: [AppGroupRecordFfi] = []
    private var messagesByGroupId: [String: [AppMessageRecordFfi]] = [:]
    private var timelinePagesByGroupId: [String: TimelinePageFfi] = [:]
    private var timelineUpdatesByGroupId: [String: [TimelineSubscriptionUpdateFfi]] = [:]
    private var mediaRecordsByGroupId: [String: [MediaRecordFfi]] = [:]
    private var mediaDownloadsByPlaintextSha256: [String: MediaDownloadResultFfi] = [:]
    private var chatListUpdates: [ChatListSubscriptionUpdateFfi] = []
    private(set) var createdGroupMemberRefs: [String] = []
    private(set) var createdGroupName: String?
    private(set) var createdGroupDescription: String?
    private(set) var repliedMessage: SentReply?
    private(set) var reactedMessage: SentReaction?
    private(set) var deletedMessage: DeletedMessage?
    private(set) var sentText: SentText?
    private(set) var uploadedMedia: UploadedMedia?
    // Issue #78 reentrancy-test support: count message-action FFI calls so a test can prove
    // an overlapping duplicate was dropped by the WorkspaceState guard before reaching the runtime.
    private(set) var sendTextCallCount = 0
    private(set) var replyToMessageCallCount = 0
    private(set) var reactToMessageCallCount = 0
    private(set) var deleteMessageCallCount = 0
    private(set) var uploadMediaCallCount = 0
    private(set) var listMediaCallCount = 0
    private(set) var downloadMediaCallCount = 0
    private(set) var updatedGroupAvatar: UpdatedGroupAvatar?
    private(set) var updateGroupAvatarUrlCallCount = 0
    private(set) var updatedGroupProfile: UpdatedGroupProfile?
    private(set) var archivedGroup: ArchivedGroup?
    private(set) var leftGroupIdHex: String?
    private(set) var acceptedInviteGroupIds: [String] = []
    private(set) var declinedInviteGroupIds: [String] = []
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
    var groupDetailsFailureGroupIds = Set<String>()
    private(set) var chatListSubscriptionCount = 0
    private(set) var notificationSubscriptionCount = 0
    private(set) var timelineSubscriptionCount = 0
    private(set) var lastTimelineSubscription: FakeTimelineMessagesSubscription?
    var chatListStreamEndsAfterUpdates = false
    /// Simulates async relay/runtime latency before a chat-list subscription is ready.
    var chatListSubscriptionDelayNanoseconds: UInt64 = 0
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
    /// Issue #230 media-cache teardown-test support: when armed, the first `downloadMedia`
    /// call suspends after capturing the download bytes so a purge can complete before it returns.
    private let mediaDownloadGateLock = NSLock()
    var mediaDownloadGateEnabled = false
    private var mediaDownloadGateReached = false
    var didReachMediaDownloadGate: Bool {
        mediaDownloadGateLock.withLock { mediaDownloadGateReached }
    }
    private var mediaDownloadGateContinuation: CheckedContinuation<Void, Never>?
    private var mediaDownloadGateReleased = false
    /// Issue #134 reentrancy-test support: when armed, the first group-avatar update FFI call
    /// suspends until `releaseGroupAvatarUpdateGate()` is invoked, holding the first invocation
    /// in-flight so a test can issue an overlapping clear/set action and assert the guard dropped it.
    var groupAvatarUpdateGateEnabled = false
    private(set) var didReachGroupAvatarUpdateGate = false
    private var groupAvatarUpdateGateContinuation: CheckedContinuation<Void, Never>?
    /// Issue #135 last-request-wins-test support: when armed, the first `groupDetails` FFI call
    /// suspends until `releaseGroupDetailsGate()` is invoked, holding the older `loadGroupDetails`
    /// in-flight so a test can run a newer overlapping load to completion and then assert the stale
    /// older completion does not clobber the newer snapshot or drop the shared spinner.
    var groupDetailsGateEnabled = false
    private(set) var didReachGroupDetailsGate = false
    private var groupDetailsGateContinuation: CheckedContinuation<Void, Never>?
    /// Issue #207 last-request-wins-test support: when armed, the first `accountKeyPackages` FFI
    /// call suspends until `releaseAccountKeyPackagesGate()` is invoked, holding an older
    /// `loadKeyPackages()` in-flight so a test can switch the active account, run a newer load to
    /// completion, then assert the stale older completion does not overwrite (or, on error, blank)
    /// the newer account's key-package list.
    var accountKeyPackagesGateEnabled = false
    private(set) var didReachAccountKeyPackagesGate = false
    private var accountKeyPackagesGateContinuation: CheckedContinuation<Void, Never>?
    /// Issue #229 stale-account-test support: when armed, the first `createGroup` FFI call suspends
    /// until `releaseCreateGroupGate()` is invoked, holding `createNewChat()` in-flight so a test can
    /// switch the active account before the create resolves and assert the freshly created group is
    /// not grafted onto / selected under the switched-to account.
    var createGroupGateEnabled = false
    private(set) var didReachCreateGroupGate = false
    private var createGroupGateContinuation: CheckedContinuation<Void, Never>?
    /// Issue #228 last-request-wins support for synchronous notification FFI reads: when armed,
    /// the first `notificationSettings` call blocks on the FFI queue until released, holding an
    /// older account's result while the test switches accounts and loads the newer snapshot.
    private let notificationSettingsGate = BlockingFfiGate()
    var notificationSettingsGateEnabled: Bool {
        get { notificationSettingsGate.isEnabled }
        set { notificationSettingsGate.isEnabled = newValue }
    }
    var didReachNotificationSettingsGate: Bool {
        notificationSettingsGate.didReach
    }
    /// Issue #228 equivalent gate for the synchronous `setLocalNotificationsEnabled` FFI write.
    private let setLocalNotificationsGate = BlockingFfiGate()
    var setLocalNotificationsGateEnabled: Bool {
        get { setLocalNotificationsGate.isEnabled }
        set { setLocalNotificationsGate.isEnabled = newValue }
    }
    var didReachSetLocalNotificationsGate: Bool {
        setLocalNotificationsGate.didReach
    }
    /// Per-account key packages keyed by `accountRef`. Falls back to the default `keyPackages`
    /// fixture when an account has no explicit install, so existing single-account tests are
    /// unaffected.
    private var keyPackagesByAccountRef: [String: [AccountKeyPackageFfi]] = [:]
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
    private var notificationSettingsByAccountRef: [String: NotificationSettingsFfi] = [:]
    var storedAuditLogSettings = AuditLogSettingsFfi(enabled: false, dataMode: .obfuscatedSensitiveData)
    var storedAuditLogFiles: [AuditLogFileFfi] = []
    var auditLogDeleteFailurePaths: Set<String> = []
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
    /// Optional hook fired inside `userProfile`, on the off-main FFI batch thread. A test can
    /// use it to advance an injected clock and model a slow batch (whitenoise-mac#181).
    var onUserProfileLookup: (@Sendable (String) -> Void)?

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
        // Test-only hook fired inside the off-main profile-resolution batch, used to
        // simulate a slow batch advancing the wall clock so the post-FFI cache stamp can
        // be distinguished from a pre-FFI one (whitenoise-mac#181).
        onUserProfileLookup?(accountIdHex)
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
                ),
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
        groupManagementStateById[details.group.groupIdHex] =
            managementState ?? defaultGroupManagementState(for: details)
    }

    func installChatListUpdates(_ updates: [ChatListSubscriptionUpdateFfi]) {
        chatListUpdates = updates
    }

    func installTimelineUpdates(_ updates: [TimelineSubscriptionUpdateFfi], groupIdHex: String) {
        timelineUpdatesByGroupId[groupIdHex] = updates
    }

    func installMediaRecord(_ record: MediaRecordFfi, download: MediaDownloadResultFfi) {
        mediaRecordsByGroupId[record.groupIdHex, default: []].append(record)
        mediaDownloadsByPlaintextSha256[record.reference.plaintextSha256] = download
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
        missing: [MissingRelayListKindFfi] = []
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

    func publishUserProfile(
        accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]
    ) async throws -> UserProfileMetadataFfi {
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
        // Snapshot the result *before* the gate so a held older load returns its account's packages
        // and a later switch/mutation cannot retroactively change them (issue #207).
        let result = keyPackagesByAccountRef[accountRef] ?? keyPackages
        await passAccountKeyPackagesGateIfArmed()
        return result
    }

    func installKeyPackages(accountRef: String, packages: [AccountKeyPackageFfi]) {
        keyPackagesByAccountRef[accountRef] = packages
    }

    private func passAccountKeyPackagesGateIfArmed() async {
        guard accountKeyPackagesGateEnabled, accountKeyPackagesGateContinuation == nil,
            !didReachAccountKeyPackagesGate
        else { return }
        didReachAccountKeyPackagesGate = true
        await withCheckedContinuation { continuation in
            accountKeyPackagesGateContinuation = continuation
        }
    }

    func releaseAccountKeyPackagesGate() {
        accountKeyPackagesGateContinuation?.resume()
        accountKeyPackagesGateContinuation = nil
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
        guard !auditLogDeleteFailurePaths.contains(path) else {
            throw FakeMarmotRuntimeError.auditLogDeleteFailed
        }
        deletedAuditLogFilePaths.append(path)
        storedAuditLogFiles.removeAll { $0.path == path }
        return AuditLogDeleteResultFfi(stillRecording: storedAuditLogSettings.enabled)
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        recordSyncCall("notificationSettings")
        let result = notificationSettingsByAccountRef[accountRef] ?? notificationSettings
        passNotificationSettingsGateIfArmed()
        return result
    }

    func installNotificationSettings(accountRef: String, settings: NotificationSettingsFfi) {
        notificationSettingsByAccountRef[accountRef] = settings
    }

    private func passNotificationSettingsGateIfArmed() {
        notificationSettingsGate.passIfArmed()
    }

    func releaseNotificationSettingsGate() {
        notificationSettingsGate.release()
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
        var updated = notificationSettingsByAccountRef[accountRef] ?? notificationSettings
        updated.localNotificationsEnabled = enabled
        if notificationSettingsByAccountRef[accountRef] != nil {
            notificationSettingsByAccountRef[accountRef] = updated
        } else {
            notificationSettings = updated
        }
        passSetLocalNotificationsGateIfArmed()
        return updated
    }

    private func passSetLocalNotificationsGateIfArmed() {
        setLocalNotificationsGate.passIfArmed()
    }

    func releaseSetLocalNotificationsGate() {
        setLocalNotificationsGate.release()
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
        mediaRecordsByGroupId = [:]
        mediaDownloadsByPlaintextSha256 = [:]
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

    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws
        -> String
    {
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
                disappearingMessageSecs: 0,
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
        await passCreateGroupGateIfArmed()
        return "created-group"
    }

    private func passCreateGroupGateIfArmed() async {
        guard createGroupGateEnabled, createGroupGateContinuation == nil, !didReachCreateGroupGate else { return }
        didReachCreateGroupGate = true
        await withCheckedContinuation { continuation in
            createGroupGateContinuation = continuation
        }
    }

    func releaseCreateGroupGate() {
        createGroupGateContinuation?.resume()
        createGroupGateContinuation = nil
    }

    func acceptGroupInvite(accountRef: String, groupIdHex: String) async throws -> AppGroupRecordFfi {
        acceptedInviteGroupIds.append(groupIdHex)
        guard let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) else {
            throw FakeMarmotRuntimeError.unused
        }
        groups[index].pendingConfirmation = false
        if var details = groupDetailsById[groupIdHex] {
            details.group.pendingConfirmation = false
            groupDetailsById[groupIdHex] = details
            groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        }
        return groups[index]
    }

    func declineGroupInvite(accountRef: String, groupIdHex: String) async throws -> GroupInviteDeclineResultFfi {
        declinedInviteGroupIds.append(groupIdHex)
        guard let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) else {
            throw FakeMarmotRuntimeError.unused
        }
        var group = groups.remove(at: index)
        group.pendingConfirmation = false
        groupDetailsById[groupIdHex] = nil
        groupManagementStateById[groupIdHex] = nil
        return GroupInviteDeclineResultFfi(
            group: group,
            summary: SendSummaryFfi(published: 1, messageIds: ["group-decline"])
        )
    }

    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi {
        groupDetailsCallCounts[groupIdHex, default: 0] += 1
        if groupDetailsFailureGroupIds.contains(groupIdHex) {
            throw FakeMarmotRuntimeError.unused
        }
        // Snapshot the value *before* the gate so a held older load captures the older details and a
        // later mutation cannot retroactively change what it returns (issue #135 last-request-wins).
        let result: GroupDetailsFfi
        if let details = groupDetailsById[groupIdHex] {
            result = details
        } else if let group = groups.first(where: { $0.groupIdHex == groupIdHex }) {
            result = GroupDetailsFfi(group: group, members: [])
        } else {
            throw FakeMarmotRuntimeError.unused
        }
        await passGroupDetailsGateIfArmed()
        return result
    }

    private func passGroupDetailsGateIfArmed() async {
        guard groupDetailsGateEnabled, groupDetailsGateContinuation == nil, !didReachGroupDetailsGate else { return }
        didReachGroupDetailsGate = true
        await withCheckedContinuation { continuation in
            groupDetailsGateContinuation = continuation
        }
    }

    func releaseGroupDetailsGate() {
        groupDetailsGateContinuation?.resume()
        groupDetailsGateContinuation = nil
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

    func inviteMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    {
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

    func promoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    {
        promotedAdminRef = memberRef
        updateMember(groupIdHex: groupIdHex, matching: memberRef) { member in
            member.isAdmin = true
        }
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-promote")
    }

    func demoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    {
        demotedAdminRef = memberRef
        updateMember(groupIdHex: groupIdHex, matching: memberRef) { member in
            member.isAdmin = false
        }
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-demote")
    }

    func removeMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    {
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

    func updateGroupAvatarUrl(accountRef: String, groupIdHex: String, url: String?, dim: String?, thumbhash: String?)
        async throws -> SendSummaryFfi
    {
        updateGroupAvatarUrlCallCount += 1
        await passGroupAvatarUpdateGateIfArmed()

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

    private func passGroupAvatarUpdateGateIfArmed() async {
        guard groupAvatarUpdateGateEnabled,
            groupAvatarUpdateGateContinuation == nil,
            !didReachGroupAvatarUpdateGate
        else { return }
        didReachGroupAvatarUpdateGate = true
        await withCheckedContinuation { continuation in
            groupAvatarUpdateGateContinuation = continuation
        }
    }

    func releaseGroupAvatarUpdateGate() {
        groupAvatarUpdateGateContinuation?.resume()
        groupAvatarUpdateGateContinuation = nil
    }

    func updateGroupProfile(accountRef: String, groupIdHex: String, name: String?, description: String?) async throws
        -> SendSummaryFfi
    {
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

    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    {
        lastSetInboxBootstrapRelays = bootstrapRelays
        relayLists.inbox = RelayListFfi(kind: relayLists.inbox.kind, relays: relays)
        return relayLists
    }

    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    {
        lastSetNip65BootstrapRelays = bootstrapRelays
        relayLists.nip65 = RelayListFfi(kind: relayLists.nip65.kind, relays: relays)
        return relayLists
    }

    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription {
        chatListSubscriptionCount += 1
        if chatListSubscriptionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: chatListSubscriptionDelayNanoseconds)
        }
        return FakeChatListSubscription(
            rows: chatListRows(includeArchived: includeArchived),
            updates: chatListUpdates,
            endsWhenExhausted: chatListStreamEndsAfterUpdates,
            recordSnapshot: { [weak self] in
                self?.recordSyncCall("chatListSubscription.snapshot")
            }
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

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws
        -> TimelineMessagesSubscription
    {
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
            endsWhenExhausted: timelineStreamEndsAfterUpdates,
            recordSnapshot: { [weak self] in
                self?.recordSyncCall("timelineMessagesSubscription.snapshot")
            }
        )
        lastTimelineSubscription = subscription
        return subscription
    }

    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi? {
        recordSyncCall("initializeChatReadState")
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi?
    {
        recordSyncCall("markTimelineMessageRead")
        markedReadMessageIds.append(messageIdHex)
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func listMedia(accountRef: String, groupIdHex: String, limit: UInt32?) throws -> [MediaRecordFfi] {
        listMediaCallCount += 1
        let records = mediaRecordsByGroupId[groupIdHex] ?? []
        guard let limit else { return records }
        return Array(records.prefix(Int(limit)))
    }

    func downloadMedia(accountRef: String, groupIdHex: String, reference: MediaAttachmentReferenceFfi) async throws
        -> MediaDownloadResultFfi
    {
        downloadMediaCallCount += 1
        guard let download = mediaDownloadsByPlaintextSha256[reference.plaintextSha256] else {
            throw FakeMarmotRuntimeError.unused
        }
        await passMediaDownloadGateIfArmed()
        return download
    }

    func uploadMedia(accountRef: String, groupIdHex: String, request: MediaUploadRequestFfi) async throws
        -> MediaUploadResultFfi
    {
        uploadMediaCallCount += 1
        uploadedMedia = UploadedMedia(groupIdHex: groupIdHex, request: request)
        await passMessageActionGateIfArmed()
        let attachments = request.attachments.enumerated().map { index, attachment in
            MediaUploadAttachmentResultFfi(
                reference: MediaAttachmentReferenceFfi(
                    locators: [MediaLocatorFfi(kind: "blossom", value: "https://example.com/media-\(index)")],
                    ciphertextSha256: "cipher-\(index)",
                    plaintextSha256: "plain-\(index)",
                    nonceHex: "nonce-\(index)",
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    version: "m1",
                    sourceEpoch: 1,
                    dim: attachment.dim,
                    thumbhash: attachment.thumbhash
                ),
                encryptedSizeBytes: UInt64(attachment.plaintext.count + 16)
            )
        }
        return MediaUploadResultFfi(
            attachments: attachments,
            sent: request.send ? SendSummaryFfi(published: 1, messageIds: ["media"]) : nil
        )
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        sendTextCallCount += 1
        sentText = SentText(groupIdHex: groupIdHex, text: text)
        await passMessageActionGateIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["text"])
    }

    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws
        -> SendSummaryFfi
    {
        replyToMessageCallCount += 1
        repliedMessage = SentReply(groupIdHex: groupIdHex, targetMessageId: targetMessageId, text: text)
        await passMessageActionGateIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["reply"])
    }

    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws
        -> SendSummaryFfi
    {
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

    /// Suspends the first media download FFI call when the gate is armed, after the fake runtime
    /// has captured the bytes it will return. This models a network download completing after a
    /// user-initiated purge has already removed the account/cache.
    private func passMediaDownloadGateIfArmed() async {
        let shouldSuspend = mediaDownloadGateLock.withLock {
            mediaDownloadGateEnabled && mediaDownloadGateContinuation == nil && !mediaDownloadGateReached
        }
        guard shouldSuspend else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = mediaDownloadGateLock.withLock {
                mediaDownloadGateContinuation = continuation
                mediaDownloadGateReached = true
                if mediaDownloadGateReleased {
                    mediaDownloadGateContinuation = nil
                    return true
                }
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseMediaDownloadGate() {
        let continuation = mediaDownloadGateLock.withLock {
            mediaDownloadGateReleased = true
            let continuation = mediaDownloadGateContinuation
            mediaDownloadGateContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    // MARK: - darkmatter 745959e FFI additions

    var parseMarkdownCallCount = 0
    var signOutCallCount = 0
    var signedOutAccountRefs: [String] = []
    var signInAccountCallCount = 0
    var revealNsecCallCount = 0
    var exportEncryptedSecretKeyCallCount = 0
    var deleteGroupLocalCallCount = 0
    var locallyDeletedGroupIds: [String] = []
    var updateMessageRetentionCallCount = 0
    var lastRetentionSecs: UInt64?
    var secureDeleteExpiredCallCount = 0
    var secureDeleteExpiredGateEnabled = false
    private(set) var didReachSecureDeleteExpiredGate = false
    private var secureDeleteExpiredGateContinuation: CheckedContinuation<Void, Never>?
    var accountUnreadSummaryRows: [AccountUnreadFfi] = []

    func parseMarkdown(text: String) -> MarkdownDocumentFfi {
        parseMarkdownCallCount += 1
        return MarkdownDocumentFfi(blocks: [], truncated: false)
    }

    func accountUnreadSummary() throws -> [AccountUnreadFfi] {
        accountUnreadSummaryRows
    }

    func signOut(accountRef: String, deleteKeyPackages: Bool) async throws -> SignOutOutcomeFfi {
        signOutCallCount += 1
        signedOutAccountRefs.append(accountRef)
        return SignOutOutcomeFfi(
            keyPackagesDeleted: 0,
            keyPackageFailures: [],
            localCleanup: LocalCleanupReportFfi(completed: true, reason: nil)
        )
    }

    func signInAccount(accountRef: String) async throws -> AccountSummaryFfi {
        signInAccountCallCount += 1
        return AccountSummaryFfi(
            label: accountRef,
            accountIdHex: accountRef,
            localSigning: true,
            signedOut: false,
            running: true
        )
    }

    func revealNsec(accountRef: String) throws -> String {
        revealNsecCallCount += 1
        return "nsec1fake"
    }

    func exportEncryptedSecretKey(accountRef: String, passphrase: String) throws -> String {
        exportEncryptedSecretKeyCallCount += 1
        return "ncryptsec1fake"
    }

    func deleteGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool {
        deleteGroupLocalCallCount += 1
        locallyDeletedGroupIds.append(groupIdHex)
        return true
    }

    func updateMessageRetention(accountRef: String, groupIdHex: String, disappearingMessageSecs: UInt64) async throws
        -> SendSummaryFfi
    {
        updateMessageRetentionCallCount += 1
        lastRetentionSecs = disappearingMessageSecs
        return SendSummaryFfi(published: 1, messageIds: ["retention"])
    }

    func secureDeleteExpired(accountRef: String, groupIdHex: String) async throws -> SecureDeleteExpiredResultFfi {
        secureDeleteExpiredCallCount += 1
        await passSecureDeleteExpiredGateIfArmed()
        return SecureDeleteExpiredResultFfi(prunedMessages: 0, mediaCiphertextSha256: [])
    }

    private func passSecureDeleteExpiredGateIfArmed() async {
        guard secureDeleteExpiredGateEnabled, secureDeleteExpiredGateContinuation == nil,
            !didReachSecureDeleteExpiredGate
        else { return }
        didReachSecureDeleteExpiredGate = true
        await withCheckedContinuation { continuation in
            secureDeleteExpiredGateContinuation = continuation
        }
    }

    func releaseSecureDeleteExpiredGate() {
        secureDeleteExpiredGateContinuation?.resume()
        secureDeleteExpiredGateContinuation = nil
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
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: latest?.timelineAt,
            updatedAt: latest?.timelineAt ?? 0
        )
    }
}

private enum FakeMarmotRuntimeError: Error, LocalizedError {
    case missingCreatedAccount
    case auditLogDeleteFailed
    case unused

    var errorDescription: String? {
        switch self {
        case .missingCreatedAccount:
            return "Missing created account."
        case .auditLogDeleteFailed:
            return "Audit log delete failed."
        case .unused:
            return "Unused fake runtime error."
        }
    }
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

private struct UploadedMedia: Equatable {
    let groupIdHex: String
    let request: MediaUploadRequestFfi
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
    private let recordSnapshot: () -> Void

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.rows = []
        self.updates = []
        self.endsWhenExhausted = true
        self.recordSnapshot = {}
        super.init(unsafeFromRawPointer: pointer)
    }

    init(
        rows: [ChatListRowFfi],
        updates: [ChatListSubscriptionUpdateFfi] = [],
        endsWhenExhausted: Bool = false,
        recordSnapshot: @escaping () -> Void = {}
    ) {
        self.rows = rows
        self.updates = updates
        self.endsWhenExhausted = endsWhenExhausted
        self.recordSnapshot = recordSnapshot
        super.init(noPointer: NoPointer())
    }

    override func snapshot() -> [ChatListRowFfi] {
        recordSnapshot()
        return rows
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
    private let recordSnapshot: () -> Void
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
        self.recordSnapshot = {}
        super.init(unsafeFromRawPointer: pointer)
    }

    init(
        messages: [TimelineMessageRecordFfi],
        limit: Int,
        windowCap: Int,
        updates: [TimelineSubscriptionUpdateFfi] = [],
        updateDelayNanoseconds: UInt64 = 0,
        endsWhenExhausted: Bool = false,
        recordSnapshot: @escaping () -> Void = {}
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
        self.recordSnapshot = recordSnapshot
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
        recordSnapshot()
        return windowPage()
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

    /// Dequeue the next queued signal, mutate the fake's server-side `fullSet` and
    /// re-window `lo`/`hi` exactly as the runtime's `recv()` does, and hand back both the
    /// original update (so `nextUpdate()` can surface the raw `.projection`) and the
    /// re-materialized window (what a `.page`/`snapshot()` observes). Shared by `next()`
    /// and `nextUpdate()` so both stay faithful to the same windowing contract.
    private func consumeSignalApplyingWindow() -> (update: TimelineSubscriptionUpdateFfi, page: TimelinePageFfi) {
        let update = updates.removeFirst()
        let priorSpan = hi - lo
        let wasAnchored = hi >= fullSet.messages.count
        switch update {
        case .page(let page):
            // A head `.page` refresh never replaces a scrolled-back (detached) window.
            if wasAnchored {
                for message in page.messages {
                    if let index = fullSet.messages.firstIndex(where: { $0.messageIdHex == message.messageIdHex }) {
                        fullSet.messages[index] = message
                    } else {
                        fullSet.messages.append(message)
                    }
                }
                fullSet.sortCanonical()
            }
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
        return (update, windowPage())
    }

    override func next() async -> TimelinePageFfi? {
        guard !updates.isEmpty else {
            if endsWhenExhausted { return nil }
            return await awaitSubscriptionCancellation()
        }
        if updateDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: updateDelayNanoseconds)
        }
        return consumeSignalApplyingWindow().page
    }

    override func nextUpdate() async -> TimelineSubscriptionUpdateFfi? {
        guard !updates.isEmpty else {
            if endsWhenExhausted { return nil }
            return await awaitSubscriptionCancellation()
        }
        if updateDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: updateDelayNanoseconds)
        }
        let (update, page) = consumeSignalApplyingWindow()
        // Mirror the runtime: a refresh surfaces the re-materialized window as a `.page`,
        // while a projection surfaces the raw delta for the client to apply incrementally.
        switch update {
        case .page:
            return .page(page: page)
        case .projection:
            return update
        }
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
                case .upsert(trigger: _, let message):
                    upsert(message)
                case .remove(let messageIdHex, reason: _):
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
    var requestAuthorizationGateEnabled = false
    private(set) var didReachRequestAuthorizationGate = false
    private var requestAuthorizationGateContinuation: CheckedContinuation<Void, Never>?
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
        if requestAuthorizationGateEnabled {
            didReachRequestAuthorizationGate = true
            await withCheckedContinuation { continuation in
                requestAuthorizationGateContinuation = continuation
            }
        }
        if let requestError {
            throw requestError
        }
        status = requestedStatus
        return status
    }

    func releaseRequestAuthorizationGate() {
        requestAuthorizationGateContinuation?.resume()
        requestAuthorizationGateContinuation = nil
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
    let reactionsByTarget = Dictionary(
        grouping: messages.compactMap { message -> TimelineUserReactionFfi? in
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
                        media: [],
                        agentTextStreamJson: nil,
                        deleted: false
                    )
                }
            },
            mediaJson: nil,
            media: [],
            agentTextStreamJson: nil,
            groupSystem: nil,
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
    reactions: TimelineReactionSummaryFfi = projectedReactionSummary([]),
    contentTokens: MarkdownDocumentFfi = emptyMarkdownDocument(),
    deleted: Bool = false,
    invalidationStatus: String? = nil
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: id,
        sourceMessageIdHex: nil,
        direction: direction,
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        contentTokens: contentTokens,
        kind: kind,
        tags: tags,
        timelineAt: recordedAt,
        receivedAt: recordedAt,
        replyToMessageIdHex: nil,
        replyPreview: nil,
        mediaJson: mediaJson,
        media: [],
        agentTextStreamJson: agentTextStreamJson,
        groupSystem: nil,
        reactions: reactions,
        deleted: deleted,
        deletedByMessageIdHex: nil,
        invalidationStatus: invalidationStatus
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
        unreadMentionCount: 0,
        unreadMention: false,
        firstUnreadMessageIdHex: nil,
        lastReadMessageIdHex: nil,
        lastReadTimelineAt: nil,
        updatedAt: timelineAt
    )
}

private func chatListOrderingTestItem(
    id: String,
    title: String,
    preview: String = "preview",
    updatedAt: UInt64,
    unreadCount: Int = 1
) -> ChatItem {
    chatListOrderingTestItem(
        id: id,
        title: title,
        preview: preview,
        date: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
        unreadCount: unreadCount
    )
}

private func chatListOrderingTestItem(
    id: String,
    title: String,
    preview: String = "preview",
    date: Date?,
    unreadCount: Int = 1
) -> ChatItem {
    ChatItem(
        id: id,
        title: title,
        subtitle: "Group message",
        preview: preview,
        updatedAt: date,
        avatarSeed: id,
        pictureURL: nil,
        unreadCount: unreadCount,
        isDirect: false,
        pendingConfirmation: false
    )
}

private func performanceChatItems(count: Int) -> [ChatItem] {
    (0..<count).map { index in
        let id = "perf-chat-\(index)"
        let preview = index.isMultiple(of: 100) ? "launch planning \(index)" : "ordinary preview \(index)"
        let updatedAt = Date(timeIntervalSince1970: Double(2_000_000_000 - index))
        let unreadCount = index % 5
        let unreadMentionCount = index % 2
        return ChatItem(
            id: id,
            title: "Performance Chat \(index)",
            subtitle: "npub\(index)",
            preview: preview,
            updatedAt: updatedAt,
            avatarSeed: id,
            pictureURL: nil,
            unreadCount: unreadCount,
            unreadMentionCount: unreadMentionCount,
            isDirect: index.isMultiple(of: 3),
            pendingConfirmation: false
        )
    }
}

private func projectedReactionSummary(_ reactions: [TimelineUserReactionFfi]) -> TimelineReactionSummaryFfi {
    let byEmoji = Dictionary(grouping: reactions, by: \.emoji)
        .map { emoji, reactions in
            TimelineReactionEmojiFfi(emoji: emoji, count: UInt32(reactions.count), senders: reactions.map(\.sender))
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
private func waitFor(attempts: Int = 100, _ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<attempts {
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

private final class RemoteImageURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var delay: TimeInterval = 0
    private static var requests = 0
    private static var stops = 0
    private var stopped = false

    static func reset(data: Data, responseDelay: TimeInterval) {
        lock.lock()
        responseData = data
        delay = responseDelay
        requests = 0
        stops = 0
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func stopLoadingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (data, responseDelay) = Self.recordRequest()
        let complete = { [weak self] in
            guard let self, let url = self.request.url, !self.isStopped else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if responseDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + responseDelay) {
                complete()
            }
        } else {
            complete()
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stops += 1
        stopped = true
        Self.lock.unlock()
    }

    private static func recordRequest() -> (Data, TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        return (responseData, delay)
    }

    private var isStopped: Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return stopped
    }
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
        isMention: false,
        messageIdHex: "\(notificationKey)-message",
        sender: NotificationUserFfi(
            accountIdHex: isFromSelf
                ? account.accountIdHex : "alice1234567890alice1234567890alice1234567890alice1234567890",
            displayName: senderName,
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: account.accountIdHex,
            displayName: account.label,
            pictureUrl: nil
        ),
        previewText: previewText,
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: 1_700_000_000_000,
        isFromSelf: isFromSelf
    )
}

private func desktopAccount() -> AccountSummaryFfi {
    AccountSummaryFfi(
        label: "Desktop Account",
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        localSigning: true,
        signedOut: false,
        running: true
    )
}

private func keyPackageFixture(accountRef: String, eventIdHex: String) -> AccountKeyPackageFfi {
    AccountKeyPackageFfi(
        accountRef: accountRef,
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        keyPackageId: "slot-\(eventIdHex)",
        keyPackageRefHex: "ref-\(eventIdHex)",
        eventIdHex: eventIdHex,
        publishedAt: 1_700_000_000,
        keyPackageBytes: 512,
        sourceRelays: MarmotClient.seedRelays,
        local: true,
        relay: false
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
        otherIsAdmin ? aliceIdHex : nil,
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
            ),
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

/// A thread-safe mutable clock for tests that need to advance the wall clock from an
/// off-main FFI batch (e.g. modelling a slow profile-resolution batch) while reading it
/// from the main-actor `nowProvider` (whitenoise-mac#181).
private final class ConcurrentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(now: Date) { self.current = now }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
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
        disappearingMessageSecs: 0,
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
        disappearingMessageSecs: 0,
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

private func mediaAttachmentReference(
    sourceEpoch: UInt64 = 0,
    mediaType: String,
    fileName: String,
    ciphertextSha256: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    plaintextSha256: String = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    nonceHex: String = "cccccccccccccccccccccccc"
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [
            MediaLocatorFfi(kind: "blossom", value: "https://blob.example/\(fileName)")
        ],
        ciphertextSha256: ciphertextSha256,
        plaintextSha256: plaintextSha256,
        nonceHex: nonceHex,
        fileName: fileName,
        mediaType: mediaType,
        version: "marmot.encrypted-media.v1",
        sourceEpoch: sourceEpoch,
        dim: mediaType.hasPrefix("image/") ? "120x80" : nil,
        thumbhash: nil
    )
}

private func mediaJson(for reference: MediaAttachmentReferenceFfi) -> String {
    let tag = mediaIMetaTag(for: reference).values
    return mediaJSONString(fromJSONObject: ["imeta": [tag]])
}

private func mediaJson(for reference: MediaAttachmentReferenceFfi, appendingIMetaField field: String) -> String {
    var tag = mediaIMetaTag(for: reference).values
    tag.append(field)
    return mediaJSONString(fromJSONObject: ["imeta": [tag]])
}

private func mediaJson(for reference: MediaAttachmentReferenceFfi, sourceEpochKey key: String) -> String {
    let tag = mediaIMetaTag(for: reference).values
    return mediaJSONString(fromJSONObject: ["imeta": [tag], key: NSNumber(value: reference.sourceEpoch)])
}

private func mediaJson(
    for reference: MediaAttachmentReferenceFfi,
    sourceEpochKey key: String,
    rawSourceEpoch: NSNumber
) -> String {
    let tag = mediaIMetaTag(for: reference).values
    return mediaJSONString(fromJSONObject: ["imeta": [tag], key: rawSourceEpoch])
}

private func mediaJson(for reference: MediaAttachmentReferenceFfi, mediaObjectDepth depth: Int) -> String {
    var object: [String: Any] = ["imeta": [mediaIMetaTag(for: reference).values]]
    for _ in 0..<depth {
        object = ["media": object]
    }
    return mediaJSONString(fromJSONObject: object)
}

private func mediaJson(for reference: MediaAttachmentReferenceFfi, arrayDepth depth: Int) -> String {
    var object: Any = ["imeta": [mediaIMetaTag(for: reference).values]]
    for _ in 0..<depth {
        object = [object]
    }
    return mediaJSONString(fromJSONObject: object)
}

private func mediaJsonWithIMetaAndFlatKeys(for reference: MediaAttachmentReferenceFfi) -> String {
    let object: [String: Any] = [
        "imeta": [mediaIMetaTag(for: reference).values],
        "ciphertext_sha256": reference.ciphertextSha256,
        "plaintext_sha256": reference.plaintextSha256,
        "nonce": reference.nonceHex,
        "file_name": reference.fileName,
        "media_type": reference.mediaType,
        "version": reference.version,
    ]
    return mediaJSONString(fromJSONObject: object)
}

private func mediaJSONString(fromJSONObject object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private func mediaIMetaTag(for reference: MediaAttachmentReferenceFfi) -> MessageTagFfi {
    var values = ["imeta"]
    values.append(contentsOf: reference.locators.map { "locator \($0.kind) \($0.value)" })
    values.append("ciphertext_sha256 \(reference.ciphertextSha256)")
    values.append("plaintext_sha256 \(reference.plaintextSha256)")
    values.append("nonce \(reference.nonceHex)")
    values.append("filename \(reference.fileName)")
    values.append("m \(reference.mediaType)")
    values.append("v \(reference.version)")
    if let dim = reference.dim {
        values.append("dim \(dim)")
    }
    if let thumbhash = reference.thumbhash {
        values.append("thumbhash \(thumbhash)")
    }
    return MessageTagFfi(values: values)
}

private func performanceMessageItems(count: Int, groupIdHex: String = "perf-group") -> [MessageItem] {
    let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    let richMarkdown = richMarkdownDocumentForPerformance()
    let compactMarkdown = MarkdownDocumentFfi(
        blocks: [
            .paragraph(inlines: [
                .text(content: "Compact update with "),
                .strong(children: [.text(content: "status")]),
                .text(content: " and "),
                .code(content: "trace_id"),
                .text(content: "."),
            ])
        ],
        truncated: false
    )

    return (0..<count).map { index in
        let isOutgoing = index.isMultiple(of: 2)
        let markdown: MarkdownDocumentFfi?
        if index.isMultiple(of: 5) {
            markdown = richMarkdown
        } else if index.isMultiple(of: 3) {
            markdown = compactMarkdown
        } else {
            markdown = nil
        }

        return MessageItem(
            id: "perf-\(index)",
            groupIdHex: groupIdHex,
            senderAccountIdHex: isOutgoing ? "self" : "alice",
            senderName: isOutgoing ? "Jeff" : "Alice",
            body: """
                Performance transcript fixture \(index). This row is intentionally long \
                enough to wrap across multiple lines and exercise bubble layout while \
                remaining deterministic.
                """,
            contentMarkdown: markdown,
            sentAt: baseDate.addingTimeInterval(TimeInterval(index)),
            timelineAt: UInt64(1_800_000_000 + index),
            isOutgoing: isOutgoing
        )
    }
}

private func richMarkdownDocumentForPerformance() -> MarkdownDocumentFfi {
    MarkdownDocumentFfi(
        blocks: [
            .heading(
                level: 3,
                inlines: [
                    .text(content: "Release checklist")
                ]),
            .paragraph(inlines: [
                .text(content: "Review "),
                .strong(children: [.text(content: "rendering")]),
                .text(content: ", validate "),
                .emph(children: [.text(content: "scroll position")]),
                .text(content: ", and open "),
                .link(
                    dest: "https://example.com/perf",
                    title: nil,
                    children: [.text(content: "perf notes")]
                ),
                .text(content: "."),
            ]),
            .list(
                kind: .bullet(marker: "-"),
                tight: true,
                items: [
                    MarkdownListItemFfi(
                        blocks: [
                            .paragraph(inlines: [.text(content: "No jump when older history prepends")])
                        ],
                        checked: nil
                    ),
                    MarkdownListItemFfi(
                        blocks: [
                            .paragraph(inlines: [.text(content: "No full transcript diff for one update")])
                        ],
                        checked: true
                    ),
                ]
            ),
            .table(
                alignments: [.left, .right],
                header: [
                    MarkdownTableCellFfi(inlines: [.text(content: "Path")]),
                    MarkdownTableCellFfi(inlines: [.text(content: "Target")]),
                ],
                rows: [
                    [
                        MarkdownTableCellFfi(inlines: [.code(content: "body")]),
                        MarkdownTableCellFfi(inlines: [.text(content: "< 16ms")]),
                    ],
                    [
                        MarkdownTableCellFfi(inlines: [.code(content: "diff")]),
                        MarkdownTableCellFfi(inlines: [.text(content: "bounded")]),
                    ],
                ]
            ),
            .codeBlock(kind: .fenced, info: "swift", content: "let row = ConversationMessageRow(message: item)"),
        ],
        truncated: false
    )
}

/// Absolute wall-clock performance guards apply a fixed slack multiplier so they stay
/// reliable across wildly different hardware — fast local dev machines vs. loaded, shared
/// CI runners (a hosted macos-26 runner clocked the indexed-upsert guard at ~870ms against a
/// 500ms base). They exist to catch order-of-magnitude regressions, not runner variance.
/// NB: Xcode does not propagate the shell `CI` env var into the xctest host process, so
/// detecting CI from here is unreliable; a uniform margin is simpler and dependable.
private let performanceSlack: Double = 5

private func measuredMilliseconds(_ work: () -> Void) -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    work()
    return (CFAbsoluteTimeGetCurrent() - start) * 1_000
}

private func measuredMillisecondsAsync(_ work: () async -> Void) async -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    await work()
    return (CFAbsoluteTimeGetCurrent() - start) * 1_000
}

private func formatMilliseconds(_ milliseconds: Double) -> String {
    String(format: "%.2f", milliseconds)
}

private func messageMediaDiskCache(
    root: URL,
    keyData: Data = Data(repeating: 0x42, count: 32),
    keyDeleter: @escaping @Sendable () -> Void = {}
) -> MessageMediaDiskCache {
    MessageMediaDiskCache(
        directoryResolver: { root },
        keyProvider: { SymmetricKey(data: keyData) },
        keyDeleter: keyDeleter
    )
}

private func mediaDiskCacheReference(
    plaintext: Data,
    ciphertextByte: UInt8 = 0xcc
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [],
        ciphertextSha256: String(repeating: String(format: "%02x", ciphertextByte), count: 32),
        plaintextSha256: hexSHA256(plaintext),
        nonceHex: String(repeating: "00", count: 12),
        fileName: "cached.bin",
        mediaType: "application/octet-stream",
        version: "encrypted-media-v1",
        sourceEpoch: 7,
        dim: nil,
        thumbhash: nil
    )
}

private func hexSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func dataContains(_ haystack: Data, _ needle: Data) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for offset in 0...(haystack.count - needle.count) {
        if haystack[offset..<(offset + needle.count)].elementsEqual(needle) {
            return true
        }
    }
    return false
}

private func emptyMarkdownDocument() -> MarkdownDocumentFfi {
    MarkdownDocumentFfi(blocks: [], truncated: false)
}

private func nestedBlockQuote(depth: Int, leaf: MarkdownBlockFfi) -> MarkdownBlockFfi {
    var block = leaf
    for _ in 0..<depth {
        block = .blockQuote(blocks: [block])
    }
    return block
}

private func nestedStrong(depth: Int, leaf: MarkdownInlineFfi) -> MarkdownInlineFfi {
    var inline = leaf
    for _ in 0..<depth {
        inline = .strong(children: [inline])
    }
    return inline
}

private func blockQuoteNestingDepth(_ blocks: [MarkdownDisplayBlockNode]) -> Int {
    var depth = 0
    var current = blocks
    while case .blockQuote(let inner)? = current.first?.block {
        depth += 1
        current = inner
    }
    return depth
}

private func firstParagraph(in blocks: [MarkdownDisplayBlockNode]) -> AttributedString? {
    for node in blocks {
        switch node.block {
        case .paragraph(let text):
            return text
        case .blockQuote(let inner):
            if let found = firstParagraph(in: inner) {
                return found
            }
        case .list(let items):
            for item in items {
                if let found = firstParagraph(in: item.blocks) {
                    return found
                }
            }
        default:
            continue
        }
    }
    return nil
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
