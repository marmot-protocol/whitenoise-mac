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
import UniformTypeIdentifiers
import UserNotifications

@MainActor
extension WorkspaceState {
    func bootstrap() async {
        guard client == nil, case .bootstrapping = phase else { return }
        let splashStartedAt = DispatchTime.now().uptimeNanoseconds
        var performanceRuntime: (any MarmotRuntime)?
        lastError = nil
        // Wipe any decrypted/plaintext media scratch left by a prior session before the
        // UI can surface new media or prepare outgoing attachments.
        try? await FFIExecutor.run {
            MediaPlaybackTempStore.purge()
            OutgoingMediaMetadataTempStore.purge()
        }
        do {
            let runtime = try clientFactory()
            performanceRuntime = runtime
            client = runtime
            storageRootPath = runtime.storageRootPath
            if hiddenMessageStore == nil {
                hiddenMessageStore = HiddenMessageFileStore(storageRootPath: storageRootPath)
            }
            if pinnedChatStore == nil {
                pinnedChatStore = PinnedChatFileStore(storageRootPath: storageRootPath)
            }
            if contactNicknameStore == nil {
                contactNicknameStore = ContactNicknameFileStore(storageRootPath: storageRootPath)
            }
            if directPeerMemoryStore == nil {
                directPeerMemoryStore = DirectPeerMemoryFileStore(storageRootPath: storageRootPath)
            }
            loadHiddenMessages()
            loadPinnedChats()
            loadContactNicknames()
            loadRememberedDirectPeers()
            let summaries = try await FFIExecutor.run {
                try runtime.listAccounts()
            }
            accounts = try await accountItems(from: summaries, client: runtime)
            restoreOrSelectFirstAccount()
            await configureObservabilityRuntimeBestEffort()
            // Not `accounts.isEmpty`: a Mac holding nothing but deactivated identities has
            // nothing to show either. It used to bring the runtime online, land in `.ready` with
            // no active account, and offer the stored identities as a list where one click
            // reactivated one without a key. Getting in is Sign In or Sign Up, and the core
            // reactivates a matching signed-out account on login, so that identity's chats come
            // back through the real flow rather than around it.
            if signedInAccounts.isEmpty {
                authenticationMode = .landing
                phase = .onboarding
                runtime.recordHostPerformance(
                    operation: .splashReady,
                    durationMs: Self.elapsedMilliseconds(since: splashStartedAt),
                    outcome: .success
                )
                return
            }

            try await bringRuntimeOnline(runtime)
            accounts = try await accountItemsFromRuntime(client: runtime)
            restoreOrSelectFirstAccount()
            await activateReadyState()
            runtime.recordHostPerformance(
                operation: .splashReady,
                durationMs: Self.elapsedMilliseconds(since: splashStartedAt),
                outcome: .success
            )
            await refreshAccountProfiles()
        } catch {
            performanceRuntime?.recordHostPerformance(
                operation: .splashReady,
                durationMs: Self.elapsedMilliseconds(since: splashStartedAt),
                outcome: .failure
            )
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func selectAccount(_ account: AccountItem) {
        guard !account.signedOut else { return }
        guard account.id != activeAccountId else {
            reselectActiveAccount()
            return
        }
        switchActiveAccount(account, finalSelection: chatSelection(forSwitchTo: account))
    }

    /// Where the rail lands when the identity changes. The remembered conversation is looked up for
    /// the account being switched *to*, so each identity returns to its own last chat instead of
    /// inheriting whatever the outgoing account happened to have open.
    ///
    /// An account that remembers a conversation its cached rows cannot resolve yet lands on nothing:
    /// selecting a substitute would immediately overwrite the memory through `selection`'s `didSet`,
    /// so the decision is deferred to `selectInitialChatIfNeeded()` once the fresh snapshot arrives.
    private func chatSelection(forSwitchTo account: AccountItem) -> WorkspaceSelection? {
        if let remembered = rememberedChat(forAccount: account) {
            return .chat(remembered.id)
        }
        guard !hasRememberedChat(forAccount: account) else { return nil }
        return chatsByAccount[account.id]?.first.map { WorkspaceSelection.chat($0.id) }
    }

    /// Handles a rail tap on the avatar that is *already* active. Running the real switch here
    /// would drop every cached timeline (`pruneMessageCache(keeping: nil)`), stop the chat-list
    /// listener, reset the filter/search, and re-subscribe through `reloadChats()` — so the open
    /// conversation blanks and every row re-enriches, reading as a full window reload for a tap
    /// that changes nothing.
    ///
    /// Doing literally nothing is not enough, though: this avatar is also the only way back to the
    /// chats from Settings. So a same-account tap still leaves a non-chat surface, it just gets
    /// there through the ordinary chat-selection path rather than an account switch.
    private func reselectActiveAccount() {
        // The composer covers the chat list, so a rail tap still dismisses it.
        if isNewChatComposerVisible {
            closeNewChatComposer()
        }
        // Already looking at a conversation: leave every cache, listener, and selection alone.
        guard isShowingSettings || selection == nil else { return }
        // The avatar is also the way back from Settings, which is where a settings-anchored account
        // switch leaves the user — so this is the moment that switch's chat decision finally gets
        // made, and it has to honor the same per-account memory the rail does. It asks without
        // forgetting: a tap can land while the account's rows are still the stale cache, which is no
        // basis for deciding a memory is dead.
        let outcome = rememberedChatOutcomeForActiveAccount()
        guard let chat = outcome.chat ?? mostRecentChat(in: activeChats) else {
            if isShowingSettings {
                selection = nil
            }
            return
        }
        withRememberedChatPreserved(outcome.preservesMemory) { selectChat(chat) }
    }

    /// Switch identity from a control anchored inside Settings, landing on the settings page the
    /// user is already reading rather than on a conversation.
    ///
    /// Currently reached from no view: the switcher popover that called it is gone, and the
    /// account rail uses `selectAccount(_:)`, which lands on a chat. Kept because the *landing*
    /// rule it encodes is the one any future in-Settings switch wants, and because it is what
    /// `settingsSelectionAfterAccountMutation` is exercised through.
    func selectAccountFromSettings(_ account: AccountItem) {
        guard !account.signedOut else { return }
        // The row for the already-active account is a no-op: a switch anchored to the settings
        // page the user is already reading would tear the session down and rebuild it only to
        // land back on the same screen.
        guard account.id != activeAccountId else { return }
        switchActiveAccount(account, finalSelection: settingsSelectionAfterAccountMutation)
    }

    /// Where to land after an account mutation hands the app a different active identity.
    ///
    /// Identity work lives at the top of Settings rather than on an Accounts page of its own, so
    /// these paths stay in Settings: on the page the user was already reading (it is simply
    /// re-answered for the new identity — `SettingsPanelView` reloads off `activeAccountId`), or
    /// on the profile overview when the mutation came from the account rail instead.
    var settingsSelectionAfterAccountMutation: WorkspaceSelection {
        if case .settings(let page) = selection {
            return .settings(page)
        }
        return .settings(.overview)
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
        dismissGlobalMessageSearch()
        invalidateSidebarMessageSearch(clearQuery: true)
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
        invalidatePrivacySecurityOperations()
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        chatListFilter = .active
        archivingChatId = nil
        // Destructive-action dialogs name a group id, which is only meaningful for the account that
        // opened them; a confirmation surviving the switch would act on the wrong account's chat.
        clearPendingChatDestructiveActions()
        // Settings → Profile is showing account A's name in an open editor and a seal earned by
        // account A's address. Neither survives the switch: B's settings load writes the new draft,
        // and an edit session left open over it would let A's baseline be restored onto B.
        resetProfileEditingState()
        closeNewChatComposer()
        resetComposeContacts()
        clearFollows()
        pruneMessageCache(keeping: groupIdHex)
        clearConversationMetadata()
        clearMediaReferenceResolutionCache()
        // Lookup caches are scoped to the active account's view (directory display names and
        // group membership visibility can differ per account); drop them on switch so the new
        // account does not inherit stale cross-account entries (whitenoise-mac#8/#9).
        peerProfileFFICache.removeAll()
        clearPeerProfileRefreshState()
        clearGroupMemberCache()
        groupImagePayloadCache.removeAll()
        // Read markers are keyed by groupIdHex only; stale entries from the
        // previous account suppress the first legitimate advance for a shared
        // group id under the new identity. See #429.
        lastMarkedReadMarkers.removeAll()
        lastConfirmedReadMarkers.removeAll()
        refreshObservabilityRuntime()
    }

    func activateReadyState() async {
        await configureObservabilityRuntimeBestEffort()
        phase = .ready
        await refreshNotificationAuthorizationStatus()
        await loadNotificationSettings()
        await loadPrivacySecuritySettings()
        await reloadChats()
        startNotificationListener()
        flushPendingDeepLinkIfReady()
        Task { [weak self] in
            await self?.sweepExpiredRetentionBestEffort()
        }
    }

    private static func elapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }

    func recordForegroundLocalReady(since startedAt: UInt64) {
        guard case .ready = phase, let client else { return }
        client.recordHostPerformance(
            operation: .foregroundLocalReady,
            durationMs: Self.elapsedMilliseconds(since: startedAt),
            outcome: .success
        )
    }

    /// Runs MDK's account-wide, fail-closed retention policy without delaying local-ready UI.
    func sweepExpiredRetentionBestEffort() async {
        guard let client, let activeAccount else { return }
        let accountId = activeAccount.id
        let nowMs = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        guard
            let report = try? await client.sweepExpiredRetention(
                accountRef: activeAccount.accountRef,
                nowMs: nowMs
            ), activeAccountId == accountId
        else { return }

        let pruned = report.groups.filter { $0.status == .pruned && $0.prunedMessages > 0 }
        guard !pruned.isEmpty else { return }

        let prunedGroupIds = Set(pruned.map(\.groupIdHex))
        for groupIdHex in prunedGroupIds {
            clearMediaReferenceResolutionCache(forAccountId: accountId, groupIdHex: groupIdHex)
            messageTimelineStores[groupIdHex]?.clear()
        }

        // The host cache is keyed by attachment references rather than MDK's returned
        // ciphertext hashes, so purge this account when any swept message owned media.
        if pruned.contains(where: { !$0.mediaCiphertextSha256.isEmpty }) {
            resetMediaDownloadStateStores()
            await mediaDiskCache.purgeAccount(accountId)
            await refreshMediaCacheFootprint()
        }

        await reloadChats(forceFreshSnapshot: true)
        if let selectedChat, prunedGroupIds.contains(selectedChat.id) {
            await loadMessages(groupIdHex: selectedChat.id)
        }
    }

    func showLogin() {
        authenticationMode = .login
        clearEnteredLoginIdentity()
        lastError = nil
    }

    /// Open the onboarding surface to add an identity alongside the ones already on this Mac.
    ///
    /// This is the whole of Settings' `Add Profile` row — the last caller left. Adding an
    /// identity once had two competing answers: a bespoke Settings sheet with its own key field
    /// and its own pair of buttons, and a `Use another account` button on the pane that stood in
    /// for the app when nothing was signed in. The sheet's was a second, worse copy of a flow
    /// that already exists, and that pane is gone — with nothing signed in the app opens this
    /// flow itself rather than listing the deactivated identities on this Mac. What is left is
    /// the panes in `Views/Onboarding`, which is what `wn-ios-prototype`'s `AddProfileFlow` does
    /// too: it presents `WelcomeView` and pushes the *real* `LoginView` and `SignUpView` rather
    /// than reimplementing either.
    ///
    /// The Settings caller is `SettingsAccountSwitcherCard`'s second row, unconditionally. That
    /// row used to read `Add Account` with one identity on this Mac and `Switch Account` with
    /// more, the latter opening a popover instead of calling this — so the same row meant two
    /// different things depending on state the user had not thought about.
    ///
    /// Deliberately leaves `selection` alone, so `leaveAccountOnboarding()` puts the user back on
    /// the page they opened this from rather than somewhere merely plausible.
    func showAccountOnboarding() {
        authenticationMode = .landing
        clearEnteredLoginIdentity()
        lastError = nil
        phase = .onboarding
    }

    /// Whether the onboarding surface has an app behind it to return to.
    ///
    /// Derived rather than stored, because a flag saying the same thing could fall out of step
    /// with the phase it describes. Every *other* route into `.onboarding` is taken precisely
    /// because there is nothing else to show — a first launch, the last account signed out or
    /// removed, a wipe — and each one leaves `signedInAccounts` empty. So a signed-in identity
    /// in this phase means someone chose to be here and is owed a way out.
    ///
    /// Reads `signedInAccounts`, not `accounts`: the deactivated identities on this Mac stay in
    /// the latter, and counting them here would draw a `Cancel` whose `.ready` destination has no
    /// account to render — the pane the user just came from because nothing was signed in.
    var canLeaveAccountOnboarding: Bool {
        phase == .onboarding && !signedInAccounts.isEmpty
    }

    /// Leave the onboarding surface without adding anything — the prototype's `Cancel`.
    ///
    /// Restores the phase and nothing else: no account changed hands, so there is no state to
    /// rebuild and `activateReadyState()`'s reloads would be work done for a user who pressed
    /// cancel. What it does scrub is the key field, because Cancel is one of the exits #32 is
    /// about: a typed-but-unsubmitted nsec must not outlive the pane it was typed into.
    func leaveAccountOnboarding() {
        guard canLeaveAccountOnboarding, !isAuthenticating else { return }
        authenticationMode = .landing
        clearEnteredLoginIdentity()
        lastError = nil
        phase = .ready
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
        guard !isAuthenticating else { return }
        lastError = nil
        authenticationActivity = .signUp
        defer { authenticationActivity = nil }

        guard let client = await clientForAuthentication() else { return }

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
            // Read before `activateReadyState()`: it goes `.ready` part-way through, after which a
            // switch from Settings can land on a different identity. See
            // `presentImprovementsPromptIfNeeded(forEnteredAccountIdHex:)`.
            let enteredAccountIdHex = activeAccount?.accountIdHex
            await activateReadyState()
            presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: enteredAccountIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func login() async {
        guard !isAuthenticating else { return }
        let identity = loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { return }

        lastError = nil
        authenticationActivity = .login
        // Scrub the entered nsec (private key) on every exit path so it never
        // outlives the login call, including failures. See issue #32.
        defer {
            authenticationActivity = nil
            clearEnteredLoginIdentity()
        }

        guard let client = await clientForAuthentication() else { return }

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
            // Read before `activateReadyState()`: it goes `.ready` part-way through, after which a
            // switch from Settings can land on a different identity. See
            // `presentImprovementsPromptIfNeeded(forEnteredAccountIdHex:)`.
            let enteredAccountIdHex = activeAccount?.accountIdHex
            await activateReadyState()
            presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: enteredAccountIdHex)
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
            return try await FFIExecutor.run { try client.revealNsec(accountRef: accountRef) }
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
            return try await FFIExecutor.run {
                try client.exportEncryptedSecretKey(accountRef: accountRef, passphrase: passphrase)
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Write the active account's private key to a file the reader picks.
    ///
    /// The destination is asked for *before* the key is fetched, and that order is the point:
    /// `revealNsec` is an audited call that downgrades the core's audit data mode for this
    /// account, so a save panel the reader cancels must not have cost them that. Nothing is
    /// fetched, and nothing is logged, until there is somewhere to put it.
    ///
    /// `passphrase` is required for `.encrypted` and ignored for `.raw`. Returns true when a file
    /// was written; false when the reader cancelled, when the account has no local key, or when
    /// the write failed — `lastError` carries the reason in the last case.
    @discardableResult
    func exportActiveAccountPrivateKey(
        _ kind: PrivateKeyExportKind,
        passphrase: String = ""
    ) async -> Bool {
        guard !isExportingPrivateKey, let exportingAccount = activeAccount, exportingAccount.localSigning else {
            return false
        }
        // `lastError` is shared app-wide state, and the export sheet reads it to decide both what
        // to draw and whether it may close. A failed profile save or relay write from minutes ago
        // would otherwise render under the password fields as though this export had produced it,
        // and would stop a successful export from ever dismissing the sheet.
        lastError = nil
        let suggestedFilename = L10n.string(kind.suggestedFilenameKey)
        guard let destinationURL = privateKeyExportDestinationPicker(suggestedFilename, kind.contentType) else {
            return false
        }
        // The identity is pinned across the panel. `NSSavePanel.runModal()` spins a nested run
        // loop, which drains the main queue, so main-actor work queued before the panel opened can
        // resume while it is up — and the key material below is fetched from `activeAccount`, not
        // from whatever was active when the reader asked. Bailing here costs nothing: the panel is
        // answered but nothing has been fetched, so no audited call has happened yet.
        guard activeAccount?.id == exportingAccount.id else { return false }

        isExportingPrivateKey = true
        defer { isExportingPrivateKey = false }

        let keyMaterial: String?
        switch kind {
        case .encrypted:
            keyMaterial = await exportActiveAccountEncryptedKey(passphrase: passphrase)
        case .raw:
            keyMaterial = await revealActiveAccountNsec()
        }
        // Both helpers already set `lastError` on failure, so a nil here is reported.
        guard let keyMaterial else { return false }
        // Checked again after the fetch, because the helpers read `activeAccount` themselves and
        // an `await` is a suspension point. This is the check that keeps the *file* honest: one
        // account's key must never land in a file the reader asked for while another was active.
        guard activeAccount?.id == exportingAccount.id else { return false }

        do {
            // `.atomic` so a failed write cannot leave a truncated key behind under a name that
            // claims to be a backup, and `.completeFileProtection` so the file is not readable
            // while the volume is locked. The sandbox grants write access to exactly the URL the
            // panel returned — see `App Sandbox` in the entitlements.
            try kind.fileContents(forKeyMaterial: keyMaterial).write(
                to: destinationURL,
                options: [.atomic, .completeFileProtection]
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// The production save panel for a private-key export.
    ///
    /// A panel rather than a fixed location because the sandbox has no other way to grant a write
    /// outside the container: this app holds `files.user-selected.read-write` and nothing wider, so
    /// a path assembled in code fails even when it resolves (see the container-symlink case).
    static func choosePrivateKeyExportDestination(
        suggestedFilename: String,
        contentType: UTType
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export Private Key")
        panel.prompt = L10n.string("Export")
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [contentType]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
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
        let selectedGroupId = wasActive ? selectedChat?.id : nil
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
            removeChatRestorationTarget(forOwnerAccountIdHex: removedAccountIdHex)
            forgetImprovementsPrompt(forOwnerAccountIdHex: removedAccountIdHex)
            clearComposerDrafts(forAccountId: removedAccountId)
            purgeHiddenMessages(accountId: removedAccountId)
            purgePinnedChats(accountId: removedAccountId)
            purgeContactNicknames(ownerAccountIdHex: removedAccountIdHex)
            purgeRememberedDirectPeers(accountId: removedAccountId)
            await mediaDiskCache.purgeAccount(removedAccountId)
            clearMediaReferenceResolutionCache(forAccountId: removedAccountId)
            accounts = try await accountItemsFromRuntime(client: client)
            removeChats(forAccountId: removedAccountId)
            accountUnreadByIdHex[removedAccountIdHex] = nil
            pendingInviteCountByIdHex[removedAccountIdHex] = nil

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

            // Deliberately `signedInAccounts`, not `accounts`: removing the last signed-in
            // identity while a deactivated one remains on this Mac leaves nothing to render, and
            // the fall-through below would reselect nothing and stay in `.ready`.
            if signedInAccounts.isEmpty {
                activeAccountId = nil
                invalidateNotificationSettingsOperations()
                invalidatePrivacySecurityOperations()
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
                selection = nil
                authenticationMode = .landing
                clearEnteredLoginIdentity()
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
                selection = settingsSelectionAfterAccountMutation
                await configureObservabilityRuntimeBestEffort()
                await loadSettingsData()
                await reloadChats()
            }
        } catch {
            if wasActive, activeAccountId == removedAccountId {
                await restoreReadySessionAfterInterruptedMutation(selectedGroupId: selectedGroupId)
            }
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
        clearPeerProfileRefreshState()
        clearGroupMemberCache()
        groupImagePayloadCache.removeAll()
        // Active-account teardown must evict decoded peer/group avatars held in the
        // process-lifetime image cache; profile metadata alone is not enough. See #177/#288.
        RemoteImageLoader.shared.clearCache()
        timelinePagingByChat.removeAll()
        clearConversationMetadata()
        accountUnreadByIdHex.removeAll()
        // The recorded signal describes counts that no longer exist; keeping it could suppress
        // the refresh that repopulates the badges after the next account takes over. Bumping the
        // generation also drops any answer still in flight, which would otherwise repopulate the
        // badges the teardown just cleared.
        lastSummarizedAccountUnread = nil
        accountUnreadSummaryGeneration &+= 1
        // The other half of the same badges, and the same reason for the generation bump.
        pendingInviteCountByIdHex.removeAll()
        pendingInviteCountGeneration &+= 1
        // Read markers are keyed by groupIdHex; leaving them behind both retains a
        // record of which messages the signed-out identity read and lets a recurring
        // group id suppress the first legitimate read-mark advance after re-login. The
        // delivered-notification keys are likewise account-scoped residue. See #241.
        lastMarkedReadMarkers.removeAll()
        lastConfirmedReadMarkers.removeAll()
        deliveredNotificationKeys.removeAll()
        deliveredNotificationKeyOrder.removeAll()
        resetAccountScopedGroupAndNewChatUIState()
        // Sign-out and account removal reach onboarding without going through
        // `prepareForActiveAccountSwitch` when no signed-in account remains, so the destructive
        // -action dialogs have to be dropped here too — they name a group id belonging to the
        // account being torn down.
        clearPendingChatDestructiveActions()
        profileDraft = ProfileDraft()
        resetProfileEditingState()
        keyPackages = []
        auditLogFiles = []
        auditLogUploadStatus = nil
    }

    private func resetAccountScopedGroupAndNewChatUIState() {
        isNewChatComposerVisible = false
        resetNewChatComposer()
        resetComposeContacts()
        clearFollows()
        isResolvingNewChat = false
        isCreatingChat = false

        isGroupImagePickerPresented = false
        groupImageSearchQuery = ""
        groupImageResults = []
        invalidateGroupImageSearch()
        closeProfileImagePicker()
        profileImageUploadGeneration &+= 1
        isUploadingProfileImage = false

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
        let selectedGroupId = wasActive ? selectedChat?.id : nil
        do {
            await flushComposerDraftPersistence(forAccountId: account.id)
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
                switchActiveAccount(nextActive, finalSelection: settingsSelectionAfterAccountMutation)
                await configureObservabilityRuntimeBestEffort()
                await loadSettingsData()
            } else {
                // Signing out the last identity is a way out of the app, so it lands where a
                // first launch does. It used to stay in `.ready` with no active account, which
                // drew a list of this Mac's deactivated identities offering to reactivate one
                // with a click — undoing the sign-out that had just been confirmed. Coming back
                // is Sign In or Sign Up now; the core reactivates a matching signed-out account
                // on login, so this identity's chats are still waiting behind its key.
                activeAccountId = nil
                invalidateNotificationSettingsOperations()
                invalidatePrivacySecurityOperations()
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
                selection = nil
                authenticationMode = .landing
                clearEnteredLoginIdentity()
                phase = .onboarding
                notificationSettings = .defaults
                privacySecuritySettings = .defaults
            }
        } catch {
            if wasActive, activeAccountId == account.id {
                await restoreReadySessionAfterInterruptedMutation(selectedGroupId: selectedGroupId)
            }
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
                    switchActiveAccount(refreshed, finalSelection: settingsSelectionAfterAccountMutation)
                    await configureObservabilityRuntimeBestEffort()
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
        await refreshAccountUnreadSummary(reflecting: currentAccountUnreadSignal())
        await refreshPendingInviteCounts()
    }

    /// Re-read the unanswered-invitation counts behind the non-active accounts' avatar badges.
    ///
    /// Deliberately absent from `refreshAccountUnreadSummaryIfChatRowsMovedIt`: that gate fires on
    /// the *active* account's row deltas, and no delta of its rows can move another account's
    /// invitations, while its own are counted off those very rows. Every path that can move them —
    /// a full chat-list reload, an account switch, a sign-in, and a notification landing on a
    /// background account — goes through `refreshAccountUnreadSummary()` above.
    ///
    /// The unread summary answers for every account in one call; invitations have no such
    /// aggregate in this binding, so each account is read separately. That is the same cost class
    /// (one local projection read per account, no session load, no network), which is why this is
    /// kept off the per-read-marker path.
    private func refreshPendingInviteCounts() async {
        guard let client else { return }
        // Same race as the unread summary: two refreshes can be in flight and the FFI answers in
        // whatever order it finishes, so only the newest request may commit.
        pendingInviteCountGeneration &+= 1
        let generation = pendingInviteCountGeneration
        // The active account is excluded here and answered from its rows; a signed-out account
        // has no badge count at all, and no rail avatar to hang one on — `signedInAccounts`
        // leaves it out.
        let targets = accounts.filter { !$0.signedOut && $0.id != activeAccountId }
        var counts: [String: Int] = [:]
        for target in targets {
            do {
                let rows = try await FFIExecutor.run {
                    try client.chatList(accountRef: target.accountRef, includeArchived: false)
                }
                counts[target.accountIdHex] = PendingInviteBadgeCount.count(inRows: rows)
            } catch {
                // Badges are best-effort: keep this account's previous count rather than dropping
                // an invitation off the rail because one projection read failed.
                if let previous = pendingInviteCountByIdHex[target.accountIdHex] {
                    counts[target.accountIdHex] = previous
                }
            }
        }
        guard pendingInviteCountGeneration == generation else { return }
        pendingInviteCountByIdHex = counts
    }

    /// Re-run the summary only when the active account's own chat rows have moved its unread total.
    ///
    /// The avatar badge reads `accountUnreadByIdHex`, which comes from a different backend query
    /// than the chat-list subscription feeding the rows. Reading a chat updates the rows live but
    /// left the summary at its pre-read value, so the active account's avatar kept a badge for
    /// messages it had already read until the next full reload or account switch (the only two
    /// callers of the summary). Gating on the row-derived signal keeps the badge honest without
    /// putting an FFI query on every read-marker advance.
    func refreshAccountUnreadSummaryIfChatRowsMovedIt() async {
        let signal = currentAccountUnreadSignal()
        guard signal != lastSummarizedAccountUnread else { return }
        await refreshAccountUnreadSummary(reflecting: signal)
    }

    /// Re-run the summary when a notification lands on an account other than the active one.
    ///
    /// Only the active account runs a chat-list subscription, so the row deltas that keep its own
    /// badge honest never arrive for the others. Their avatar badges held whatever the last account
    /// switch or full reload recorded, which is why incoming messages appeared to count only once
    /// the user switched to that account.
    ///
    /// The active account is deliberately left to the row path: it is the more precise signal, and
    /// querying here as well would put a second summary read on every message it receives.
    func refreshAccountUnreadSummaryForBackgroundAccount(receiving update: NotificationUpdateFfi) async {
        guard let activeAccount, activeAccount.accountIdHex != update.accountIdHex else { return }
        await refreshAccountUnreadSummary()
    }

    private func refreshAccountUnreadSummary(reflecting signal: AccountUnreadSignal?) async {
        guard let client else { return }
        // Two refreshes can be in flight at once (a read-marker advance and a chat-list reload
        // race routinely), and the FFI answers in whatever order it finishes. Only the newest
        // request for the still-active account may commit: a late answer landing last would
        // restore a pre-read total and — because committing also records its signal — leave the
        // gate suppressing the very refresh that would correct it.
        accountUnreadSummaryGeneration &+= 1
        let generation = accountUnreadSummaryGeneration
        let requestedAccountId = activeAccountId
        do {
            let rows = try await FFIExecutor.run { try client.accountUnreadSummary() }
            guard accountUnreadSummaryGeneration == generation, activeAccountId == requestedAccountId else {
                return
            }
            accountUnreadByIdHex = Dictionary(
                rows.map { ($0.accountIdHex, Int(clamping: $0.unreadCount)) },
                uniquingKeysWith: { lhs, _ in lhs }
            )
            // Record the signal captured before the query, not the current one: rows that changed
            // while it was in flight are not reflected in these totals and must still trigger a
            // follow-up refresh.
            lastSummarizedAccountUnread = signal
        } catch {
            // Unread badges are best-effort; leave the prior values — and the prior signal, so the
            // next row change retries — on failure.
        }
    }

    /// The active account's aggregate unread state as its own loaded chat rows report it.
    ///
    /// This is never what the badge displays (that stays the backend summary, which is the only
    /// value comparable across accounts); it is the cheap local signal for noticing that the
    /// displayed summary went stale.
    func currentAccountUnreadSignal() -> AccountUnreadSignal? {
        guard let activeAccountId else { return nil }
        // Unarchived chats only, matching what the summary this guards counts: the core sums
        // unread over `WHERE row.archived = 0`, so an archived chat's unread messages are not in
        // the displayed total and a change confined to them cannot move it. Counting them here as
        // well made archiving invisible to the gate — the row moved from one counted list to the
        // other, leaving the totals identical — so the badge went on counting a chat the user had
        // just archived until the next full reload or account switch.
        let chats = chatsByAccount[activeAccountId] ?? []
        var totalUnreadCount = 0
        var unreadChatCount = 0
        for chat in chats {
            // A change signal, not a displayed count: wrapping addition keeps a pathological
            // row total (rows clamp to `Int.max`) from trapping here.
            totalUnreadCount &+= chat.unreadCount
            if chat.hasUnread {
                unreadChatCount += 1
            }
        }
        return AccountUnreadSignal(
            accountId: activeAccountId,
            totalUnreadCount: totalUnreadCount,
            unreadChatCount: unreadChatCount,
            chatCount: chats.count
        )
    }

    /// Aggregate attention count for an account's avatar badge in the rail:
    /// unread messages plus one for each invitation the account has not answered yet.
    ///
    /// An unaccepted invite has no timeline, so it adds nothing to the unread total however long
    /// it sits there — the badge said "nothing to see" while the chat list was showing an invite.
    /// Counting it as +1 matches how the core aggregates its own badge attention
    /// (`attention_only_conversations`) and how the row already presents it.
    func unreadCount(forAccountIdHex accountIdHex: String) -> Int {
        let unread = accountUnreadByIdHex[accountIdHex] ?? 0
        // Wrapping addition: both sides are clamped row totals, so a pathological unread count
        // must not trap here for the sake of a badge that reads "99+" either way.
        return unread &+ pendingInviteCount(forAccountIdHex: accountIdHex)
    }

    /// Unanswered invitations for one account, live for the active account and from the last
    /// projection read for the others.
    ///
    /// The active account is answered from its loaded rows rather than from
    /// `pendingInviteCountByIdHex`, so accepting or declining an invite — or receiving one —
    /// moves its badge on the chat-list update that changed the row, with no FFI round trip to
    /// wait through and no window where the two disagree.
    func pendingInviteCount(forAccountIdHex accountIdHex: String) -> Int {
        if let activeAccount, activeAccount.accountIdHex == accountIdHex {
            return PendingInviteBadgeCount.count(inUnarchived: activeChats)
        }
        return pendingInviteCountByIdHex[accountIdHex] ?? 0
    }

    func deleteAllData() async {
        guard let client, !isAccountMutationInProgress else { return }

        isDeletingAllData = true
        lastError = nil
        suppressAllMediaDiskStores()
        defer { resumeAllMediaDiskStores() }
        defer { isDeletingAllData = false }

        let selectedGroupId = selectedChat?.id

        // Stop any in-progress voice recording before the wipe so the mic is not left hot
        // (and no plaintext audio keeps being written) while local data is deleted (#311).
        leaveActiveConversation()
        stopNotificationListener()
        cancelChatListReload()
        stopChatListListener()
        stopTimelineListener()

        // Marmot only owns its storage root; plaintext media scratch directories live
        // outside it, so purge those before the potentially throwing Marmot deletion.
        // The encrypted media cache stays until the delete succeeds — on a pre-shutdown failure
        // the recovered session must keep its cached media intact and decryptable.
        try? await FFIExecutor.run {
            MediaPlaybackTempStore.purge()
            OutgoingMediaMetadataTempStore.purge()
        }

        do {
            try await client.deleteAllLocalData()
        } catch {
            let errorMessage = error.localizedDescription
            if let deletionError = error as? MarmotLocalDataDeletionError,
                case .runtimeInvalidated = deletionError
            {
                await mediaDiskCache.purgeAll(removeEncryptionKey: true)
                transitionToPostDeletionOnboarding(storageRootPath: client.storageRootPath)
                if let recreationError = await recreateClientForOnboarding() {
                    setBackgroundStatus(recreationError.localizedDescription)
                }
            } else {
                await restoreReadySessionAfterInterruptedMutation(selectedGroupId: selectedGroupId)
            }
            lastError = errorMessage
            return
        }

        await mediaDiskCache.purgeAll(removeEncryptionKey: true)
        transitionToPostDeletionOnboarding(storageRootPath: client.storageRootPath)
        if let recreationError = await recreateClientForOnboarding() {
            lastError = recreationError.localizedDescription
        }
    }

    func restoreReadySessionAfterInterruptedMutation(selectedGroupId: String?) async {
        guard client != nil, activeAccount != nil, case .ready = phase else { return }

        startNotificationListener()
        await reloadChats(forceFreshSnapshot: true)
        if let selectedGroupId, selectedChat?.id == selectedGroupId {
            await loadMessages(groupIdHex: selectedGroupId)
        }
    }

    private func transitionToPostDeletionOnboarding(storageRootPath: String) {
        client = nil
        observabilityRuntimeGeneration &+= 1
        observabilityRuntimeConfiguration = nil
        resetToNewInstallState(storageRootPath: storageRootPath)
    }

    private func recreateClientForOnboarding() async -> Error? {
        guard client == nil else { return nil }
        do {
            let runtime = try clientFactory()
            client = runtime
            storageRootPath = runtime.storageRootPath
            await configureObservabilityRuntimeBestEffort()
            return nil
        } catch {
            client = nil
            return error
        }
    }

    /// The runtime an authentication path runs against, recreating it if onboarding tore it down.
    ///
    /// Not `private`: `completeSignUp()` lives in `WorkspaceState+SignUp.swift` and is the same
    /// kind of caller as `signUp()` and `login()` right here.
    func clientForAuthentication() async -> (any MarmotRuntime)? {
        if let client { return client }
        if let error = await recreateClientForOnboarding() {
            lastError = error.localizedDescription
            return nil
        }
        return client
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
        invalidatePrivacySecurityOperations()
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
        // Seed relays alone miss an identity published only to its own NIP-65 write relays,
        // so use the same union every peer refresh uses.
        let relays = await peerProfileLookupRelaysForActiveAccount()
        for accountIdHex in accountIds {
            try? await client.refreshProfile(accountIdHex: accountIdHex, relays: relays)
        }

        guard let refreshed = try? await accountItemsFromRuntime(client: client) else { return }
        accounts = refreshed
        restoreOrSelectFirstAccount()
    }

    func refreshAccounts(preferred summary: AccountSummaryFfi) async throws {
        guard let client else { return }
        await flushComposerDraftPersistence()
        let preferredItems = try await accountItems(from: [summary], client: client)
        let preferredAccount = preferredItems.first ?? Self.accountItem(from: summary, resolved: nil)
        var refreshed = try await accountItemsFromRuntime(client: client)
        if !refreshed.contains(where: { $0.id == preferredAccount.id }) {
            refreshed.append(preferredAccount)
        }

        accounts = refreshed
        resetComposeContacts()
        clearFollows()
        activeAccountId = preferredAccount.id
        invalidateNotificationSettingsOperations()
        invalidatePrivacySecurityOperations()
        UserDefaults.standard.set(preferredAccount.id, forKey: Self.activeAccountKey)
        invalidateSidebarMessageSearch(clearQuery: true)
        clearAllComposerDrafts()
        selection = nil
    }

    /// Returns once MDK's local account/runtime state is ready. In 0.9.8 relay
    /// activation and catch-up continue asynchronously, so UI readiness no longer
    /// waits on network I/O. `start()` remains idempotent and must be called after
    /// every login/sign-up so newly added accounts get workers and subscriptions.
    func bringRuntimeOnline(_ runtime: any MarmotRuntime) async throws {
        try await runtime.start()
    }

    func resetToNewInstallState(storageRootPath: String) {
        leaveActiveConversation()
        stopNotificationListener()
        cancelChatListReload()
        stopChatListListener()
        stopTimelineListener()
        cancelTimelineLoad()
        accounts = []
        resetChats()
        clearPendingChatDestructiveActions()
        cachedMessageChatIds = []
        for store in messageTimelineStores.values {
            store.clear()
        }
        messageTimelineStores = [:]
        resetMediaDownloadStateStores()
        mediaCacheFootprintRefreshGeneration &+= 1
        mediaCacheFootprint = .zero
        isLoadingMediaCacheFootprint = false
        isClearingMediaCache = false
        mediaCacheReclaimedByteCount = nil
        mediaCacheGeneration &+= 1
        peerProfileFFICache.removeAll()
        clearPeerProfileRefreshState()
        clearGroupMemberCache()
        clearConversationMetadata()
        clearSharedMedia()
        accountUnreadByIdHex.removeAll()
        lastSummarizedAccountUnread = nil
        accountUnreadSummaryGeneration &+= 1
        pendingInviteCountByIdHex.removeAll()
        pendingInviteCountGeneration &+= 1
        // "Delete All Local Data" must also evict decoded peer/group avatars held in the
        // process-lifetime decoded-image cache; those images derive from attacker-controlled
        // peer `picture` URLs and would otherwise survive the wipe in memory. See #177.
        RemoteImageLoader.shared.clearCache()
        settingsLoadTask?.cancel()
        settingsLoadTask = nil
        settingsLoadAccountId = nil
        settingsLoadGeneration &+= 1
        privacySecurityLoadTask?.cancel()
        privacySecurityLoadTask = nil
        privacySecurityLoadAccountId = nil
        privacySecurityLoadGeneration &+= 1
        observabilityRuntimeGeneration &+= 1
        observabilityRuntimeConfiguration = nil
        activeAccountId = nil
        invalidateNotificationSettingsOperations()
        invalidatePrivacySecurityOperations()
        selection = nil
        invalidateSidebarMessageSearch(clearQuery: true)
        isChatListVisible = true
        clearAllComposerDrafts()
        clearAllHiddenMessages()
        clearAllPinnedChats()
        clearAllContactNicknames()
        clearAllRememberedDirectPeers()
        clearChatRestorationTargets()
        clearImprovementsPromptRecords()
        isRefreshing = false
        isSending = false
        authenticationMode = .landing
        loginIdentity = ""
        authenticationActivity = nil
        profileDraft = ProfileDraft()
        resetProfileEditingState()
        relaySettings = .defaults
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
        let summaries = try await FFIExecutor.run {
            try client.listAccounts()
        }
        return try await accountItems(from: summaries, client: client)
    }

    func accountItems(
        from summaries: [AccountSummaryFfi],
        client: any MarmotRuntime
    ) async throws -> [AccountItem] {
        try await FFIExecutor.run {
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
