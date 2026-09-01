//
//  AccountTests.swift
//  whitenoise-macTests
//
//  Identity lifecycle: onboarding, sign-up and login, adding and removing accounts,
//  switching between them, signing out, deleting all data, and the unread badges.
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

struct AccountTests: WorkspaceTestSupport {
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
            externalSigning: false,
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
            externalSigning: false,
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

    /// The way back into a deactivated identity, now that no surface offers to reactivate one
    /// with a click while nothing is signed in.
    ///
    /// The core does the reactivating: `create_or_import_account` looks for a signed-out account
    /// matching the key before creating anything, clears its signed-out flag, and returns that
    /// same account — so the identity's local chats, media, and settings come back with it rather
    /// than a second identity appearing beside it. What this pins is the app's half: one row, not
    /// two, and it is the active one.
    @MainActor
    @Test func loggingInWithADeactivatedIdentitysKeyReactivatesThatSameRow() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let signedOut = signedOutBackupAccount()
        // What the core hands back: the *same* account id, no longer signed out.
        let reactivated = AccountSummaryFfi(
            label: signedOut.label,
            accountIdHex: signedOut.accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [signedOut], createdAccount: reactivated)
        UserDefaults.standard.set(signedOut.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        // The premise: nothing is signed in, so the app is on the login surface with no chooser.
        #expect(state.phase == .onboarding)

        state.showLogin()
        state.loginIdentity = "nsec1backup"
        await state.login()

        #expect(state.phase == .ready)
        #expect(state.showsMessengerChrome)
        // One row, not two: the identity was reactivated, not duplicated.
        #expect(state.accounts.map(\.id) == [signedOut.label])
        #expect(state.signedInAccounts.map(\.id) == [signedOut.label])
        #expect(state.activeAccountId == signedOut.label)
        // The key does not outlive the pane it was typed into (#32).
        #expect(state.loginIdentity == "")
    }

