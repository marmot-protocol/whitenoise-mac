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
        // Wipe any decrypted/plaintext media scratch left by a prior session before the
        // UI can surface new media or prepare outgoing attachments.
        try? await runOffMain {
            MediaPlaybackTempStore.purge()
            OutgoingMediaMetadataTempStore.purge()
        }
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
            await refreshAccountProfiles()
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func selectAccount(_ account: AccountItem) {
        guard !account.signedOut else { return }
        switchActiveAccount(
            account,
            finalSelection: chatsByAccount[account.id]?.first.map { WorkspaceSelection.chat($0.id) }
        )
    }

    func selectAccountFromSettings(_ account: AccountItem) {
        guard !account.signedOut else { return }
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
        leaveActiveConversation()
        stopTimelineListener()
        cancelTimelineLoad()
        cancelChatListReload()
        stopChatListListener()
        closeGroupDetails()
        clearSharedMedia()
        clearEnteredLoginIdentity()
        activeAccountId = account.id
        invalidateNotificationSettingsOperations()
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        searchText = ""
        chatListFilter = .active
        archivingChatId = nil
        closeNewChatComposer()
        resetComposeContacts()
        pruneMessageCache(keeping: groupIdHex)
        clearConversationMetadata()
        clearMediaReferenceResolutionCache()
        // Lookup caches are scoped to the active account's view (directory display names and
        // group membership visibility can differ per account); drop them on switch so the new
        // account does not inherit stale cross-account entries (whitenoise-mac#8/#9).
        peerProfileFFICache.removeAll()
        clearGroupMemberCache()
        // Read markers are keyed by groupIdHex only; stale entries from the
        // previous account suppress the first legitimate advance for a shared
        // group id under the new identity. See #429.
        lastMarkedReadMarkers.removeAll()
        lastConfirmedReadMarkers.removeAll()
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
        flushPendingDeepLinkIfReady()
    }

    func showLogin() {
        authenticationMode = .login
        clearEnteredLoginIdentity()
        lastError = nil
    }

    func showAccountOnboarding() {
        authenticationMode = .landing
        clearEnteredLoginIdentity()
        lastError = nil
        phase = .onboarding
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
            // `refreshAccounts(preferred:)` commits activeAccountId/UserDefaults
            // and clears selection; wait until start succeeds so a failure keeps
            // the previous ready account intact (#333).
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
            // `refreshAccounts(preferred:)` commits activeAccountId/UserDefaults
            // and clears selection; wait until start succeeds so a failure keeps
            // the previous ready account intact (#333).
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

    /// Reveal the active account's raw private key as an `nsec1…` bech32 string for
    /// in-app backup. SENSITIVE: the core logs this and downgrades the audit data
    /// mode. Returns `nil` (and sets `lastError`) on failure.
    func revealActiveAccountNsec() async -> String? {
        guard let client, let activeAccount else { return nil }
        let accountRef = activeAccount.accountRef
        lastError = nil
        do {
            return try await runOffMain { try client.revealNsec(accountRef: accountRef) }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Export the active account's private key as a passphrase-encrypted NIP-49
    /// `ncryptsec1…` string. Returns `nil` (and sets `lastError`) on failure.
    func exportActiveAccountEncryptedKey(passphrase: String) async -> String? {
        guard let client, let activeAccount else { return nil }
        let accountRef = activeAccount.accountRef
        lastError = nil
        do {
            return try await runOffMain {
                try client.exportEncryptedSecretKey(accountRef: accountRef, passphrase: passphrase)
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Removes a single identity (any account, not just the active one) from this Mac.
    /// Deletes the account's private key and local Marmot/MLS state via the runtime, then
    /// updates `accounts`/`chatsByAccount`. When the removed account is the active one, the
    /// in-memory message/profile caches are cleared and a remaining account is reselected
    /// (or the app returns to onboarding when none remain).
    func removeAccount(_ account: AccountItem) async {
        guard let client, !isAccountMutationInProgress else { return }

        lastError = nil
        isRemovingAccount = true
        defer { isRemovingAccount = false }

        let removedAccountId = account.id
        let removedAccountIdHex = account.accountIdHex
        let wasActive = activeAccountId == removedAccountId
        suppressMediaDiskStores(forAccountId: removedAccountId)
        defer { resumeMediaDiskStores(forAccountId: removedAccountId) }
        do {
            if wasActive {
                stopTimelineListener()
                cancelTimelineLoad()
                cancelChatListReload()
                stopChatListListener()
            }
            try await client.removeAccount(accountRef: account.accountRef)
            clearComposerDrafts(forAccountId: removedAccountId)
            purgeHiddenMessages(accountId: removedAccountId)
            await mediaDiskCache.purgeAccount(removedAccountId)
            clearMediaReferenceResolutionCache(forAccountId: removedAccountId)
            accounts = try await accountItemsFromRuntime(client: client)
            removeChats(forAccountId: removedAccountId)
            accountUnreadByIdHex[removedAccountIdHex] = nil

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
                resetActiveAccountUIState()
            } else {
                // Decoded peer/group avatars derive from account contacts' attacker-controlled
                // `picture` URLs. The decoded-image cache is process-lifetime and global rather than
                // account-partitioned, so evict it after every successful background-account removal.
                // Active-account removal clears it through `resetActiveAccountUIState()`. See #177.
                RemoteImageLoader.shared.clearCache()
            }

            if accounts.isEmpty {
                activeAccountId = nil
                invalidateNotificationSettingsOperations()
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

    /// Clears all active-account-scoped in-memory UI state (conversation resources,
    /// timelines, caches, drafts, settings snapshots). Shared by account removal and sign-out.
    func resetActiveAccountUIState() {
        leaveActiveConversation()
        stopTimelineListener()
        cancelTimelineLoad()
        cancelChatListReload()
        stopChatListListener()
        clearSharedMedia()
        cachedMessageChatIds.removeAll()
        for store in messageTimelineStores.values {
            store.clear()
        }
        messageTimelineStores.removeAll()
        mediaDownloads.removeAll()
        clearMediaReferenceResolutionCache()
        peerProfileFFICache.removeAll()
        clearGroupMemberCache()
        // Active-account teardown must evict decoded peer/group avatars held in the
        // process-lifetime image cache; profile metadata alone is not enough. See #177/#288.
        RemoteImageLoader.shared.clearCache()
        timelinePagingByChat.removeAll()
        clearConversationMetadata()
        accountUnreadByIdHex.removeAll()
        // Read markers are keyed by groupIdHex; leaving them behind both retains a
        // record of which messages the signed-out identity read and lets a recurring
        // group id suppress the first legitimate read-mark advance after re-login. The
        // delivered-notification keys are likewise account-scoped residue. See #241.
        lastMarkedReadMarkers.removeAll()
        lastConfirmedReadMarkers.removeAll()
        deliveredNotificationKeys.removeAll()
        deliveredNotificationKeyOrder.removeAll()
        resetAccountScopedGroupAndNewChatUIState()
        profileDraft = ProfileDraft()
        keyPackages = []
        auditLogFiles = []
        auditLogUploadStatus = nil
    }

    private func resetAccountScopedGroupAndNewChatUIState() {
        isNewChatComposerVisible = false
        resetNewChatComposer()
        resetComposeContacts()
        isResolvingNewChat = false
        isCreatingChat = false

        isGroupImagePickerPresented = false
        groupImageSearchQuery = ""
        groupImageResults = []
        invalidateGroupImageSearch()

        closeGroupDetails()
        groupTranscriptExportTask = nil
    }

    /// Non-destructive sign-out: retains the account's local data but deactivates
    /// it (and cleans up its relay key packages). If it was the active account, the
    /// UI switches to another signed-in account, or onboarding when none remain.
    func signOutAccount(_ account: AccountItem) async {
        guard let client, !isAccountMutationInProgress else { return }
        lastError = nil
        isSigningOutAccount = true
        defer { isSigningOutAccount = false }

        let wasActive = activeAccountId == account.id
        do {
            if wasActive {
                stopTimelineListener()
                cancelTimelineLoad()
                cancelChatListReload()
                stopChatListListener()
            }
            _ = try await client.signOut(accountRef: account.accountRef, deleteKeyPackages: true)
            clearComposerDrafts(forAccountId: account.id)
            clearMediaReferenceResolutionCache(forAccountId: account.id)
            accounts = try await accountItemsFromRuntime(client: client)
            removeChats(forAccountId: account.id)
            await refreshAccountUnreadSummary()

            // `activeAccountId` may have changed during the awaits above — e.g. the user
            // selected another account while this sign-out was in flight (account switching
            // is not gated by `isSigningOutAccount`). Decide recovery from post-await state,
            // not the pre-await `wasActive` snapshot: if a still-signed-in account is active
            // (an untouched background account, or the one the user just raced to), leave its
            // freshly loaded session intact rather than tearing it down and reselecting.
            let currentActiveAccount = activeAccountId.flatMap { id in
                accounts.first { $0.id == id && !$0.signedOut }
            }
            guard currentActiveAccount == nil else { return }

            resetActiveAccountUIState()
            if let nextActive = accounts.first(where: { !$0.signedOut }) {
                switchActiveAccount(nextActive, finalSelection: .settings(.accounts))
                try await configureObservabilityRuntime()
                await loadSettingsData()
            } else {
                activeAccountId = nil
                invalidateNotificationSettingsOperations()
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
                selection = nil
                phase = .ready
                notificationSettings = .defaults
                privacySecuritySettings = .defaults
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-activate a previously signed-out account and make it the active one.
    func signInAccount(_ account: AccountItem) async {
        guard let client, !isAccountMutationInProgress else { return }
        lastError = nil
        isSigningOutAccount = true
        defer { isSigningOutAccount = false }

        let preAwaitActiveAccountId = activeAccountId
        do {
            _ = try await client.signInAccount(accountRef: account.accountRef)
            accounts = try await accountItemsFromRuntime(client: client)
            if let refreshed = accounts.first(where: { $0.id == account.id }) {
                let currentActiveAccount = activeAccountId.flatMap { id in
                    accounts.first { $0.id == id && !$0.signedOut }
                }
                // `activeAccountId` may have changed during the awaits above — e.g. the user
                // selected another account while this sign-in was in flight (account switching
                // is not gated by `isSigningOutAccount`). Only activate the just-signed-in
                // account when no other valid signed-in account was raced to mid-flight.
                let userRacedToDifferentAccount =
                    currentActiveAccount != nil
                    && activeAccountId != preAwaitActiveAccountId
                    && currentActiveAccount?.id != account.id
                if !userRacedToDifferentAccount {
                    switchActiveAccount(refreshed, finalSelection: .settings(.accounts))
                    try await configureObservabilityRuntime()
                    await loadSettingsData()
                }
            }
            await refreshAccountUnreadSummary()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Refresh per-account unread totals without loading each account's full session.
    func refreshAccountUnreadSummary() async {
        guard let client else { return }
        do {
            let rows = try await runOffMain { try client.accountUnreadSummary() }
            accountUnreadByIdHex = Dictionary(
                rows.map { ($0.accountIdHex, Int(clamping: $0.unreadCount)) },
                uniquingKeysWith: { lhs, _ in lhs }
            )
        } catch {
            // Unread badges are best-effort; leave the prior values on failure.
        }
    }

    /// Aggregate unread count for an account's avatar badge in the switcher.
    func unreadCount(forAccountIdHex accountIdHex: String) -> Int {
        accountUnreadByIdHex[accountIdHex] ?? 0
    }

    func deleteAllData() async {
        guard let client, !isAccountMutationInProgress else { return }

        isDeletingAllData = true
        lastError = nil
        suppressAllMediaDiskStores()
        defer { resumeAllMediaDiskStores() }
        defer { isDeletingAllData = false }

        let selectedGroupId = selectedChat?.id

        do {
            // Stop any in-progress voice recording before the wipe so the mic is not left hot
            // (and no plaintext audio keeps being written) while local data is deleted (#311).
            leaveActiveConversation()
            stopNotificationListener()
            cancelChatListReload()
            stopChatListListener()
            stopTimelineListener()

            // Marmot only owns its storage root; plaintext media scratch directories live
            // outside it, so purge those before the potentially throwing Marmot deletion.
            // The encrypted media cache stays until the delete succeeds — on a failed wipe the
            // recovered session must keep its cached media intact and decryptable.
            try? await runOffMain {
                MediaPlaybackTempStore.purge()
                OutgoingMediaMetadataTempStore.purge()
            }
            try await client.deleteAllLocalData()
            await mediaDiskCache.purgeAll()
            await mediaDiskCache.purgeAll(removeEncryptionKey: true)
            self.client = nil
            observabilityRuntimeConfiguration = nil
            resetToNewInstallState(storageRootPath: client.storageRootPath)

            let runtime = try clientFactory()
            self.client = runtime
            storageRootPath = runtime.storageRootPath
            try await configureObservabilityRuntime()
        } catch {
            let errorMessage = error.localizedDescription
            await recoverReadySessionAfterFailedDeleteAllData(selectedGroupId: selectedGroupId)
            lastError = errorMessage
        }
    }

    func recoverReadySessionAfterFailedDeleteAllData(selectedGroupId: String?) async {
        guard client != nil, activeAccount != nil, case .ready = phase else { return }

        startNotificationListener()
        await reloadChats(forceFreshSnapshot: true)
        if let selectedGroupId, selectedChat?.id == selectedGroupId {
            await loadMessages(groupIdHex: selectedGroupId)
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
        if let activeAccountId,
            accounts.contains(where: { $0.id == activeAccountId && !$0.signedOut })
        {
            return
        }
        activeAccountId = accounts.first(where: { !$0.signedOut })?.id
        invalidateNotificationSettingsOperations()
        if let activeAccountId {
            UserDefaults.standard.set(activeAccountId, forKey: Self.activeAccountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
        }
    }

    /// Refresh public profile metadata after the local account snapshot is usable.
    /// This keeps launch fast while replacing stale fallback identifiers as soon as
    /// relay-backed profile data arrives.
    func refreshAccountProfiles() async {
        guard let client, !isRefreshingAccountProfiles, !accounts.isEmpty else { return }
        isRefreshingAccountProfiles = true
        defer { isRefreshingAccountProfiles = false }

        let accountIds = accounts.map(\.accountIdHex)
        for accountIdHex in accountIds {
            try? await client.refreshProfile(
                accountIdHex: accountIdHex,
                relays: MarmotClient.seedRelays
            )
        }

        guard let refreshed = try? await accountItemsFromRuntime(client: client) else { return }
        accounts = refreshed
        restoreOrSelectFirstAccount()
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
        resetComposeContacts()
        activeAccountId = preferredAccount.id
        invalidateNotificationSettingsOperations()
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
        leaveActiveConversation()
        accounts = []
        resetChats()
        cachedMessageChatIds = []
        for store in messageTimelineStores.values {
            store.clear()
        }
        messageTimelineStores = [:]
        resetMediaDownloadStateStores()
        peerProfileFFICache.removeAll()
        clearGroupMemberCache()
        clearConversationMetadata()
        clearSharedMedia()
        accountUnreadByIdHex.removeAll()
        // "Delete All Local Data" must also evict decoded peer/group avatars held in the
        // process-lifetime decoded-image cache; those images derive from attacker-controlled
        // peer `picture` URLs and would otherwise survive the wipe in memory. See #177.
        RemoteImageLoader.shared.clearCache()
        observabilityRuntimeConfiguration = nil
        activeAccountId = nil
        invalidateNotificationSettingsOperations()
        selection = nil
        searchText = ""
        isChatListVisible = true
        clearAllComposerDrafts()
        clearAllHiddenMessages()
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
        shouldReloadAuditLogFilesAfterCurrentLoad = false
        isDeletingAuditLogFiles = false
        isUploadingAuditLogFiles = false
        deletingKeyPackageId = nil
        resetAccountScopedGroupAndNewChatUIState()
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
            externalSigning: base.externalSigning,
            isRunning: base.isRunning,
            signedOut: base.signedOut
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
            externalSigning: account.externalSigning,
            isRunning: account.isRunning,
            signedOut: account.signedOut
        )
    }
}
