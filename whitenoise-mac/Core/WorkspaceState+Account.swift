//
//  WorkspaceState+Account.swift
//  whitenoise-mac
//
//  Account behavior extracted from WorkspaceState.swift (no behavior change).
//

import AVFoundation
import AppKit
import Combine
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

@MainActor
extension WorkspaceState {
    func bootstrap() async {
        guard client == nil, case .bootstrapping = phase else { return }
        lastError = nil
        // Wipe any decrypted attachment plaintext left in the playback scratch directory by
        // a prior session before the UI can surface new media.
        try? await runOffMain { MediaPlaybackTempStore.purge() }
        do {
            let runtime = try clientFactory()
            client = runtime
            storageRootPath = runtime.storageRootPath
            let summaries = try await runOffMain {
                try runtime.listAccounts()
            }
            accounts = try await accountItems(from: summaries, client: runtime)
            restoreOrSelectFirstAccount()
            try await configureObservabilityRuntime()
            if accounts.isEmpty {
                phase = .onboarding
                return
            }

            try await bringRuntimeOnline(runtime)
            accounts = try await accountItemsFromRuntime(client: runtime)
            restoreOrSelectFirstAccount()
            try await activateReadyState()
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func selectAccount(_ account: AccountItem) {
        switchActiveAccount(
            account,
            finalSelection: chatsByAccount[account.id]?.first.map { WorkspaceSelection.chat($0.id) }
        )
    }

    func selectAccountFromSettings(_ account: AccountItem) {
        switchActiveAccount(account, finalSelection: .settings(.accounts))
    }

    func switchActiveAccount(_ account: AccountItem, finalSelection: WorkspaceSelection?) {
        prepareForActiveAccountSwitch(to: account, preservingMessageCacheFor: nil)
        selection = finalSelection
        if case .chat(let chatId)? = finalSelection {
            beginTimelineInitialLoadIfNeeded(groupIdHex: chatId)
        }
        Task {
            await reloadChats()
            if let selectedChat {
                await loadMessages(groupIdHex: selectedChat.id)
            }
        }
    }

    /// Performs all account-scoped teardown before any chat or message reloads run.
    /// Keeping listener stops, cache pruning, peer-profile invalidation, and
    /// observability refresh together prevents reloads from seeing stale account state.
    func prepareForActiveAccountSwitch(
        to account: AccountItem,
        preservingMessageCacheFor groupIdHex: String?
    ) {
        cancelVoiceRecording()
        stopTimelineListener()
        stopChatListListener()
        clearEnteredLoginIdentity()
        activeAccountId = account.id
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        searchText = ""
        closeNewChatComposer()
        pruneMessageCache(keeping: groupIdHex)
        // Lookup caches are scoped to the active account's view (directory display names and
        // group membership visibility can differ per account); drop them on switch so the new
        // account does not inherit stale cross-account entries (whitenoise-mac#8/#9).
        peerProfileFFICache.removeAll()
        clearGroupMemberCache()
        refreshObservabilityRuntime()
    }

    func activateReadyState() async throws {
        phase = .ready
        try await configureObservabilityRuntime()
        await refreshNotificationAuthorizationStatus()
        await loadNotificationSettings()
        await loadPrivacySecuritySettings()
        await reloadChats()
        startNotificationListener()
    }

    func showLogin() {
        authenticationMode = .login
        clearEnteredLoginIdentity()
        lastError = nil
    }

    func cancelLogin() {
        authenticationMode = .landing
        clearEnteredLoginIdentity()
        lastError = nil
    }

    /// Scrubs the entered nsec (private key) from `loginIdentity` so it does not
    /// linger in observable memory longer than necessary. Used on login exit
    /// paths and when navigating away from the login / add-account UI. See #32.
    func clearEnteredLoginIdentity() {
        guard !loginIdentity.isEmpty else { return }
        loginIdentity = ""
    }

    func signUp() async {
        guard let client, !isAuthenticating else { return }
        lastError = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let summary = try await client.createIdentity(
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
            )
            try await refreshAccounts(preferred: summary)
            try await bringRuntimeOnline(client)
            try await refreshAccounts(preferred: summary)
            authenticationMode = .landing
            try await activateReadyState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func login() async {
        guard let client, !isAuthenticating else { return }
        let identity = loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { return }

        lastError = nil
        isAuthenticating = true
        // Scrub the entered nsec (private key) on every exit path so it never
        // outlives the login call, including failures. See issue #32.
        defer {
            isAuthenticating = false
            clearEnteredLoginIdentity()
        }

        do {
            let summary = try await client.login(
                identity: identity,
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
            )
            try await refreshAccounts(preferred: summary)
            try await bringRuntimeOnline(client)
            try await refreshAccounts(preferred: summary)
            authenticationMode = .landing
            try await activateReadyState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeActiveAccount() async {
        guard let activeAccount else { return }
        await removeAccount(activeAccount)
    }

    /// Removes a single identity (any account, not just the active one) from this Mac.
    /// Deletes the account's private key and local Marmot/MLS state via the runtime, then
    /// updates `accounts`/`chatsByAccount`. When the removed account is the active one, the
    /// in-memory message/profile caches are cleared and a remaining account is reselected
    /// (or the app returns to onboarding when none remain).
    func removeAccount(_ account: AccountItem) async {
        guard let client, !isRemovingAccount else { return }

        lastError = nil
        isRemovingAccount = true
        defer { isRemovingAccount = false }

        let removedAccountId = account.id
        let wasActive = activeAccountId == removedAccountId
        do {
            if wasActive {
                stopTimelineListener()
                stopChatListListener()
            }
            try await client.removeAccount(accountRef: account.accountRef)
            clearComposerDrafts(forAccountId: removedAccountId)
            accounts = try await accountItemsFromRuntime(client: client)
            chatsByAccount[removedAccountId] = nil

            // `activeAccountId` may have changed during the await above — e.g. the user
            // selected an account from settings while this removal was in flight. Decide
            // recovery from the post-await state, not the pre-await `wasActive` snapshot,
            // so we never leave `activeAccountId`/UserDefaults pointing at a removed
            // account. `needsActiveReset` is true if the removed account was driving the
            // UI, or if the (possibly newly-selected) active account no longer exists.
            let activeAccountInvalid =
                activeAccountId == nil
                || !accounts.contains(where: { $0.id == activeAccountId })
            let needsActiveReset = wasActive || activeAccountInvalid

            if needsActiveReset {
                stopTimelineListener()
                stopChatListListener()
                messagesByChat.removeAll()
                for store in messageTimelineStores.values {
                    store.clear()
                }
                messageTimelineStores.removeAll()
                messageLookupByChat.removeAll()
                messageIDsByChat.removeAll()
                mediaDownloads.removeAll()
                peerProfileFFICache.removeAll()
                clearGroupMemberCache()
                timelinePagingByChat.removeAll()
                profileDraft = ProfileDraft()
                keyPackages = []
                auditLogFiles = []
                auditLogUploadStatus = nil
            }

            if accounts.isEmpty {
                activeAccountId = nil
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
                selection = nil
                phase = .onboarding
                notificationSettings = .defaults
                privacySecuritySettings = .defaults
                return
            }

            // Reselecting and reloading is only required when the account currently
            // driving the UI was removed (directly, or via a racing selection of the
            // soon-to-be-removed account). Removing a background identity that leaves a
            // still-valid active account untouched needs no reselection.
            if needsActiveReset {
                restoreOrSelectFirstAccount()
                selection = .settings(.accounts)
                try await configureObservabilityRuntime()
                await loadSettingsData()
                await reloadChats()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAllData() async {
        guard let client, !isDeletingAllData else { return }

        isDeletingAllData = true
        lastError = nil
        defer { isDeletingAllData = false }

        do {
            stopNotificationListener()
            stopChatListListener()
            stopTimelineListener()

            // Marmot only owns its storage root; the decrypted-attachment playback scratch
            // directory lives outside it, so purge it before the potentially throwing
            // Marmot deletion call when wiping local data.
            try? await runOffMain { MediaPlaybackTempStore.purge() }
            try await client.deleteAllLocalData()
            self.client = nil
            observabilityRuntimeConfiguration = nil
            resetToNewInstallState(storageRootPath: client.storageRootPath)

            let runtime = try clientFactory()
            self.client = runtime
            storageRootPath = runtime.storageRootPath
            try await configureObservabilityRuntime()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The bech32 `npub` form of a hex public key — the canonical, user-facing way to show
    /// a Nostr public key. Falls back to the hex until the account cache has been hydrated
    /// off the main thread.
    func npub(forAccountIdHex accountIdHex: String) -> String {
        let trimmed = accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return accounts.first(where: { $0.accountIdHex == trimmed })?.npub ?? trimmed
    }

    func restoreOrSelectFirstAccount() {
        if let activeAccountId, accounts.contains(where: { $0.id == activeAccountId }) {
            return
        }
        activeAccountId = accounts.first?.id
        if let activeAccountId {
            UserDefaults.standard.set(activeAccountId, forKey: Self.activeAccountKey)
        }
    }

    func refreshAccounts(preferred summary: AccountSummaryFfi) async throws {
        guard let client else { return }
        let preferredItems = try await accountItems(from: [summary], client: client)
        let preferredAccount = preferredItems.first ?? Self.accountItem(from: summary, resolved: nil)
        var refreshed = try await accountItemsFromRuntime(client: client)
        if !refreshed.contains(where: { $0.id == preferredAccount.id }) {
            refreshed.append(preferredAccount)
        }

        accounts = refreshed
        activeAccountId = preferredAccount.id
        UserDefaults.standard.set(preferredAccount.id, forKey: Self.activeAccountKey)
        searchText = ""
        clearAllComposerDrafts()
        selection = nil
    }

    /// Brings the Marmot runtime online so newly added accounts start their
    /// workers and subscribe to transport events. `start()` is idempotent —
    /// it reconciles all known accounts (spawning a worker for any that lacks
    /// a live one) and rebuilds the user-directory subscriptions, and only
    /// fails when the runtime is shutting down. It must therefore be re-invoked
    /// after every `login()` / `signUp()`, not just once per launch: the
    /// Settings → Add Account flow adds a 2nd+ account while the runtime is
    /// already running, and that account stays offline (no live relay sync /
    /// notifications) until relaunch unless the runtime is brought online
    /// again. See issues #31 and #74.
    func bringRuntimeOnline(_ runtime: any MarmotRuntime) async throws {
        try await runtime.start()
    }

    func resetToNewInstallState(storageRootPath: String) {
        accounts = []
        chatsByAccount = [:]
        messagesByChat = [:]
        for store in messageTimelineStores.values {
            store.clear()
        }
        messageTimelineStores = [:]
        resetMediaDownloadStateStores()
        messageLookupByChat = [:]
        messageIDsByChat = [:]
        peerProfileFFICache.removeAll()
        clearGroupMemberCache()
        observabilityRuntimeConfiguration = nil
        activeAccountId = nil
        selection = nil
        searchText = ""
        isChatListVisible = true
        clearAllComposerDrafts()
        isRefreshing = false
        isSending = false
        authenticationMode = .landing
        loginIdentity = ""
        isAuthenticating = false
        profileDraft = ProfileDraft()
        relaySettings = .defaults
        selectedRelaySection = .nip65
        relayDraft = MarmotClient.seedRelays
        newRelayURL = ""
        keyPackages = []
        notificationSettings = .defaults
        notificationAuthorizationStatus = .notDetermined
        privacySecuritySettings = .defaults
        auditLogFiles = []
        auditLogUploadStatus = nil
        isLoadingSettings = false
        isSavingProfile = false
        isRemovingAccount = false
        isSavingRelays = false
        isPublishingKeyPackage = false
        isRepublishingKeyPackage = false
        isSavingNotifications = false
        isSavingPrivacySecurity = false
        isLoadingAuditLogFiles = false
        isDeletingAuditLogFiles = false
        isUploadingAuditLogFiles = false
        deletingKeyPackageId = nil
        isNewChatComposerVisible = false
        resetNewChatComposer()
        isResolvingNewChat = false
        isCreatingChat = false
        isGroupImagePickerPresented = false
        groupImageSearchQuery = ""
        groupImageResults = []
        invalidateGroupImageSearch()
        isSavingGroupImage = false
        isGroupDetailsPresented = false
        groupDetailsSnapshot = nil
        groupProfileDraftName = ""
        groupProfileDraftDescription = ""
        groupInviteMemberQuery = ""
        // Invalidate any in-flight load so a stale completion cannot write into the reset state;
        // this also clears `isLoadingGroupDetails`. See issue #135.
        invalidateGroupDetailsLoad()
        isSavingGroupProfile = false
        isInvitingGroupMember = false
        isAcceptingGroupInvite = false
        isDecliningGroupInvite = false
        isArchivingGroup = false
        isLeavingGroup = false
        isExportingGroupTranscript = false
        groupTranscriptExportStatus = nil
        mutatingGroupMemberId = nil
        self.storageRootPath = storageRootPath
        timelinePagingByChat = [:]
        timelineInitialLoadGroupId = nil
        lastMarkedReadMarkers = [:]
        lastConfirmedReadMarkers = [:]
        deliveredNotificationKeys = []
        deliveredNotificationKeyOrder = []
        UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
        phase = .onboarding
    }

    func accountItemsFromRuntime(client: any MarmotRuntime) async throws -> [AccountItem] {
        let summaries = try await runOffMain {
            try client.listAccounts()
        }
        return try await accountItems(from: summaries, client: client)
    }

    func accountItems(
        from summaries: [AccountSummaryFfi],
        client: any MarmotRuntime
    ) async throws -> [AccountItem] {
        try await runOffMain {
            summaries.map { summary in
                let resolved = Self.resolvedAccountFFI(from: summary, client: client)
                return Self.accountItem(from: summary, resolved: resolved)
            }
        }
    }

    nonisolated static func resolvedAccountFFI(
        from summary: AccountSummaryFfi,
        client: any MarmotRuntime
    ) -> ResolvedAccountFFI {
        let profile = try? client.userProfile(accountIdHex: summary.accountIdHex)
        return ResolvedAccountFFI(
            profileDisplayName: profile?.displayName,
            profileName: profile?.name,
            profilePicture: profile?.picture,
            directoryDisplayName: client.displayName(accountIdHex: summary.accountIdHex),
            npub: client.npub(accountIdHex: summary.accountIdHex)
        )
    }

    nonisolated static func accountItem(
        from summary: AccountSummaryFfi,
        resolved: ResolvedAccountFFI?
    ) -> AccountItem {
        let base = AccountItem(summary: summary)
        let displayName =
            firstNonBlank([
                resolved?.profileDisplayName,
                resolved?.profileName,
                resolved?.directoryDisplayName,
            ]) ?? base.displayName

        return AccountItem(
            id: base.id,
            accountRef: base.accountRef,
            displayName: displayName,
            accountIdHex: base.accountIdHex,
            npub: resolved?.npub,
            pictureURL: resolved?.profilePicture,
            localSigning: base.localSigning,
            isRunning: base.isRunning
        )
    }

    func updateActiveAccountProfile(displayName: String, pictureURL: String?) {
        guard let activeAccountId,
            let index = accounts.firstIndex(where: { $0.id == activeAccountId })
        else { return }

        let account = accounts[index]
        accounts[index] = AccountItem(
            id: account.id,
            accountRef: account.accountRef,
            displayName: displayName,
            accountIdHex: account.accountIdHex,
            npub: account.npub,
            pictureURL: pictureURL,
            localSigning: account.localSigning,
            isRunning: account.isRunning
        )
    }
}