    @MainActor
    @Test func signUpMarksOnlyTheSignUpPathAsAuthenticating() async throws {
        // Both authentication buttons used to read a single `isAuthenticating` bool, so creating
        // an identity also put the "Log in" button into its "Logging in..." loading label. Only
        // the running path reports progress; the other is disabled via `isAuthenticating`.
        let created = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: created)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.authenticationActivity == nil)
        #expect(!state.isAuthenticating)

        runtime.createIdentityGateEnabled = true
        async let pendingSignUp: Void = state.signUp()
        while !runtime.didReachCreateIdentityGate {
            await Task.yield()
        }

        #expect(state.authenticationActivity == .signUp)
        #expect(state.authenticationActivity != .login)
        #expect(state.isAuthenticating)

        runtime.releaseCreateIdentityGate()
        await pendingSignUp

        #expect(state.authenticationActivity == nil)
        #expect(!state.isAuthenticating)
    }

    @MainActor
    @Test func loginMarksOnlyTheLoginPathAsAuthenticating() async throws {
        let loggedIn = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: loggedIn)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1desktop"

        runtime.loginGateEnabled = true
        async let pendingLogin: Void = state.login()
        while !runtime.didReachLoginGate {
            await Task.yield()
        }

        #expect(state.authenticationActivity == .login)
        #expect(state.authenticationActivity != .signUp)
        #expect(state.isAuthenticating)

        runtime.releaseLoginGate()
        await pendingLogin

        #expect(state.authenticationActivity == nil)
        #expect(!state.isAuthenticating)
    }

    // MARK: - The one-time "Help Improve White Noise" prompt

    /// Injected everywhere below, never `UserDefaults.standard`: an un-injected store writes into
    /// the test host's own preferences, so the first run would record the account and every later
    /// run would find it already offered and pass for the wrong reason.
    @MainActor
    final class FakeImprovementsPromptStore: ImprovementsPromptStoring {
        private(set) var offered: Set<String>
        private(set) var clearAllCallCount = 0

        init(offered: Set<String> = []) {
            self.offered = offered
        }

        func hasBeenOffered(toOwnerAccountIdHex accountIdHex: String) -> Bool {
            offered.contains(accountIdHex.lowercased())
        }

        func markOffered(toOwnerAccountIdHex accountIdHex: String) {
            offered.insert(accountIdHex.lowercased())
        }

        func forget(ownerAccountIdHex accountIdHex: String) {
            offered.remove(accountIdHex.lowercased())
        }

        func clearAll() {
            clearAllCallCount += 1
            offered.removeAll()
        }
    }

    private static let improvementsPromptAccountIdHex =
        "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

    @MainActor
    private static func improvementsPromptWorkspace(
        store: FakeImprovementsPromptStore
    ) -> (WorkspaceState, FakeMarmotRuntime) {
        let created = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: improvementsPromptAccountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: created)
        let state = WorkspaceState(improvementsPromptStore: store, clientFactory: { runtime })
        return (state, runtime)
    }

    @MainActor
    @Test func signingUpOffersTheImprovementsPromptOverAReadyChatsScreen() async throws {
        let store = FakeImprovementsPromptStore()
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        await state.signUp()

        // `wn-ios-prototype` presents this over Chats rather than as a step inside the onboarding
        // panes, precisely so the account is already usable if it is dismissed without a decision.
        #expect(state.phase == .ready)
        #expect(state.showsMessengerChrome)
        #expect(state.isImprovementsPromptPresented)
    }

    @MainActor
    @Test func signingInOffersTheImprovementsPrompt() async throws {
        let store = FakeImprovementsPromptStore()
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1desktop"
        await state.login()

        #expect(state.phase == .ready)
        #expect(state.isImprovementsPromptPresented)
    }

    /// The defect this exists for: an identity that already answered — or deliberately declined by
    /// closing — being asked again on its next sign-in.
    @MainActor
    @Test func anIdentityAlreadyOfferedTheImprovementsChoiceIsNotAskedAgain() async throws {
        let store = FakeImprovementsPromptStore(offered: [Self.improvementsPromptAccountIdHex])
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1desktop"
        await state.login()

        #expect(state.phase == .ready)
        #expect(!state.isImprovementsPromptPresented)
    }

    /// Recorded when it goes up, not when it comes down. Dismissing is a valid answer ("leave both
    /// off"), and the prompt is only ever reached from a fresh sign-up or sign-in — so a quit with
    /// it still open must not leave the identity un-asked forever *or* asked twice.
    @MainActor
    @Test func theIdentityIsRecordedTheMomentTheImprovementsPromptIsPresented() async throws {
        let store = FakeImprovementsPromptStore()
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        await state.signUp()

        #expect(store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))

        state.dismissImprovementsPrompt()
        #expect(!state.isImprovementsPromptPresented)
        #expect(store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))
    }

    /// The regression that shipped: the hook went on `signUp()`, which **no view calls**. The
    /// sign-up pane's button runs `completeSignUp()`, in a different file, so a real sign-up
    /// reached Chats with no prompt while `signUpOffers…` above passed against a dead path.
    ///
    /// Driven exactly as `OnboardingSignUpView` drives it — set the draft, press the button —
    /// rather than through `signUp()`, so it keeps failing if the pane is ever repointed again.
    @MainActor
    @Test func completingSignUpFromThePaneOffersTheImprovementsPrompt() async throws {
        let store = FakeImprovementsPromptStore()
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        state.showSignUp()
        state.signUpDraft.displayName = "Pepi"
        await state.completeSignUp()

        #expect(state.lastError == nil)
        #expect(state.phase == .ready)
        #expect(state.isImprovementsPromptPresented)
        #expect(store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))
    }

    /// Backing out of the sign-up pane *after* the identity was minted goes forward into the app
    /// rather than back to the landing pane — a first entry to Chats like any other, so it is
    /// offered the choice too. Reaching it needs a publish failure to leave the account behind.
    @MainActor
    @Test func leavingTheSignUpPaneWithAMintedIdentityOffersTheImprovementsPrompt() async throws {
        let store = FakeImprovementsPromptStore()
        let (state, runtime) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        state.showSignUp()
        state.signUpDraft.displayName = "Pepi"
        runtime.publishUserProfileError = FakeMarmotRuntimeError.profilePublishFailed
        await state.completeSignUp()

        // The identity exists, the profile never published, and the pane is still up.
        #expect(state.lastError != nil)
        #expect(!state.isImprovementsPromptPresented)

        await state.cancelSignUp()

        #expect(state.phase == .ready)
        #expect(state.isImprovementsPromptPresented)
    }

    /// Launch is not a first entry: an identity already on this Mac is restored by `bootstrap()`,
    /// which reaches `activateReadyState()` like the sign-up paths do and must stay silent.
    @MainActor
    @Test func relaunchingIntoAnExistingIdentityDoesNotOfferTheImprovementsPrompt() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: Self.improvementsPromptAccountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let store = FakeImprovementsPromptStore()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(improvementsPromptStore: store, clientFactory: { runtime })

        await state.bootstrap()

        #expect(state.phase == .ready)
        #expect(!state.isImprovementsPromptPresented)
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))
    }

    @MainActor
    @Test func removingAnIdentityDropsItsImprovementsPromptRecord() async throws {
        let store = FakeImprovementsPromptStore()
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        await state.signUp()
        #expect(store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))

        state.dismissImprovementsPrompt()
        await state.removeActiveAccount()

        // A later sign-in with the same key is a fresh identity on this Mac, and inherits nothing.
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))
    }

    /// "Erase App Data" resets the Mac to a newly installed state, which has asked nobody.
    @MainActor
    @Test func resettingToANewInstallClearsEveryImprovementsPromptRecord() async throws {
        let store = FakeImprovementsPromptStore(
            offered: [Self.improvementsPromptAccountIdHex, "0011"]
        )
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        state.isImprovementsPromptPresented = true
        state.resetToNewInstallState(storageRootPath: TestStorageRoot.isolated.resolvedPath())

        #expect(store.clearAllCallCount == 1)
        #expect(store.offered.isEmpty)
        #expect(!state.isImprovementsPromptPresented)
    }

    /// The prompt belongs to the identity that *entered* the session, not to whoever is active by
    /// the time it goes up.
    ///
    /// `activateReadyState()` flips `phase` to `.ready` before the rest of its own awaits, leaving
    /// Chats — and the Settings account switcher — reachable for the remainder of the call. A
    /// switch landing in that window used to spend the switched-to account's one lifetime offer on
    /// a moment that is not its first entry, while the identity that actually just signed in went
    /// un-asked. Driven by calling with a mismatched identity rather than by racing the awaits, so
    /// the guard is pinned deterministically.
    @MainActor
    @Test func theImprovementsPromptIsDroppedWhenTheIdentityChangedWhileEntering() async throws {
        let store = FakeImprovementsPromptStore(offered: [Self.improvementsPromptAccountIdHex])
        let (state, _) = Self.improvementsPromptWorkspace(store: store)

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1desktop"
        await state.login()
        #expect(!state.isImprovementsPromptPresented)

        // The identity now active has never been offered the choice, so the record is no longer
        // what keeps the prompt down — only the identity guard is.
        store.clearAll()

        let identityThatEntered = String(repeating: "f", count: 64)
        state.presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: identityThatEntered)

        #expect(!state.isImprovementsPromptPresented)
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: identityThatEntered))

        // Positive control: the guard refuses a *mismatch*, not every caller. Without this the
        // test above would still pass if the prompt had simply been broken outright.
        state.presentImprovementsPromptIfNeeded(
            forEnteredAccountIdHex: Self.improvementsPromptAccountIdHex
        )

        #expect(state.isImprovementsPromptPresented)
        #expect(store.hasBeenOffered(toOwnerAccountIdHex: Self.improvementsPromptAccountIdHex))
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
            externalSigning: false,
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
            externalSigning: false,
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
    @Test func overlappingAuditLogFileLoadsCoalesceWhileLoadIsInFlight() async throws {
        // Regression for #366: loadAuditLogFiles() owns a shared spinner flag. A second
        // overlapping load must not enqueue a concurrent FFI fetch whose completion can race
        // the first load's defer, but it should request one fresh pass after the current load
        // so mutation-triggered refreshes are not dropped.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        runtime.clearSyncCallThreadRecords()
        runtime.auditLogFilesGateEnabled = true

        async let firstLoad: Void = state.loadAuditLogFiles()
        while !(state.isLoadingAuditLogFiles && runtime.didReachAuditLogFilesGate) {
            await Task.yield()
        }

        async let secondLoad: Void = state.loadAuditLogFiles()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(state.isLoadingAuditLogFiles)
        #expect(runtime.syncCallThreadRecord("auditLogFiles").count == 1)

        runtime.releaseAuditLogFilesGate()
        await firstLoad
        await secondLoad

        #expect(runtime.syncCallThreadRecord("auditLogFiles").count == 2)
        #expect(state.isLoadingAuditLogFiles == false)
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
            externalSigning: false,
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
            externalSigning: false,
            signedOut: false,
            running: false
        )
        runtime.createdAccount = secondary
        state.composeContacts = [
            ComposeContact(
                accountIdHex: String(repeating: "2", count: 64),
                npub: "npub1primarycontact",
                displayName: "Primary contact",
                pictureURL: "https://example.com/primary-contact.png",
                lastActivity: Date()
            )
        ]
        state.isLoadingComposeContacts = true
        state.composeContactsGeneration = 41
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
        #expect(state.composeContacts.isEmpty)
        #expect(!state.isLoadingComposeContacts)
        #expect(state.composeContactsGeneration == 42)
    }

    @MainActor
    @Test func addingSecondAccountViaSignUpBringsItOnlineWithoutRelaunch() async throws {
        // Companion to the login case above: the Create Identity button in
        // Settings → Add Account must also bring the new account online. See #74.
        let primary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
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
            externalSigning: false,
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
    @Test func addingSecondAccountViaLoginWhenRuntimeStartFailsKeepsPriorActiveAccount() async throws {
        // Regression for #333: the Settings → Add Account login path used to commit the
        // active-account switch (activeAccountId, UserDefaults, cleared selection) *before*
        // bringing the runtime online. If start() then threw, the app was left pointed at the
        // new, offline account with no rollback. The switch must not be committed until the
        // runtime is online.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.phase == .ready)
        #expect(state.activeAccountId == "Primary Account")
        #expect(UserDefaults.standard.string(forKey: WorkspaceState.activeAccountKey) == "Primary Account")

        // Simulate the user sitting on a Settings page for the current account.
        state.selection = .settings(.overview)

        // Add a second account, but make the runtime fail to come online.
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        runtime.createdAccount = secondary
        runtime.startError = FakeMarmotRuntimeError.unused
        state.showLogin()
        state.loginIdentity = "nsec1backup"
        await state.login()

        // The switch must have been rolled forward *only* on success: because start() threw,
        // the active account, its persisted value, and the settings selection stay on Primary.
        #expect(state.lastError != nil)
        #expect(runtime.startCallCount == 2)
        #expect(state.activeAccountId == "Primary Account")
        #expect(UserDefaults.standard.string(forKey: WorkspaceState.activeAccountKey) == "Primary Account")
        #expect(state.selection == .settings(.overview))
        #expect(state.phase == .ready)
    }

    @MainActor
    @Test func addingSecondAccountViaSignUpWhenRuntimeStartFailsKeepsPriorActiveAccount() async throws {
        // Companion to the login case: the Create Identity add-account path must also defer the
        // active-account switch until the runtime is online. See #333.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.phase == .ready)
        #expect(state.activeAccountId == "Primary Account")
        state.selection = .settings(.overview)

        let secondary = AccountSummaryFfi(
            label: "Second Identity",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        runtime.createdAccount = secondary
        runtime.startError = FakeMarmotRuntimeError.unused
        await state.signUp()

        #expect(state.lastError != nil)
        #expect(runtime.startCallCount == 2)
        #expect(state.activeAccountId == "Primary Account")
        #expect(UserDefaults.standard.string(forKey: WorkspaceState.activeAccountKey) == "Primary Account")
        #expect(state.selection == .settings(.overview))
        #expect(state.phase == .ready)
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

    /// The sign-in pane must not show a failed attempt's error under the key entered to replace it.
    ///
    /// Both halves that produce that are real state, so both are driven here rather than assumed:
    /// the scrub above empties the field on failure, and `lastError` is not cleared until the
    /// *next* attempt starts. Between those two every keystroke inherits the rejected key's
    /// complaint, and `LoginIdentityDraft.showsLastAttemptError` is the only thing that ends it.
    @MainActor
    @Test func aReplacementKeyIsNotShownThePreviousAttemptsError() async throws {
        // No createdAccount => FakeMarmotRuntime.login throws, exercising the failure path.
        let runtime = FakeMarmotRuntime(accounts: [])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1faketestkeyfaketestkeyfaketestkeyfaketestkeyfaketest"

        await state.login()

        // What the failure leaves behind: an emptied field, and a complaint about the key that is
        // no longer in it. The pane still shows it here — there is nothing else to show.
        let failure = try #require(state.lastError)
        #expect(state.loginIdentity == "")
        #expect(LoginIdentityDraft(state.loginIdentity).showsLastAttemptError)

        // The user pastes a different key. `lastError` deliberately still stands, so the draft is
        // what has to stop carrying it.
        state.loginIdentity = "npub1anotherfakekeyanotherfakekeyanotherfakekeyanotherfake"
        #expect(state.lastError == failure)
        #expect(LoginIdentityDraft(state.loginIdentity).showsLastAttemptError == false)

        // And a wrong one keeps the field's own complaint in front, unchanged.
        state.loginIdentity = "hello"
        #expect(LoginIdentityDraft(state.loginIdentity) == .invalid)
        #expect(LoginIdentityDraft(state.loginIdentity).showsLastAttemptError == false)
    }

    @MainActor
    @Test func successfulLoginScrubsEnteredNsecFromMemory() async throws {
        let summary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
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
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [summary])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        // Simulate a typed-but-unsubmitted key in the Add Account field.
        state.loginIdentity = "nsec1faketestkeyfaketestkeyfaketestkeyfaketestkeyfaketest"

        state.showSettings(.overview)
        #expect(state.loginIdentity == "")

        // And again when leaving for a chat.
        state.loginIdentity = "nsec1anotherfakekeyanotherfakekeyanotherfakekeyanotherfake"
        if let chat = state.activeChats.first {
            state.selectChat(chat)
            #expect(state.loginIdentity == "")
        }
    }

    /// Adding an account is the onboarding flow, not a sheet of its own. Settings' switcher used
    /// to raise `AddAccountSheet` — a second key field and a second pair of buttons for the two
    /// things `Views/Onboarding` already does — then its `Add Account` button routed here instead,
    /// and now that button is gone too: a dropdown for choosing among existing identities is not
    /// where a new one gets created. And the signed-out pane that used to offer `Use another
    /// account` is gone too — with nothing signed in the app opens this flow itself rather than
    /// listing the deactivated identities on this Mac. Settings' switcher *card* is the remaining
    /// caller, so this and the four tests below drive `showAccountOnboarding()` directly. They
    /// still pin the routing, which is what a caller added later would depend on; the tests keep
    /// their `addAccount` names because the flow's regressions (#74, #333, #32) are filed under
    /// it.
    @MainActor
    @Test func addAccountOpensTheOnboardingFlowOnItsLandingPane() async throws {
        let state = WorkspaceState(clientFactory: { Self.addAccountRuntime() })
        await state.bootstrap()
        #expect(state.phase == .ready)

        state.showAccountOnboarding()

        #expect(state.phase == .onboarding)
        #expect(state.authenticationMode == .landing)
    }

    /// The welcome pane is the root of the flow, so its way out is a `Cancel` back to the app —
    /// but only where there is an app behind it. A first launch has none, and a control that
    /// returned to a blank window would be offering something it cannot do.
    @MainActor
    @Test func onlyAnOnboardingFlowWithAccountsBehindItOffersAWayOut() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let empty = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        await empty.bootstrap()
        #expect(empty.phase == .onboarding)
        #expect(empty.canLeaveAccountOnboarding == false)

        // A Mac holding nothing but deactivated identities is the same dead end. This reads
        // `signedInAccounts`, not `accounts`: counting the signed-out ones drew a `Cancel` whose
        // `.ready` destination had no account to render — the very reason the user is on this
        // pane. The account list stays non-empty throughout, so only the filter can tell them
        // apart.
        let deactivatedOnly = WorkspaceState(
            clientFactory: {
                FakeMarmotRuntime(accounts: [signedOutBackupAccount()])
            })
        await deactivatedOnly.bootstrap()
        #expect(deactivatedOnly.accounts.isEmpty == false)
        #expect(deactivatedOnly.phase == .onboarding)
        #expect(deactivatedOnly.canLeaveAccountOnboarding == false)

        let state = WorkspaceState(clientFactory: { Self.addAccountRuntime() })
        await state.bootstrap()
        // Ready, with an account: in the app, so there is nothing to leave.
        #expect(state.canLeaveAccountOnboarding == false)

        state.showAccountOnboarding()
        #expect(state.canLeaveAccountOnboarding)
    }

    /// Launching with every identity on this Mac deactivated is a login, not a menu.
    ///
    /// It used to bring the runtime online and land in `.ready` with no active account, where
    /// `SignedOutAccountsView` listed the stored identities and one click reactivated one —
    /// a sign-in that asked for no key. The core reactivates a matching signed-out account on
    /// `login`, so the real flow returns that identity's chats; going around it was the only
    /// thing lost.
    @MainActor
    @Test func bootstrapWithOnlyDeactivatedIdentitiesOpensTheLoginSurface() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let signedOut = signedOutBackupAccount()
        let runtime = FakeMarmotRuntime(accounts: [signedOut])
        UserDefaults.standard.set(signedOut.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        #expect(state.phase == .onboarding)
        #expect(state.authenticationMode == .landing)
        #expect(state.activeAccountId == nil)
        // The identity itself is still on this Mac — it is reachable through Sign In, and
        // Settings' switcher still lists it once something is signed in.
        #expect(state.accounts.map(\.id) == [signedOut.label])
        #expect(state.signedInAccounts.isEmpty)
        // The stale active-account pointer must not survive: it named an account that cannot
        // drive the UI, and a later launch would restore it.
        #expect(UserDefaults.standard.string(forKey: WorkspaceState.activeAccountKey) == nil)
    }

    /// Signing out the last identity lands where a first launch does.
    ///
    /// It used to stay in `.ready` with no active account and draw the chooser, which offered to
    /// reactivate the identity whose sign-out the user had just confirmed in Settings.
    @MainActor
    @Test func signingOutTheLastIdentityOpensTheLoginSurface() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [primary])
        UserDefaults.standard.set(primary.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let account = try #require(state.accounts.first { $0.id == primary.label })

        await state.signOutAccount(account)

        #expect(runtime.signedOutAccountRefs == [primary.label])
        #expect(state.phase == .onboarding)
        #expect(state.authenticationMode == .landing)
        #expect(state.activeAccountId == nil)
        #expect(state.selection == nil)
        // No way back out of the pane: `.ready` has no account to render.
        #expect(state.canLeaveAccountOnboarding == false)
    }

    /// Removing the last *signed-in* identity while a deactivated one remains is the same dead
    /// end as removing the last identity outright — the account list is still non-empty, so the
    /// `accounts.isEmpty` guard this replaced fell through, reselected nothing, and stayed in
    /// `.ready` with no active account.
    @MainActor
    @Test func removingTheLastSignedInIdentityOpensTheLoginSurface() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = desktopAccount()
        let signedOut = signedOutBackupAccount()
        let runtime = FakeMarmotRuntime(accounts: [primary, signedOut])
        UserDefaults.standard.set(primary.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let account = try #require(state.accounts.first { $0.id == primary.label })

        await state.removeAccount(account)

        #expect(runtime.removedAccountRefs == [primary.label])
        #expect(state.accounts.map(\.id) == [signedOut.label])
        #expect(state.signedInAccounts.isEmpty)
        #expect(state.phase == .onboarding)
        #expect(state.authenticationMode == .landing)
        #expect(state.activeAccountId == nil)
        #expect(state.canLeaveAccountOnboarding == false)
    }

    /// Cancel returns the user to the page they opened the flow from, which is why
    /// `showAccountOnboarding()` leaves `selection` alone: restoring the phase is the whole of
    /// the way back, and nothing else moved while the panes were up.
    @MainActor
    @Test func cancellingAddAccountReturnsToThePageItWasOpenedFrom() async throws {
        let state = WorkspaceState(clientFactory: { Self.addAccountRuntime() })
        await state.bootstrap()
        state.showSettings(.overview)
        let selectionBeforehand = state.selection

        state.showAccountOnboarding()
        state.leaveAccountOnboarding()

        #expect(state.phase == .ready)
        #expect(state.authenticationMode == .landing)
        #expect(state.selection == selectionBeforehand)
    }

    /// #32 on the exit the sheet's `.onDisappear` used to cover. A key typed into the flow and
    /// then abandoned must not outlive it — cancelling is exactly the case where the user has
    /// decided not to submit what they pasted.
    @MainActor
    @Test func cancellingAddAccountScrubsTheEnteredNsec() async throws {
        let state = WorkspaceState(clientFactory: { Self.addAccountRuntime() })
        await state.bootstrap()

        state.showAccountOnboarding()
        state.showLogin()
        state.loginIdentity = "nsec1faketestkeyfaketestkeyfaketestkeyfaketestkeyfaketest"

        // Back out of the key pane first, the way the panes are actually stacked.
        state.cancelLogin()
        #expect(state.loginIdentity == "")

        // And again for a key that survived as far as the landing pane.
        state.loginIdentity = "nsec1anotherfakekeyanotherfakekeyanotherfakekeyanotherfake"
        state.leaveAccountOnboarding()

        #expect(state.loginIdentity == "")
        #expect(state.phase == .ready)
    }

    /// Entering the flow must not carry a failure in from wherever it was opened, and leaving it
    /// must not carry one back out: `lastError` renders on the landing pane and on every settings
    /// pane, so a stale one would be read as a complaint about the screen it followed the user to.
    @MainActor
    @Test func theAddAccountFlowClearsErrorsOnTheWayInAndOnTheWayOut() async throws {
        let state = WorkspaceState(clientFactory: { Self.addAccountRuntime() })
        await state.bootstrap()

        state.lastError = "Something failed in Settings"
        state.showAccountOnboarding()
        #expect(state.lastError == nil)

        state.lastError = "Couldn't sign in"
        state.leaveAccountOnboarding()
        #expect(state.lastError == nil)
    }

    /// The exit control's two cases are not interchangeable: `wn-ios-prototype` draws the pushed
    /// panes' way back as a nav-bar chevron and the root pane's as `Cancel`, and conflating them
    /// would put a "go back" arrow on a pane with nothing behind it.
    @MainActor
    @Test func theOnboardingExitControlDrawsBackAndCancelDifferently() {
        let back = OnboardingExitControl.back {}
        let cancel = OnboardingExitControl.cancel {}

        #expect(back.symbol == "chevron.left")
        #expect(cancel.symbol == "xmark")
        #expect(back.helpKey != cancel.helpKey)
        #expect(back.accessibilityIdentifier != cancel.accessibilityIdentifier)
    }

    /// One signed-in account on a fake runtime, for the add-account flow's tests.
    private static func addAccountRuntime() -> FakeMarmotRuntime {
        FakeMarmotRuntime(accounts: [
            AccountSummaryFfi(
                label: "Desktop Account",
                accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                localSigning: true,
                externalSigning: false,
                signedOut: false,
                running: true
            )
        ])
    }

    /// The avatar's selection ring and drop shadow are both drawn outside the frame they are
    /// applied to, so every clipping container has to be told how far they reach. Pinned to the
    /// effects that produce it: a hand-written literal that stopped tracking `selectedScale`
    /// would hand those containers a slack that no longer covers the ring.
    @MainActor
    @Test func avatarChromeOverhangCoversTheSelectionRingAndTheShadow() {
        let size: CGFloat = 32
        // `scaleEffect` grows about the center, so each side moves out by half the added width.
        let ringReach = size * (AvatarChromeModifier.selectedScale - 1) / 2

        #expect(ringReach > 0)
        #expect(
            AvatarChromeModifier.overhang(forAvatarSize: size)
                == ringReach + AvatarChromeModifier.shadowRadius)
        // The shadow's blur is on top of the ring, not inside it.
        #expect(AvatarChromeModifier.overhang(forAvatarSize: size) > ringReach)
        // A bigger avatar's ring reaches further, so the slack it needs has to scale with it.
        #expect(
            AvatarChromeModifier.overhang(forAvatarSize: 64)
                > AvatarChromeModifier.overhang(forAvatarSize: 32))
    }

    /// The rail buys its slack with an oversized frame, and `AvatarChromeModifier` documents that
    /// arrangement as the reason `selectedScale` is safe to apply. Shrinking the frame — or
    /// raising the scale — without the other would clip the active account's ring against the
    /// rail's own bounds.
    @MainActor
    @Test func accountRailAvatarFrameLeavesRoomForTheSelectedAvatarsChrome() {
        let slackPerSide =
            (MessagesLayout.accountRailAvatarFrameSize - MessagesLayout.accountRailAvatarSize) / 2

        #expect(
            slackPerSide
                >= AvatarChromeModifier.overhang(
                    forAvatarSize: MessagesLayout.accountRailAvatarSize))
    }

    @MainActor
    @Test func removeActiveAccountCallsRuntimeAndSelectsNextAccount() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
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
        #expect(state.selection == .settings(.overview))
    }

    @MainActor
    @Test func removeNonActiveAccountLeavesActiveSessionUntouched() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
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
    @Test func signOutActiveAccountClearsDecodedImageCache() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        RemoteImageLoader.shared.clearCache()
        defer { RemoteImageLoader.shared.clearCache() }
        let cacheKey = "signed-out-active-account-avatar"
        let imageData = try Self.testPNGData(width: 64, height: 64)
        let decoded = try #require(
            await RemoteImageLoader.shared.image(
                for: imageData,
                cacheKey: cacheKey,
                maxPixelSize: 32
            )
        )
        let cachedBeforeSignOut = try #require(
            await RemoteImageLoader.shared.image(
                for: Data([0x00]),
                cacheKey: cacheKey,
                maxPixelSize: 32
            )
        )
        #expect(cachedBeforeSignOut.nsImage === decoded.nsImage)

        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        await state.signOutAccount(desktopAccount)

        #expect(runtime.signedOutAccountRefs == ["Desktop Account"])
        #expect(state.accounts.first { $0.id == "Desktop Account" }?.signedOut == true)
        #expect(state.activeAccountId == "Backup Account")
        #expect(
            await RemoteImageLoader.shared.image(
                for: Data([0x00]),
                cacheKey: cacheKey,
                maxPixelSize: 32
            ) == nil
        )
    }

    @MainActor
    @Test func failedActiveAccountMutationsRestartChatAndTimelineListeners() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let activeAccount = try #require(state.activeAccount)
        let chat = try #require(state.activeChats.first { $0.id == "group" })
        state.selectChat(chat)
        #expect(await waitFor { runtime.timelineSubscriptionCount == 1 })

        runtime.signOutError = FakeMarmotRuntimeError.unused
        var chatListBaseline = runtime.chatListSubscriptionCount
        var timelineBaseline = runtime.timelineSubscriptionCount
        await state.signOutAccount(activeAccount)
        #expect(
            await waitFor {
                runtime.chatListSubscriptionCount >= chatListBaseline + 1
                    && runtime.timelineSubscriptionCount >= timelineBaseline + 1
            })
        #expect(state.activeAccountId == account.label)
        #expect(state.selection == .chat("group"))

        runtime.signOutError = nil
        runtime.removeAccountError = FakeMarmotRuntimeError.unused
        chatListBaseline = runtime.chatListSubscriptionCount
        timelineBaseline = runtime.timelineSubscriptionCount
        await state.removeAccount(activeAccount)
        #expect(
            await waitFor {
                runtime.chatListSubscriptionCount >= chatListBaseline + 1
                    && runtime.timelineSubscriptionCount >= timelineBaseline + 1
            })
        #expect(state.activeAccountId == account.label)
        #expect(state.selection == .chat("group"))
        #expect(state.lastError == "Unused fake runtime error.")
    }

    @MainActor
    @Test func signOutLastActiveAccountStopsInProgressVoiceRecording() async throws {
        // #386: the account-rail sign-out path can send the last signed-in account
        // straight to onboarding, removing the composer that owns the Stop control.
        // It must still run active-conversation teardown so the mic is not left hot
        // and the plaintext scratch recording does not survive sign-out.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [primary])
        UserDefaults.standard.set(primary.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let url = try armInProgressVoiceRecording(on: state)
        let desktopAccount = try #require(state.accounts.first { $0.id == primary.label })

        await state.signOutAccount(desktopAccount)

        #expect(runtime.signedOutAccountRefs == [primary.label])
        #expect(state.phase == .onboarding)
        #expect(state.activeAccountId == nil)
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecorder == nil)
        #expect(state.voiceRecordingURL == nil)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(state.voiceRecordingSamples.isEmpty)
        #expect(state.voiceRecordingDurationSeconds == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
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
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
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
    @Test func signingOutActiveAccountSelectedMidFlightKeepsRacedSelection() async throws {
        // Regression for the sign-out/account-switch race (whitenoise-mac#329): if the user
        // selects another account while the active account's sign-out is in flight,
        // `activeAccountId` now points at the newly-selected account. The pre-await
        // `wasActive` snapshot is true, so naive code would still reset the active-account UI
        // state (tearing down the just-loaded session) and reselect
        // `accounts.first(where: { !$0.signedOut })`, discarding the user's explicit choice.
        // Sign-out must recompute against post-await state and leave a valid raced selection
        // untouched.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        // Ordered before "Backup Account" so the old `accounts.first(where:)` recovery would
        // pick this account rather than the one the user raced to.
        let other = AccountSummaryFfi(
            label: "Other Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, other, backup])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })

        // Simulate the racing UI selection of another account, mid-await.
        runtime.onSignOutAccountMidFlight = { _ in
            await MainActor.run {
                state.selectAccountFromSettings(backupAccount)
            }
        }

        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        await state.signOutAccount(desktopAccount)

        #expect(runtime.signedOutAccountRefs == ["Desktop Account"])
        #expect(state.accounts.first { $0.id == "Desktop Account" }?.signedOut == true)
        // The user's explicit mid-flight selection must survive: sign-out must not reselect
        // the first signed-in account ("Other Account") over the raced-to "Backup Account".
        #expect(state.activeAccountId == "Backup Account")
        #expect(UserDefaults.standard.string(forKey: "whitenoise.mac.activeAccountId") == "Backup Account")
    }

    @MainActor
    @Test func signingInAccountSelectedMidFlightKeepsRacedSelection() async throws {
        // Regression for the sign-in/account-switch race (whitenoise-mac#393): if the user
        // selects another account while a signed-out account's sign-in is in flight,
        // `activeAccountId` now points at the newly-selected account. Naive code would still
        // unconditionally `switchActiveAccount` to the just-signed-in account, tearing down the
        // raced-to session. Sign-in must recompute against post-await state and leave a valid
        // raced selection untouched.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        // Naive code would unconditionally activate the just-signed-in "Backup Account",
        // discarding the user's explicit mid-flight selection of "Other Account".
        let other = AccountSummaryFfi(
            label: "Other Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let signedOut = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, other, signedOut])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let signedOutAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        let otherAccount = try #require(state.accounts.first { $0.id == "Other Account" })

        // Simulate the racing UI selection from the account rail, mid-await.
        runtime.onSignInAccountMidFlight = { _ in
            await MainActor.run {
                state.selectAccount(otherAccount)
            }
        }

        await state.signInAccount(signedOutAccount)

        #expect(runtime.signInAccountCallCount == 1)
        #expect(state.accounts.first { $0.id == "Backup Account" }?.signedOut == false)
        // The user's explicit mid-flight selection must survive: sign-in must not activate
        // the just-signed-in "Backup Account" over the raced-to "Other Account".
        #expect(state.activeAccountId == "Other Account")
        #expect(UserDefaults.standard.string(forKey: "whitenoise.mac.activeAccountId") == "Other Account")
    }

    @MainActor
    @Test func signedInAccountsOmitsDeactivatedIdentitiesFromTheRail() async throws {
        // What the account rail draws — and, until the Settings switcher popover was deleted,
        // that list too. A signed-out identity used to sit in both, dimmed to 0.4 behind a pause
        // glyph, and tapping it signed the identity back in. Neither control can be *switched*
        // to a deactivated identity (`selectAccount` and `selectAccountFromSettings` both refuse
        // one), so those rows were a sign-in button wearing a destination's clothes.
        //
        // `accounts` must keep every identity on this Mac regardless. No surface lists the
        // deactivated ones any more — the pane that used to stand in for the app when nothing was
        // signed in is gone too, and getting back into one is Sign In with its key — but the app
        // still has to know they are there: whether this filter is empty is what decides between
        // the app and the login surface.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let signedOut = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, signedOut])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        #expect(state.accounts.map(\.id) == ["Desktop Account", "Backup Account"])
        #expect(state.signedInAccounts.map(\.id) == ["Desktop Account"])
        // And with the deactivated identity out of the list, there is nothing to switch to: the
        // management row offers `Add Account` rather than a switcher holding one row.
        #expect(!state.hasOtherSignedInAccount)

        // Signing it back in puts it back in both lists — the filter is derived from the account
        // list, not a separate copy that could fall out of step with it.
        let backup = try #require(state.accounts.first { $0.id == "Backup Account" })
        await state.signInAccount(backup)

        #expect(state.signedInAccounts.map(\.id) == ["Desktop Account", "Backup Account"])
        #expect(state.hasOtherSignedInAccount)
    }

    /// Signing a background identity out drops it from `signedInAccounts` — so from the rail —
    /// instead of turning its row into a dimmed `Signed out` entry, and leaves the active
    /// session alone.
    @MainActor
    @Test func signingOutABackgroundAccountRemovesItFromTheRail() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let other = AccountSummaryFfi(
            label: "Other Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, other])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.hasOtherSignedInAccount)
        let background = try #require(state.accounts.first { $0.id == "Other Account" })

        await state.signOutAccount(background)

        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.signedInAccounts.map(\.id) == ["Desktop Account"])
        #expect(!state.hasOtherSignedInAccount)
        // Still stored, so signing in with its key reactivates this identity rather than
        // creating a second one beside it.
        #expect(state.accounts.first { $0.id == "Other Account" }?.signedOut == true)
    }

    @MainActor
    @Test func removingAccountBlocksSignOutMidFlight() async throws {
        // Regression for whitenoise-mac#531: remove and sign-out must be mutually exclusive.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })

        runtime.onRemoveAccountMidFlight = { _ in
            await state.signOutAccount(desktopAccount)
        }

        await state.removeAccount(backupAccount)

        #expect(runtime.removedAccountRefs == ["Backup Account"])
        #expect(runtime.signOutCallCount == 0)
        #expect(runtime.signedOutAccountRefs.isEmpty)
    }

    @MainActor
    @Test func removingAccountBlocksSignInMidFlight() async throws {
        // Regression for whitenoise-mac#531: remove and sign-in must be mutually exclusive.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let other = AccountSummaryFfi(
            label: "Other Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let signedOut = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, other, signedOut])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let otherAccount = try #require(state.accounts.first { $0.id == "Other Account" })
        let signedOutAccount = try #require(state.accounts.first { $0.id == "Backup Account" })

        runtime.onRemoveAccountMidFlight = { _ in
            await state.signInAccount(signedOutAccount)
        }

        await state.removeAccount(otherAccount)

        #expect(runtime.removedAccountRefs == ["Other Account"])
        #expect(runtime.signInAccountCallCount == 0)
        #expect(state.accounts.first { $0.id == "Backup Account" }?.signedOut == true)
    }

    @MainActor
    @Test func signingOutAccountBlocksRemoveMidFlight() async throws {
        // Regression for whitenoise-mac#531: sign-out and remove must be mutually exclusive.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })

        runtime.onSignOutAccountMidFlight = { _ in
            await state.removeAccount(backupAccount)
        }

        await state.signOutAccount(desktopAccount)

        #expect(runtime.signedOutAccountRefs == ["Desktop Account"])
        #expect(runtime.removedAccountRefs.isEmpty)
        #expect(state.accounts.map(\.id) == ["Desktop Account", "Backup Account"])
    }

    @MainActor
    @Test func signingInAccountBlocksRemoveMidFlight() async throws {
        // Regression for whitenoise-mac#531: sign-in and remove must be mutually exclusive.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let signedOut = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, signedOut])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let signedOutAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })

        runtime.onSignInAccountMidFlight = { _ in
            await state.removeAccount(desktopAccount)
        }

        await state.signInAccount(signedOutAccount)

        #expect(runtime.signInAccountCallCount == 1)
        #expect(runtime.removedAccountRefs.isEmpty)
        #expect(state.accounts.map(\.id) == ["Desktop Account", "Backup Account"])
        #expect(state.accounts.first { $0.id == "Backup Account" }?.signedOut == false)
    }

    @MainActor
    @Test func deletingAllDataBlocksAccountMutationsMidFlight() async throws {
        // Regression for whitenoise-mac#590: a full wipe and every account mutation must
        // share one mutual-exclusion guard.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let signedOut = AccountSummaryFfi(
            label: "Signed Out Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary, signedOut])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        let signedOutAccount = try #require(state.accounts.first { $0.id == "Signed Out Account" })

        runtime.onDeleteAllLocalDataMidFlight = {
            await state.removeAccount(backupAccount)
            await state.signOutAccount(desktopAccount)
            await state.signInAccount(signedOutAccount)
        }

        await state.deleteAllData()

        #expect(runtime.didDeleteAllLocalData)
        #expect(runtime.removedAccountRefs.isEmpty)
        #expect(runtime.signOutCallCount == 0)
        #expect(runtime.signInAccountCallCount == 0)
        #expect(state.phase == .onboarding)
    }

    @MainActor
    @Test func signingOutAccountBlocksDeleteAllDataMidFlight() async throws {
        // Regression for whitenoise-mac#590: mutual exclusion must also prevent a wipe
        // from starting after an account mutation has entered its first await.
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })

        runtime.onSignOutAccountMidFlight = { _ in
            await state.deleteAllData()
        }

        await state.signOutAccount(desktopAccount)

        #expect(runtime.signOutCallCount == 1)
        #expect(!runtime.didDeleteAllLocalData)
        #expect(state.accounts.first { $0.id == "Desktop Account" }?.signedOut == true)
        #expect(state.phase == .ready)
    }

    @MainActor
    @Test func deleteAllDataResetsToNewInstallState() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
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
    @Test func accountRemovalPurgesOnlyItsPinsAndDeleteAllDataClearsTheRemainder() async throws {
        let primary = desktopAccount()
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: String(repeating: "1", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-pinned-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinnedChatFileStore(directoryURL: directory)
        try store.write(["shared-group"], forAccountId: primary.label)
        try store.write(["shared-group"], forAccountId: secondary.label)

        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set(primary.label, forKey: "whitenoise.mac.activeAccountId")

        let state = WorkspaceState(pinnedChatStore: store, clientFactory: { runtime })
        await state.bootstrap()

        #expect(state.isChatPinned(accountId: primary.label, groupIdHex: "shared-group"))
        #expect(state.isChatPinned(accountId: secondary.label, groupIdHex: "shared-group"))

        let backupAccount = try #require(state.accounts.first { $0.id == secondary.label })
        await state.removeAccount(backupAccount)

        #expect(try store.loadAll() == [primary.label: ["shared-group"]])
        #expect(state.isChatPinned(accountId: primary.label, groupIdHex: "shared-group"))
        #expect(!state.isChatPinned(accountId: secondary.label, groupIdHex: "shared-group"))

        await state.deleteAllData()

        #expect(try store.loadAll().isEmpty)
        #expect(state.pinnedChatIdsByAccount.isEmpty)
    }

    @MainActor
    @Test func contactNicknamesAreOwnerScopedAndSurviveSignOutButNotRemovalOrLocalWipe() async throws {
        let primary = desktopAccount()
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: String(repeating: "1", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let contact = String(repeating: "2", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nickname-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactNicknameFileStore(directoryURL: directory)
        try store.write([contact: "Mum"], forOwnerAccountIdHex: primary.accountIdHex)
        try store.write([contact: "Landlord"], forOwnerAccountIdHex: secondary.accountIdHex)

        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set(primary.label, forKey: "whitenoise.mac.activeAccountId")

        let state = WorkspaceState(contactNicknameStore: store, clientFactory: { runtime })
        await state.bootstrap()

        #expect(state.contactNickname(forContactAccountIdHex: contact) == "Mum")
        #expect(
            state.contactNicknames(forOwnerAccountIdHex: secondary.accountIdHex)
                .nickname(forContactAccountIdHex: contact) == "Landlord"
        )

        let backupAccount = try #require(state.accounts.first { $0.id == secondary.label })
        await state.signOutAccount(backupAccount)
        #expect(try store.loadAll().count == 2)

        let signedOutBackup = try #require(state.accounts.first { $0.id == secondary.label })
        await state.removeAccount(signedOutBackup)
        #expect(try store.loadAll() == [primary.accountIdHex: [contact: "Mum"]])
        #expect(state.contactNickname(forContactAccountIdHex: contact) == "Mum")
        #expect(
            state.contactNicknames(forOwnerAccountIdHex: secondary.accountIdHex)
                .nickname(forContactAccountIdHex: contact) == nil
        )

        await state.deleteAllData()

        #expect(try store.loadAll().isEmpty)
        #expect(state.contactNicknamesByOwner.isEmpty)
    }

    @MainActor
    @Test func accountSwitchAndNewInstallResetClearDecryptedSharedMediaCache() async throws {
        let primary = desktopAccount()
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: String(repeating: "1", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        func installDecryptedCacheFixture() {
            state.sharedMediaGroupId = "private-group"
            state.sharedMediaThumbnailCache = ["private-image": Data([1, 2, 3])]
            state.sharedMediaThumbnailCacheOrder = ["private-image"]
            state.sharedMediaThumbnailCacheBytes = 3
        }

        installDecryptedCacheFixture()
        let backup = try #require(state.accounts.first { $0.id == secondary.label })
        state.prepareForActiveAccountSwitch(to: backup, preservingMessageCacheFor: nil)
        #expect(state.sharedMediaGroupId == nil)
        #expect(state.sharedMediaThumbnailCache.isEmpty)
        #expect(state.sharedMediaThumbnailCacheOrder.isEmpty)
        #expect(state.sharedMediaThumbnailCacheBytes == 0)

        installDecryptedCacheFixture()
        state.resetToNewInstallState(storageRootPath: state.storageRootPath)
        #expect(state.sharedMediaGroupId == nil)
        #expect(state.sharedMediaThumbnailCache.isEmpty)
        #expect(state.sharedMediaThumbnailCacheOrder.isEmpty)
        #expect(state.sharedMediaThumbnailCacheBytes == 0)
    }

    @MainActor
    @Test func failedDeleteAllDataRestartsReadySessionListenersAndReloadsSelectedChat() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didStartNotifications = await waitFor {
            runtime.notificationSubscriptionCount == 1
        }
        #expect(didStartNotifications)
        let chat = try #require(state.activeChats.first { $0.id == "group" })
        state.selectChat(chat)
        let didStartTimeline = await waitFor {
            runtime.timelineSubscriptionCount == 1
        }
        #expect(didStartTimeline)

        let notificationSubscriptionBaseline = runtime.notificationSubscriptionCount
        let chatListSubscriptionBaseline = runtime.chatListSubscriptionCount
        let timelineSubscriptionBaseline = runtime.timelineSubscriptionCount
        runtime.deleteAllLocalDataError = FakeMarmotRuntimeError.unused

        await state.deleteAllData()
        let didRestartNotifications = await waitFor {
            runtime.notificationSubscriptionCount >= notificationSubscriptionBaseline + 1
        }

        #expect(didRestartNotifications)
        #expect(runtime.didDeleteAllLocalData)
        #expect(state.phase == .ready)
        #expect(state.selection == .chat("group"))
        #expect(state.activeChats.contains { $0.id == "group" })
        #expect(runtime.chatListSubscriptionCount >= chatListSubscriptionBaseline + 1)
        #expect(runtime.timelineSubscriptionCount >= timelineSubscriptionBaseline + 1)
        #expect(state.lastError == "Unused fake runtime error.")
    }

    @MainActor
    @Test func runtimeInvalidatingDeleteFailureTransitionsToFreshOnboardingClient() async throws {
        let account = desktopAccount()
        let invalidatedRuntime = FakeMarmotRuntime(accounts: [account])
        invalidatedRuntime.installGroup(messageGroup())
        let freshRuntime = FakeMarmotRuntime(accounts: [])
        var factoryCalls = 0
        let state = WorkspaceState(
            clientFactory: {
                factoryCalls += 1
                return factoryCalls == 1 ? invalidatedRuntime : freshRuntime
            })

        await state.bootstrap()
        let chat = try #require(state.activeChats.first { $0.id == "group" })
        state.selectChat(chat)
        _ = await waitFor { invalidatedRuntime.timelineSubscriptionCount == 1 }
        invalidatedRuntime.deleteAllLocalDataError = MarmotLocalDataDeletionError.runtimeInvalidated(
            underlying: FakeMarmotRuntimeError.unused
        )

        await state.deleteAllData()

        #expect(state.phase == .onboarding)
        #expect(state.accounts.isEmpty)
        #expect((state.client as? FakeMarmotRuntime) === freshRuntime)
        #expect(state.notificationTask == nil)
        #expect(state.chatListTask == nil)
        #expect(state.timelineTask == nil)
        #expect(state.lastError == "Unused fake runtime error.")
    }

    @MainActor
    @Test func onboardingAuthenticationRetriesClientFactoryAfterPostWipeFailure() async throws {
        let account = desktopAccount()
        let oldRuntime = FakeMarmotRuntime(accounts: [account])
        let freshRuntime = FakeMarmotRuntime(accounts: [], createdAccount: account)
        var factoryCalls = 0
        let state = WorkspaceState(
            clientFactory: {
                factoryCalls += 1
                switch factoryCalls {
                case 1: return oldRuntime
                case 2: throw FakeMarmotRuntimeError.unused
                default: return freshRuntime
                }
            })

        await state.bootstrap()
        await state.deleteAllData()
        #expect(state.phase == .onboarding)
        #expect(state.client == nil)
        #expect(state.lastError == "Unused fake runtime error.")

        await state.signUp()

        #expect((state.client as? FakeMarmotRuntime) === freshRuntime)
        #expect(state.phase == .ready)
        #expect(state.activeAccountId == account.label)
        #expect(factoryCalls == 3)
    }

    @MainActor
    @Test func observabilityFailureDoesNotAbortReadyStateActivation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: account)
        runtime.telemetryInstallIdError = FakeMarmotRuntimeError.observabilityConfigurationFailed
        let state = WorkspaceState(
            telemetryBuildConfigProvider: { telemetryBuildConfig(environment: "production") },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.phase == .onboarding)
        await state.signUp()

        #expect(state.phase == .ready)
        #expect(state.activeAccountId == account.label)
        #expect(await waitFor { runtime.chatListSubscriptionCount >= 1 })
        #expect(await waitFor { runtime.notificationSubscriptionCount >= 1 })
        #expect(state.backgroundStatus == "Observability configuration failed.")
    }

    @MainActor
    @Test func deleteAllDataClearsAccountUnreadBadges() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
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
            externalSigning: false,
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
    @Test func accountUnreadSummaryClampsOversizedUnreadCount() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary])
        runtime.accountUnreadSummaryRows = [
            AccountUnreadFfi(
                accountIdHex: primary.accountIdHex,
                unreadCount: UInt64(Int.max) + 1,
                unreadConversations: 1,
                hasUnread: true
            )
        ]
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.refreshAccountUnreadSummary()

        #expect(state.unreadCount(forAccountIdHex: primary.accountIdHex) == Int.max)
    }

    @MainActor
    @Test func readingTheActiveAccountsChatsClearsItsAvatarUnreadBadge() async throws {
        // The rail avatar badge reads the per-account summary, which used to be re-queried only on
        // sign-in/out and full chat-list reloads. Reading a chat reaches the app as a live row
        // delta, so the active account's avatar kept a badge for messages it had already read
        // until the next account switch.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.accountUnreadSummaryRows = [
            AccountUnreadFfi(
                accountIdHex: account.accountIdHex,
                unreadCount: 5,
                unreadConversations: 1,
                hasUnread: true
            )
        ]
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.chatListEnrichmentTask?.value
        let activeAccount = try #require(state.activeAccount)
        let chat = try #require(state.activeChats.first)

        await state.applyChatListSubscriptionUpdate(
            .row(
                trigger: .unreadChanged,
                row: chatListRow(
                    groupIdHex: chat.id,
                    title: "Test Group",
                    preview: "Unread message",
                    sender: account.accountIdHex,
                    timelineAt: 1_700_000_100,
                    unreadCount: 5,
                    hasUnread: true
                )
            ),
            account: activeAccount
        )
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 5)

        // The user opens the chat: the read marker commits and the backend stops reporting unread.
        runtime.accountUnreadSummaryRows = [
            AccountUnreadFfi(
                accountIdHex: account.accountIdHex,
                unreadCount: 0,
                unreadConversations: 0,
                hasUnread: false
            )
        ]
        await state.applyChatListSubscriptionUpdate(
            .row(
                trigger: .unreadChanged,
                row: chatListRow(
                    groupIdHex: chat.id,
                    title: "Test Group",
                    preview: "Unread message",
                    sender: account.accountIdHex,
                    timelineAt: 1_700_000_100
                )
            ),
            account: activeAccount
        )

        #expect(state.activeChats.first?.unreadCount == 0)
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
    }

    @MainActor
    @Test func aBackgroundAccountsIncomingMessageMovesItsAvatarBadge() async throws {
        // Chat-list subscriptions run for the active account only, so nothing told the app that a
        // background account had new messages: its rail badge sat on whatever the last account
        // switch or full reload recorded until the user switched to it. The client-wide
        // notification stream is the live signal that it moved.
        let backup = backupAccountSummary()
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.installNotificationSettings(
            accountRef: backup.label,
            settings: notificationSettings(for: backup, localEnabled: true)
        )
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0),
            unreadSummaryRow(accountIdHex: backup.accountIdHex, unreadCount: 0),
        ]
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let (state, active) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 0,
            localNotificationCenter: notificationCenter
        )
        state.accounts.append(AccountItem(summary: backup))

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: backup.accountIdHex) == 0)

        // A message lands on the backup account while the user stays on the active one.
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0),
            unreadSummaryRow(accountIdHex: backup.accountIdHex, unreadCount: 4),
        ]
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: backup,
                notificationKey: "notice-for-backup",
                senderName: "Alice",
                previewText: "Hi there."
            ))

        #expect(state.activeAccountId == active.id)
        #expect(state.unreadCount(forAccountIdHex: backup.accountIdHex) == 4)
        #expect(notificationCenter.postedRequests.map(\.identifier) == ["notice-for-backup"])
    }

    @MainActor
    @Test func aBackgroundAccountWithNotificationsOffStillMovesItsAvatarBadge() async throws {
        // The badge counts unread messages, not banners the user agreed to see, so the refresh sits
        // above every delivery gate: turning local notifications off for an account must not freeze
        // its rail badge at the last switch's total.
        let backup = backupAccountSummary()
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.installNotificationSettings(
            accountRef: backup.label,
            settings: notificationSettings(for: backup, localEnabled: false)
        )
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0),
            unreadSummaryRow(accountIdHex: backup.accountIdHex, unreadCount: 6),
        ]
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let (state, _) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 0,
            localNotificationCenter: notificationCenter
        )
        state.accounts.append(AccountItem(summary: backup))

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: backup,
                notificationKey: "silent-notice",
                senderName: "Alice",
                previewText: "Hi there."
            ))

        #expect(state.unreadCount(forAccountIdHex: backup.accountIdHex) == 6)
        #expect(notificationCenter.postedRequests.isEmpty)
    }

    @MainActor
    @Test func anActiveAccountNotificationLeavesTheUnreadSummaryToTheChatRowPath() async throws {
        // The active account's chat-list subscription delivers the same message as a row delta,
        // which already refreshes the summary. Querying from the notification too would put a
        // second summary read on every message the account in front of the user receives.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 2)
        ]
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let (state, account) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 2,
            localNotificationCenter: notificationCenter
        )
        let activeSummary = AccountSummaryFfi(
            label: account.accountRef,
            accountIdHex: account.accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        runtime.installNotificationSettings(
            accountRef: activeSummary.label,
            settings: notificationSettings(for: activeSummary, localEnabled: true)
        )

        await state.refreshAccountUnreadSummary()
        let queriesSoFar = runtime.accountUnreadSummaryCallCount

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: activeSummary,
                notificationKey: "notice-for-active",
                senderName: "Alice",
                previewText: "Hi there."
            ))

        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar)
        #expect(notificationCenter.postedRequests.map(\.identifier) == ["notice-for-active"])
    }

    @MainActor
    @Test func chatRowDeltasThatLeaveUnreadAloneDoNotRequeryTheAccountUnreadSummary() async throws {
        // The badge follows the rows, but a summary query per row delta would put an FFI call on
        // every read-marker advance and every incoming preview. Only a moved unread total re-queries.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 3)
        ]
        let (state, account) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 3)

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 3)
        let queriesSoFar = runtime.accountUnreadSummaryCallCount

        // A newer message on a row that stays just as unread.
        await state.applyChatRow(
            unreadBadgeFixtureRow(timelineAt: 1_700_000_100, unreadCount: 3),
            account: account,
            shouldEnrich: false
        )
        #expect(state.activeChats.first?.updatedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar)

        // The same row, now read: the badge has to follow it down, so this one does query.
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        await state.applyChatRow(
            unreadBadgeFixtureRow(timelineAt: 1_700_000_200, unreadCount: 0),
            account: account,
            shouldEnrich: false
        )
        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar + 1)
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
    }

    @MainActor
    @Test func archivingAnUnreadChatDropsItFromTheAvatarBadge() async throws {
        // The summary counts unarchived conversations alone, so archiving an unread chat has to
        // take its messages off the rail badge. It did not: the row gate compared totals that
        // counted the archived list too, so the move left the signal untouched — the chat's unread
        // was still in it, just under a different key — and the badge kept counting a chat the user
        // had put away until the next full reload or account switch.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 3)
        ]
        let (state, account) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 3)

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 3)
        let queriesSoFar = runtime.accountUnreadSummaryCallCount

        // The archived row keeps its unread count — the core does not clear it, it stops counting
        // it — which is exactly what made this move invisible to a signal spanning both lists.
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        await state.applyChatRow(
            unreadBadgeFixtureRow(timelineAt: 1_700_000_100, unreadCount: 3, archived: true),
            account: account,
            shouldEnrich: false
        )

        #expect(state.activeChats.isEmpty)
        #expect(state.archivedChats.map(\.unreadCount) == [3])
        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar + 1)
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
    }

    @MainActor
    @Test func unarchivingAnUnreadChatPutsItBackOnTheAvatarBadge() async throws {
        // The other direction of the same move: restoring a chat that was archived unread returns
        // its messages to the total the badge shows, and the gate has to notice that too.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        let (state, account) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 0,
            archivedChats: [
                chatListOrderingTestItem(
                    id: "archived-group",
                    title: "Archived Group",
                    updatedAt: 1_700_000_000,
                    unreadCount: 4
                )
            ]
        )

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
        let queriesSoFar = runtime.accountUnreadSummaryCallCount

        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 4)
        ]
        await state.applyChatRow(
            chatListRow(
                groupIdHex: "archived-group",
                title: "Archived Group",
                preview: "A message from before it was archived",
                sender: unreadBadgeFixtureAccountIdHex,
                timelineAt: 1_700_000_100,
                unreadCount: 4,
                hasUnread: true
            ),
            account: account,
            shouldEnrich: false
        )

        #expect(state.archivedChats.isEmpty)
        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar + 1)
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 4)
    }

    @MainActor
    @Test func readingAnArchivedChatDoesNotRequeryTheAccountUnreadSummary() async throws {
        // The flip side of scoping the gate to unarchived rows: nothing an archived chat's unread
        // does can move a total that excludes it, so scrolling through one must not put a summary
        // query on every read-marker advance it produces.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        let (state, account) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 0,
            archivedChats: [
                chatListOrderingTestItem(
                    id: "archived-group",
                    title: "Archived Group",
                    updatedAt: 1_700_000_000,
                    unreadCount: 6
                )
            ]
        )

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
        let queriesSoFar = runtime.accountUnreadSummaryCallCount

        // A marker advance inside the archived chat, then a newer message arriving in it.
        await state.applyChatRow(
            chatListRow(
                groupIdHex: "archived-group",
                title: "Archived Group",
                preview: "Read now",
                sender: unreadBadgeFixtureAccountIdHex,
                timelineAt: 1_700_000_100,
                unreadCount: 0,
                archived: true
            ),
            account: account,
            shouldEnrich: false
        )
        await state.applyChatRow(
            chatListRow(
                groupIdHex: "archived-group",
                title: "Archived Group",
                preview: "And a new one",
                sender: unreadBadgeFixtureAccountIdHex,
                timelineAt: 1_700_000_200,
                unreadCount: 1,
                hasUnread: true,
                archived: true
            ),
            account: account,
            shouldEnrich: false
        )

        #expect(state.archivedChats.map(\.unreadCount) == [1])
        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar)
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
    }

    @MainActor
    @Test func aLateAccountUnreadSummaryAnswerDoesNotRestoreTheClearedBadge() async throws {
        // A read-marker advance and a chat-list reload race routinely, so two summary queries can
        // be in flight and answer out of order. A late pre-read answer landing last must not put
        // the badge back — nor record its signal, which would leave the row gate suppressing the
        // refresh that would correct it.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 5)
        ]
        let (state, account) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 5)

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 5)

        // Park the older query inside the FFI, still holding the pre-read total of 5.
        runtime.accountUnreadSummaryGateEnabled = true
        let staleRefresh = Task { await state.refreshAccountUnreadSummary() }
        #expect(await waitFor { runtime.didReachAccountUnreadSummaryGate })

        // The chat is read: the row delta gates a newer query, which answers first with nothing
        // unread while the older one is still parked.
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        await state.applyChatRow(
            unreadBadgeFixtureRow(timelineAt: 1_700_000_100, unreadCount: 0),
            account: account,
            shouldEnrich: false
        )
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)

        runtime.releaseAccountUnreadSummaryGate()
        await staleRefresh.value

        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
        #expect(state.lastSummarizedAccountUnread?.totalUnreadCount == 0)
    }

    @MainActor
    @Test func anAccountUnreadSummaryAnswerForASupersededAccountIsDiscarded() async throws {
        // The totals are keyed by account, but the recorded signal is not: committing an answer
        // requested by a since-replaced active account would file its counts under the new
        // account's signal and suppress that account's next refresh.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 5)
        ]
        let (state, account) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 5)

        runtime.accountUnreadSummaryGateEnabled = true
        let supersededRefresh = Task { await state.refreshAccountUnreadSummary() }
        #expect(await waitFor { runtime.didReachAccountUnreadSummaryGate })

        // The user switches accounts while the query is still off-main.
        state.activeAccountId = "some-other-account"
        runtime.releaseAccountUnreadSummaryGate()
        await supersededRefresh.value

        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
        #expect(state.lastSummarizedAccountUnread == nil)
    }

    @MainActor
    @Test func aChatListReloadIssuesASingleAccountUnreadSummaryQuery() async throws {
        // The reload owns one unconditional refresh — the only pass that also re-reads background
        // accounts' totals — so the snapshot it applies must not gate a second query of its own.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.installGroup(messageGroup())
        // The selected chat's read-state row is the one other caller that would apply a chat row
        // during the reload, and it answers off-main; withholding it keeps the queries counted here
        // attributable to the reload alone.
        runtime.initializeChatReadStateReturnsRow = false
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        // Seeded unread with a recorded signal to match, so the reload's all-read snapshot moves
        // the signal and would gate a refresh of its own on top of the reload's own query.
        let (state, account) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 5)
        state.lastSummarizedAccountUnread = state.currentAccountUnreadSignal()
        state.reloadChatsGeneration = 41
        let queriesSoFar = runtime.accountUnreadSummaryCallCount

        await state.performChatListReload(accountId: account.id, generation: 41)

        #expect(state.activeChats.first?.unreadCount == 0)
        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar + 1)
    }

    @MainActor
    @Test func theAvatarBadgeCountsAnUnansweredInviteAsOne() async throws {
        // An unaccepted invite has no timeline, so it moves no unread total however long it sits in
        // the chat list: the rail badge read "nothing to see" while rows were asking to be answered.
        // Each one is worth +1, matching the core's own badge aggregate and the `+` the row draws.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 2)
        ]
        let (state, account) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 2,
            additionalChats: [
                pendingInviteChatItem(id: "invite-one"),
                pendingInviteChatItem(id: "invite-two"),
            ]
        )

        await state.refreshAccountUnreadSummary()

        #expect(state.pendingInviteCount(forAccountIdHex: account.accountIdHex) == 2)
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 4)
    }

    @MainActor
    @Test func theAvatarBadgeSkipsArchivedAndEndedInvites() async throws {
        // Parity with the core's `attention_only_conversations`, which counts a pending row only
        // while it is unarchived and the local membership has not ended. Both exclusions matter to
        // the badge too: an archived invite was put away deliberately, and an ended membership
        // supersedes a pending invite outright — the sidebar row draws "Removed" in its place, so a
        // badge counting it would point at a row that never mentions an invite.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        let (state, account) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 0,
            additionalChats: [pendingInviteChatItem(id: "invite-removed", selfMembership: .removed)],
            archivedChats: [pendingInviteChatItem(id: "invite-archived")]
        )

        await state.refreshAccountUnreadSummary()

        #expect(state.archivedChats.count == 1)
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
    }

    @MainActor
    @Test func answeringAnInviteMovesTheBadgeOnTheRowAlone() async throws {
        // The active account's invites are counted off its live rows rather than off the summary,
        // so accepting one moves the badge on the chat-row update itself — no FFI round trip to
        // wait through, and no window where the badge and the list disagree.
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0)
        ]
        let (state, account) = unreadBadgeFixture(
            runtime: runtime,
            seededUnreadCount: 0,
            additionalChats: [pendingInviteChatItem(id: "invite")]
        )

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 1)
        let queriesSoFar = runtime.accountUnreadSummaryCallCount

        // The answered invite comes back as an ordinary row.
        await state.applyChatRow(
            pendingInviteRow(groupIdHex: "invite", pendingConfirmation: false),
            account: account,
            shouldEnrich: false
        )

        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
        #expect(runtime.accountUnreadSummaryCallCount == queriesSoFar)
    }

    @MainActor
    @Test func aBackgroundAccountsUnansweredInviteMovesItsAvatarBadge() async throws {
        // Only the active account runs a chat-list subscription, so a background account's invites
        // can never arrive as row deltas — its badge would have kept counting messages alone. The
        // full summary pass reads them off that account's projection, which needs no session load.
        let backup = backupAccountSummary()
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0),
            unreadSummaryRow(accountIdHex: backup.accountIdHex, unreadCount: 3),
        ]
        runtime.chatListRowsByAccountRef = [
            backup.label: [
                pendingInviteRow(groupIdHex: "invite-for-backup"),
                // The exclusions have to hold on this path too, where the rows arrive unmapped.
                pendingInviteRow(groupIdHex: "invite-archived", archived: true),
                pendingInviteRow(groupIdHex: "invite-left", selfMembership: .left),
                unreadBadgeFixtureRow(timelineAt: 1_700_000_000, unreadCount: 3),
            ]
        ]
        let (state, active) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 0)
        state.accounts.append(AccountItem(summary: backup))

        await state.refreshAccountUnreadSummary()

        #expect(state.unreadCount(forAccountIdHex: backup.accountIdHex) == 4)
        #expect(state.unreadCount(forAccountIdHex: active.accountIdHex) == 0)
        // The active account is answered from its live rows, so it is never read one-shot here.
        #expect(runtime.chatListAccountRefs == [backup.label])
    }

    @MainActor
    @Test func aFailedInviteReadKeepsTheBadgeItLastRecorded() async throws {
        // Badges are best-effort. One projection read failing must not drop an invitation off the
        // rail, which would read as the invite having been answered somewhere else.
        let backup = backupAccountSummary()
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0),
            unreadSummaryRow(accountIdHex: backup.accountIdHex, unreadCount: 0),
        ]
        runtime.chatListRowsByAccountRef = [backup.label: [pendingInviteRow(groupIdHex: "invite-for-backup")]]
        let (state, _) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 0)
        state.accounts.append(AccountItem(summary: backup))

        await state.refreshAccountUnreadSummary()
        #expect(state.unreadCount(forAccountIdHex: backup.accountIdHex) == 1)

        runtime.chatListError = FakeMarmotRuntimeError.unused
        await state.refreshAccountUnreadSummary()

        #expect(state.unreadCount(forAccountIdHex: backup.accountIdHex) == 1)
    }

    @MainActor
    @Test func chatRowDeltasDoNotRereadTheOtherAccountsInviteCounts() async throws {
        // The row-gated refresh exists so the badge does not put an FFI call on every read-marker
        // advance. Invitations must not reintroduce one: no delta of the active account's rows can
        // move another account's invites, and its own are counted off those very rows.
        let backup = backupAccountSummary()
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 3),
            unreadSummaryRow(accountIdHex: backup.accountIdHex, unreadCount: 0),
        ]
        let (state, account) = unreadBadgeFixture(runtime: runtime, seededUnreadCount: 3)
        state.accounts.append(AccountItem(summary: backup))

        await state.refreshAccountUnreadSummary()
        let readsSoFar = runtime.chatListCallCount

        // The seeded row, now read: the unread total moved, so the summary itself is re-queried.
        runtime.accountUnreadSummaryRows = [
            unreadSummaryRow(accountIdHex: unreadBadgeFixtureAccountIdHex, unreadCount: 0),
            unreadSummaryRow(accountIdHex: backup.accountIdHex, unreadCount: 0),
        ]
        await state.applyChatRow(
            unreadBadgeFixtureRow(timelineAt: 1_700_000_100, unreadCount: 0),
            account: account,
            shouldEnrich: false
        )

        #expect(state.unreadCount(forAccountIdHex: account.accountIdHex) == 0)
        #expect(runtime.chatListCallCount == readsSoFar)
    }

    @MainActor
    @Test func resetActiveAccountUIStateClearsReadMarkersAndDeliveredNotificationKeys() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
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
    @Test func prepareForActiveAccountSwitchClearsReadMarkers() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let primaryAccount = AccountItem(summary: primary)
        let backupAccount = AccountItem(summary: backup)
        let runtime = FakeMarmotRuntime(accounts: [primary, backup])
        let state = WorkspaceState(
            accounts: [primaryAccount, backupAccount],
            clientFactory: { runtime }
        )
        state.activeAccountId = primaryAccount.id

        let marker = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageId: "m10"
        )
        state.lastMarkedReadMarkers["shared-group"] = marker
        state.lastConfirmedReadMarkers["shared-group"] = marker
        state.composeContacts = [
            ComposeContact(
                accountIdHex: String(repeating: "2", count: 64),
                npub: "npub1accountacontact",
                displayName: "Account A contact",
                pictureURL: "https://example.com/account-a.png",
                lastActivity: Date()
            )
        ]
        state.isLoadingComposeContacts = true
        state.composeContactsGeneration = 41

        state.prepareForActiveAccountSwitch(to: backupAccount, preservingMessageCacheFor: nil)

        // Live account switches must not inherit groupIdHex-keyed read markers or the
        // previous identity's compose-flow contact directory. See #429/#588.
        #expect(state.lastMarkedReadMarkers.isEmpty)
        #expect(state.lastConfirmedReadMarkers.isEmpty)
        #expect(state.composeContacts.isEmpty)
        #expect(!state.isLoadingComposeContacts)
        #expect(state.composeContactsGeneration == 42)
        #expect(state.activeAccountId == backupAccount.id)
    }

    @MainActor
    @Test func resetActiveAccountUIStateClearsConversationMetadata() {
        let state = WorkspaceState.preview()
        state.conversationMetadataByChat["shared-group"] = ConversationMetadata(
            memberCount: 3,
            disappearingMessageSecs: 60,
            isSelfAdmin: true
        )
        state.conversationMetadataGenerationByChat["shared-group"] = 41

        state.resetActiveAccountUIState()

        // Sign-out and active-account removal share this reset path; metadata keyed only by
        // group id must not leak the previous identity's role or group details. See #628.
        #expect(state.conversationMetadataByChat.isEmpty)
        #expect(state.conversationMetadataGenerationByChat.isEmpty)
    }

    @MainActor
    @Test func prepareForActiveAccountSwitchClosesGroupDetails() async throws {
        let primary = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, backup])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: primary.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let primaryAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        state.prepareForActiveAccountSwitch(to: primaryAccount, preservingMessageCacheFor: nil)
        await state.reloadChats(forceFreshSnapshot: true)
        let groupChat = try #require(state.activeChats.first { $0.id == "group" })
        await state.showGroupDetails(for: groupChat)
        #expect(state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot?.members.count == 3)

        state.groupProfileDraftName = "Private group name"
        state.groupProfileDraftDescription = "Private group description"
        state.groupInviteMemberQuery = "npub1pryvateynvyte"
        state.groupTranscriptExportStatus = "Exported 1 transcript event to /tmp/transcript.json."
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })

        state.prepareForActiveAccountSwitch(to: backupAccount, preservingMessageCacheFor: nil)

        // Live switches are account-boundary teardown: account A's details/transcript-export UI
        // must not stay visible under account B. See #420.
        #expect(state.activeAccountId == backupAccount.id)
        #expect(!state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot == nil)
        #expect(state.groupProfileDraftName.isEmpty)
        #expect(state.groupProfileDraftDescription.isEmpty)
        #expect(state.groupInviteMemberQuery.isEmpty)
        #expect(state.groupTranscriptExportStatus == nil)
    }

    @MainActor
    @Test func groupTranscriptExportDoesNotPublishAfterAccountSwitch() async throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let primary = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, backup])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: primary.accountIdHex))

        let exportEntered = DispatchSemaphore(value: 0)
        let releaseExport = DispatchSemaphore(value: 0)
        let messageId = String(repeating: "1", count: 64)
        runtime.timelineMessagesHandler = { query in
            if query.before == nil {
                exportEntered.signal()
                _ = releaseExport.wait(timeout: .now() + 5)
                return TimelinePageFfi(
                    messages: [
                        timelineMessage(
                            id: messageId,
                            groupIdHex: "group",
                            sender: primary.accountIdHex,
                            plaintext: "account A decrypted transcript",
                            recordedAt: 1_700_000_000
                        )
                    ],
                    hasMoreBefore: false,
                    hasMoreAfter: false
                )
            }
            return TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        let state = WorkspaceState(
            transcriptExportDestinationPicker: { _ in files.destination },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let primaryAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        state.prepareForActiveAccountSwitch(to: primaryAccount, preservingMessageCacheFor: nil)
        await state.reloadChats(forceFreshSnapshot: true)
        let groupChat = try #require(state.activeChats.first { $0.id == "group" })
        await state.showGroupDetails(for: groupChat)

        state.startExportSelectedGroupTranscript()
        let exportTask = try #require(state.groupTranscriptExportTask)
        #expect(await waitForSemaphore(exportEntered, timeout: .now() + 2) == .success)

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.prepareForActiveAccountSwitch(to: backupAccount, preservingMessageCacheFor: nil)
        releaseExport.signal()
        await exportTask.value

        #expect(state.activeAccountId == backupAccount.id)
        #expect(!FileManager.default.fileExists(atPath: files.destination.path))
        #expect(state.groupTranscriptExportStatus == nil)
    }

    @MainActor
    @Test func resetActiveAccountUIStateClearsGroupAndNewChatPII() async throws {
        let primary = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [primary])
        runtime.installGroup(messageGroup())
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: primary.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.members.count == 3)

        state.groupProfileDraftName = "Private group name"
        state.groupProfileDraftDescription = "Private group description"
        state.groupInviteMemberQuery = "npub1pryvateynvyte"
        state.isGroupImagePickerPresented = true
        state.groupImageSearchQuery = "private avatar"
        state.groupImageResults = [
            GroupImageSearchResult(
                id: "image-1",
                title: "Private Avatar",
                imageURL: "https://example.com/private-avatar.jpg",
                thumbnailURL: "https://example.com/private-avatar-thumb.jpg",
                creator: "Private Creator",
                license: "cc0",
                attribution: nil,
                sourceURL: nil,
                width: 128,
                height: 128
            )
        ]
        let recipient = NewChatRecipient(
            sourceQuery: "npub1recypyent",
            memberRef: "npub1recypyent",
            accountIdHex: "recipient1234567890recipient1234567890recipient1234567890recip1",
            npub: "npub1recypyent",
            displayName: "Private Recipient",
            pictureURL: "https://example.com/recipient.png"
        )
        state.newChatQuery = "npub1recypyent"
        state.newChatName = "Private chat"
        state.newChatDescription = "Private chat description"
        state.newChatRecipient = recipient
        state.newChatRecipients = [recipient]
        state.composeContacts = [
            ComposeContact(
                accountIdHex: recipient.accountIdHex,
                npub: recipient.npub,
                displayName: recipient.displayName,
                pictureURL: recipient.pictureURL,
                lastActivity: Date()
            )
        ]
        state.isLoadingComposeContacts = true
        state.composeContactsGeneration = 41

        state.resetActiveAccountUIState()

        // Sign-out and active-account removal share this reset path; group-scoped
        // roster/details, invite queries, image-picker results, new-chat recipients,
        // and the compose contact directory must not survive account teardown. See #398/#588.
        #expect(!state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot == nil)
        #expect(state.groupProfileDraftName.isEmpty)
        #expect(state.groupProfileDraftDescription.isEmpty)
        #expect(state.groupInviteMemberQuery.isEmpty)
        #expect(!state.isGroupImagePickerPresented)
        #expect(state.groupImageSearchQuery.isEmpty)
        #expect(state.groupImageResults.isEmpty)
        #expect(state.newChatQuery.isEmpty)
        #expect(state.newChatName.isEmpty)
        #expect(state.newChatDescription.isEmpty)
        #expect(state.newChatRecipient == nil)
        #expect(state.newChatRecipients.isEmpty)
        #expect(state.composeContacts.isEmpty)
        #expect(!state.isLoadingComposeContacts)
        #expect(state.composeContactsGeneration == 42)
    }

    @MainActor
    @Test func removeNonActiveAccountClearsItsUnreadBadge() async throws {
        let primary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
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

    @Test func deleteAllLocalDataThrowsAndPreservesStorageWhenAccountKeychainPurgeFails() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-delete-all-data-\(UUID().uuidString)", isDirectory: true)
        let secretFile = root.appendingPathComponent("private-identity.sqlite")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("private key material".utf8).write(to: secretFile)
        defer { try? fileManager.removeItem(at: root) }

        var didShutdown = false
        let purgeError = MarmotAccountKeychainPurgeError.deleteFailed(-50)

        await #expect(throws: MarmotAccountKeychainPurgeError.deleteFailed(-50)) {
            try await MarmotClient.deleteAllLocalData(
                purgeAccountKeychain: { throw purgeError },
                shutdown: { didShutdown = true },
                rootPath: root.path,
                fileManager: fileManager
            )
        }

        #expect(!didShutdown)
        #expect(fileManager.fileExists(atPath: root.path))
        #expect(fileManager.fileExists(atPath: secretFile.path))
    }

    @Test func deleteAllLocalDataPurgesKeychainBeforeShutdownAndStorageWipe() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-delete-all-data-\(UUID().uuidString)", isDirectory: true)
        let secretFile = root.appendingPathComponent("mls-state.sqlite")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("mls group state".utf8).write(to: secretFile)
        defer { try? fileManager.removeItem(at: root) }

        var operationOrder: [String] = []

        try await MarmotClient.deleteAllLocalData(
            purgeAccountKeychain: { operationOrder.append("purge") },
            shutdown: { operationOrder.append("shutdown") },
            rootPath: root.path,
            fileManager: fileManager
        )

        #expect(operationOrder == ["purge", "shutdown"])
        #expect(fileManager.fileExists(atPath: root.path))
        #expect(!fileManager.fileExists(atPath: secretFile.path))
    }

    @Test func deleteAllLocalDataMarksPostShutdownFilesystemFailureAsRuntimeInvalidating() async throws {
        let fileManager = FileManager.default
        let parentFile = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-delete-parent-\(UUID().uuidString)")
        let root = parentFile.appendingPathComponent("storage", isDirectory: true)
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? fileManager.removeItem(at: parentFile) }

        var didPurgeKeychain = false
        var didShutdown = false
        do {
            try await MarmotClient.deleteAllLocalData(
                purgeAccountKeychain: { didPurgeKeychain = true },
                shutdown: { didShutdown = true },
                rootPath: root.path,
                fileManager: fileManager
            )
            Issue.record("Expected storage recreation to fail below a regular file")
        } catch let error as MarmotLocalDataDeletionError {
            guard case .runtimeInvalidated = error else {
                Issue.record("Expected a runtime-invalidating deletion error")
                return
            }
        }

        #expect(didPurgeKeychain)
        #expect(didShutdown)
    }

    @Test func deleteAllLocalDataSucceedsWhenOrphanedKeychainCredentialRemainsAfterTombstone() async throws {
        // MDK remove_account tombstones before Keychain deletion; a failed removal leaves an
        // orphaned credential that later enumeration cannot retry. Service purge must clear it
        // without listing accounts.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-delete-all-data-\(UUID().uuidString)", isDirectory: true)
        let secretFile = root.appendingPathComponent("orphaned-keychain-credential")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("disk state survives tombstone".utf8).write(to: secretFile)
        defer { try? fileManager.removeItem(at: root) }

        var didPurgeOrphanedCredential = false

        try await MarmotClient.deleteAllLocalData(
            purgeAccountKeychain: { didPurgeOrphanedCredential = true },
            shutdown: {},
            rootPath: root.path,
            fileManager: fileManager
        )

        #expect(didPurgeOrphanedCredential)
        #expect(fileManager.fileExists(atPath: root.path))
        #expect(!fileManager.fileExists(atPath: secretFile.path))
    }

    @Test func deleteAllLocalDataSucceedsWhenHiddenKeychainCredentialWouldBeSkippedByEnumeration() async throws {
        // MDK AccountHome::accounts() silently skips unreadable records. Service purge must
        // remove hidden credentials without depending on a complete account list.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-delete-all-data-\(UUID().uuidString)", isDirectory: true)
        let secretFile = root.appendingPathComponent("partial-enumeration-disk-state")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("visible account disk state".utf8).write(to: secretFile)
        defer { try? fileManager.removeItem(at: root) }

        var didPurgeHiddenCredential = false

        try await MarmotClient.deleteAllLocalData(
            purgeAccountKeychain: { didPurgeHiddenCredential = true },
            shutdown: {},
            rootPath: root.path,
            fileManager: fileManager
        )

        #expect(didPurgeHiddenCredential)
        #expect(fileManager.fileExists(atPath: root.path))
        #expect(!fileManager.fileExists(atPath: secretFile.path))
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

    /// Your own avatar always draws; everyone else's waits for the preference.
    ///
    /// "Load Remote Profile Images" is off by default because profile pictures come from URLs
    /// *other people* control. That reasoning covers every avatar the viewer did not choose and none
    /// of the one they did: the viewer picked their own in the profile editor, the app uploaded it
    /// to the Blossom server *the app* chose, and fetching it back discloses their address to a host
    /// they have just handed the image to. Gating it made the editor look broken rather than
    /// private — the upload succeeded, the draft took the URL, and the avatar kept drawing initials
    /// with no error to explain why.
    ///
    /// `RemoteImageDisplayPolicy`'s documentation names the six surfaces that may claim an image as
    /// the viewer's own; the account rail is one of them because it is fed `signedInAccounts` and so
    /// draws nothing but the viewer's own identities.
    @Test func onlyTheViewersOwnAvatarIgnoresTheRemoteImagePreference() {
        for preferenceEnabled in [true, false] {
            #expect(
                RemoteImageDisplayPolicy.loadsRemoteImage(
                    isOwnAccountImage: true,
                    preferenceEnabled: preferenceEnabled
                ),
                "the viewer's own picture must draw whatever the preference says"
            )
        }

        #expect(
            !RemoteImageDisplayPolicy.loadsRemoteImage(
                isOwnAccountImage: false,
                preferenceEnabled: false
            ),
            "a peer's avatar was fetched with the preference off"
        )
        #expect(
            RemoteImageDisplayPolicy.loadsRemoteImage(
                isOwnAccountImage: false,
                preferenceEnabled: true
            )
        )
    }

    /// The rail switches identities and does nothing else to them.
    ///
    /// It used to carry a Sign In / Sign Out context menu whose Sign Out fired straight from a
    /// right-click with no prompt — an accidental click dropped that identity's relay key packages —
    /// and it used to draw deactivated identities, dimmed behind a pause glyph, where a single tap
    /// signed one back in. Both are gone, and what holds them gone is the *list*: the rail is fed
    /// `signedInAccounts`, so a deactivated identity never reaches it to be managed. That filter is
    /// what this drives, along with the one action the rail does have.
    @MainActor
    @Test func theAccountRailListsOnlySignedInIdentitiesAndOnlySwitchesBetweenThem() async throws {
        let active = desktopAccount()
        let other = AccountSummaryFfi(
            label: "Second Account",
            accountIdHex: String(repeating: "b2", count: 32),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let deactivated = AccountSummaryFfi(
            label: "Deactivated Account",
            accountIdHex: String(repeating: "c3", count: 32),
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [active, other, deactivated])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        #expect(state.accounts.count == 3, "the app still knows about the deactivated identity")
        #expect(
            !state.signedInAccounts.contains { $0.accountIdHex == deactivated.accountIdHex },
            "a deactivated identity reached the rail, where a single click used to sign it back in"
        )
        #expect(state.signedInAccounts.count == 2)

        // The rail's one action: switching. It signs nothing out and signs nothing in.
        let signOutsBefore = runtime.signOutCallCount
        let signInsBefore = runtime.signInAccountCallCount
        let target = try #require(state.signedInAccounts.first { $0.id != state.activeAccountId })
        state.selectAccount(target)

        #expect(state.activeAccountId == target.id)
        #expect(runtime.signOutCallCount == signOutsBefore, "switching identities signed one out")
        #expect(
            runtime.signInAccountCallCount == signInsBefore,
            "switching identities signed one in")
    }

    /// With nothing signed in, the app shows the way in rather than a list of deactivated
    /// identities.
    ///
    /// The detail pane used to be a `SignedOutAccountsView`: the deactivated identities on this Mac,
    /// each row one click from a sign-in that asked for no key. Getting into an identity is Sign In
    /// or Sign Up now, and the core reactivates a matching signed-out account on `login` rather than
    /// creating a second one — so that identity's chats come back through the real flow rather than
    /// around it. What holds the chooser gone is the routing: every path that empties the signed-in
    /// list moves the app to `.onboarding` itself.
    @MainActor
    @Test func withNothingSignedInTheAppRoutesToOnboardingRatherThanToAChooser() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        #expect(state.phase == .ready)
        let active = try #require(state.activeAccount)

        await state.signOutAccount(active)

        #expect(state.activeAccount == nil)
        #expect(state.signedInAccounts.isEmpty)
        #expect(
            state.phase == .onboarding,
            "the app stayed on a pane with no signed-in identity to draw"
        )

        // Signing that identity back in is the real flow, with its key, and the core reactivates
        // the account it matches rather than adding a second one.
        #expect(!state.accounts.isEmpty, "the deactivated identity is still held on this Mac")
    }

    @MainActor
    @Test func tappingTheActiveAccountAvatarWhileReadingChatsChangesNothing() async throws {
        // Tapping the rail avatar that is already selected used to run the full account switch:
        // every cached timeline was dropped, the chat-list listener was torn down and re-subscribed,
        // and the filter/search were reset — so the window blanked and reloaded for a tap that
        // could not change anything. It must now be inert.
        let state = WorkspaceState.preview()
        let active = try #require(state.activeAccount)
        let openChat = try #require(state.selectedChat)
        state.chatListFilter = .archived
        state.searchText = "invoice"
        let cachedChatIdsBefore = state.cachedMessageChatIds
        let reloadGenerationBefore = state.reloadChatsGeneration
        #expect(!cachedChatIdsBefore.isEmpty)

        state.selectAccount(active)

        #expect(state.activeAccountId == active.id)
        #expect(state.selection == .chat(openChat.id))
        #expect(state.cachedMessageChatIds == cachedChatIdsBefore)
        #expect(state.chatListFilter == .archived)
        #expect(state.searchText == "invoice")
        // The teardown cancels any in-flight chat-list reload and starts a new one; the generation
        // counter is the synchronous witness that neither happened.
        #expect(state.reloadChatsGeneration == reloadGenerationBefore)
    }

    @MainActor
    @Test func tappingTheActiveAccountAvatarStillLeavesSettings() async throws {
        // The rail avatar is the only way back to the chats from Settings, so the same-account tap
        // cannot be a plain no-op: it still has to leave a non-chat surface, just without the
        // account-switch teardown.
        let state = WorkspaceState.preview()
        let active = try #require(state.activeAccount)
        state.showSettings(.overview)
        #expect(state.isShowingSettings)

        state.selectAccount(active)

        #expect(!state.isShowingSettings)
        #expect(state.activeAccountId == active.id)
        let landedOn = try #require(state.selectedChat)
        #expect(state.activeChats.contains { $0.id == landedOn.id })
    }

    @MainActor
    @Test func tappingTheActiveAccountAvatarClosesTheNewChatComposer() async throws {
        // The composer covers the chat list, so the rail avatar still dismisses it — but the
        // conversation behind it stays selected.
        let state = WorkspaceState.preview()
        let active = try #require(state.activeAccount)
        let openChat = try #require(state.selectedChat)
        state.showNewChat()
        #expect(state.isNewChatComposerVisible)

        state.selectAccount(active)

        #expect(!state.isNewChatComposerVisible)
        #expect(state.selection == .chat(openChat.id))
    }

    @MainActor
    @Test func reselectingTheActiveAccountRowInSettingsKeepsTheSessionLoaded() async throws {
        // `selectAccountFromSettings` guards the already-active identity: a switch anchored to the
        // settings page on screen would tear the session down and rebuild it only to land back
        // there. No view reaches it since the switcher popover went, but the guard is the landing
        // rule any in-Settings switch wants, so it stays exercised.
        let state = WorkspaceState.preview()
        let active = try #require(state.activeAccount)
        state.showSettings(.relays)
        let cachedChatIdsBefore = state.cachedMessageChatIds
        let reloadGenerationBefore = state.reloadChatsGeneration

        state.selectAccountFromSettings(active)

        #expect(state.selection == .settings(.relays))
        #expect(state.activeAccountId == active.id)
        #expect(state.cachedMessageChatIds == cachedChatIdsBefore)
        #expect(state.reloadChatsGeneration == reloadGenerationBefore)
    }

    @MainActor
    @Test func tappingTheActiveAccountAvatarKeepsTheLoadedSessionAndItsListener() async throws {
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let chat = try #require(state.activeChats.first { $0.id == "group" })
        state.selectChat(chat)
        #expect(await waitFor { state.cachedMessageChatIds.contains("group") })
        #expect(await waitFor { state.chatListTask != nil })

        let reloadGenerationBefore = state.reloadChatsGeneration
        let active = try #require(state.activeAccount)

        state.selectAccount(active)

        // The account-switch teardown stops the chat-list listener and cancels the in-flight
        // reload (bumping the generation) before re-subscribing both; on a same-account tap the
        // loaded session has to survive untouched.
        #expect(state.chatListTask != nil)
        #expect(state.reloadChatsGeneration == reloadGenerationBefore)
        #expect(state.selection == .chat("group"))
        #expect(state.cachedMessageChatIds.contains("group"))
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
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "secondary-account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
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
    @Test func notificationResponseForActiveAccountAllowsUnsyncedGroupBeforeReload() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "primary-account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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
        #expect(state.activeAccountId == account.label)

        // Simulate a notification for an active-account chat that the runtime can return,
        // but the current chat-list snapshot has not learned about yet. The tap path must
        // select first and let the reload discover it, not reject it as unavailable.
        state.setChats([], forAccountId: account.label)
        state.selection = .settings(.overview)
        runtime.clearTimelineMessageQueries()

        state.handleNotificationResponse([
            "groupIdHex": "direct-group",
            "accountIdHex": account.accountIdHex,
            "accountRef": account.label,
        ])

        #expect(state.selection == .chat("direct-group"))
        #expect(
            state.backgroundStatus
                != "This notification is for an account or chat that is no longer available."
        )
    }

    @MainActor
    @Test func notificationResponseForUnresolvableAccountDoesNotSelectForeignGroup() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "primary-account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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
        #expect(state.activeAccountId == account.label)
        #expect(state.selection == .chat("direct-group"))

        runtime.clearTimelineMessageQueries()
        state.handleNotificationResponse([
            "groupIdHex": "foreign-group",
            "accountIdHex": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "accountRef": "removed-account",
        ])

        #expect(state.activeAccountId == account.label)
        #expect(state.selection == .chat("direct-group"))
        #expect(
            state.backgroundStatus
                == "This notification is for an account or chat that is no longer available."
        )
        #expect(runtime.timelineMessageQueries.isEmpty)
    }

    @MainActor
    @Test func notificationResponseForSignedOutAccountDoesNotSwitchOrSelectForeignGroup() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.activeAccountId")

        let primary = AccountSummaryFfi(
            label: "primary-account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let signedOut = AccountSummaryFfi(
            label: "signed-out-account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: true,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, signedOut])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: primary.accountIdHex,
            otherAccountIdHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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
        #expect(state.activeAccountId == primary.label)
        #expect(state.selection == .chat("direct-group"))

        runtime.clearTimelineMessageQueries()
        state.handleNotificationResponse([
            "groupIdHex": "foreign-group",
            "accountIdHex": signedOut.accountIdHex,
            "accountRef": signedOut.label,
        ])

        #expect(state.activeAccountId == primary.label)
        #expect(state.selection == .chat("direct-group"))
        #expect(
            state.backgroundStatus
                == "This notification is for an account or chat that is no longer available."
        )
        #expect(runtime.timelineMessageQueries.isEmpty)
    }
}
