//
//  WorkspaceState+Settings.swift
//  whitenoise-mac
//
//  Settings behavior extracted from WorkspaceState.swift (no behavior change).
//

import AVFoundation
import AppKit
import Combine
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

private enum ProfileImageSelectionError: LocalizedError {
    case invalidWebImage
    case downloadFailed
    case notAnImage

    var errorDescription: String? {
        switch self {
        case .invalidWebImage:
            L10n.string("The selected web image URL is not safe to download.")
        case .downloadFailed:
            L10n.string("The selected web image could not be downloaded.")
        case .notAnImage:
            L10n.string("Choose an image file.")
        }
    }
}

private struct ProfileImageUploadContext {
    let client: any MarmotRuntime
    let accountId: String
    let accountRef: String
    let generation: UInt64
}

/// Where a picked image is going, resolved once at the start of a selection.
///
/// Resolved up front rather than read again at commit time, for the same reason
/// `ProfileImageUploadContext` captures its account: the picker's work is `await`-heavy — a
/// download, a decode, a re-encode — and the destination must not be able to change underneath it.
private enum ProfileImageSelectionContext {
    /// Upload under the active account and set `profileDraft.picture` to the returned URL.
    case upload(ProfileImageUploadContext)
    /// Stage the bytes in `signUpDraft`; there is no account to upload them under yet.
    case stage(generation: UInt64)

    var generation: UInt64 {
        switch self {
        case .upload(let context): context.generation
        case .stage(let generation): generation
        }
    }
}

@MainActor
extension WorkspaceState {
    /// Loads the aggregate settings snapshot (profile, relays, notifications, privacy/security)
    /// for the active account.
    ///
    /// Settings loading is driven from more than one entry point — the settings view's
    /// `.task(id: workspace.activeAccountId)` and explicit reloads after account mutations (e.g.
    /// `removeAccount`, which changes `activeAccountId` *and* calls this directly). Without
    /// coalescing those paths can issue two overlapping loads for the same account, doubling the
    /// profile/relay/notification/privacy work and racing each other to write UI state. This
    /// method therefore enforces a single owner per account:
    ///
    /// - A concurrent call for the account already loading awaits the in-flight task (coalesces)
    ///   instead of starting a duplicate.
    /// - A call for a *different* account cancels the now-stale load — and the stale task, on
    ///   resuming, sees `activeAccountId` no longer matches and abandons its writes — so a slower
    ///   older load can never clobber the fresher account's UI state.
    func loadSettingsData() async {
        guard let activeAccount else {
            // No active account: cancel any in-flight load and reset to defaults synchronously.
            // The cancelled task may be suspended mid-flight; its `defer` will see a newer
            // generation (bumped below) and decline to touch `isLoadingSettings`, so this path
            // owns clearing the spinner — otherwise it would stay stuck `true` forever (issue #4).
            settingsLoadTask?.cancel()
            settingsLoadTask = nil
            settingsLoadAccountId = nil
            settingsLoadGeneration &+= 1
            isLoadingSettings = false
            profileDraft = ProfileDraft()
            relaySettings = .defaults
            relayDraft = relaySettings.relays(for: selectedRelaySection)
            keyPackages = []
            notificationSettings = .defaults
            privacySecuritySettings = .defaults
            return
        }

        let accountId = activeAccount.id

        // Coalesce: a request for the account already loading joins the in-flight task.
        if let existing = settingsLoadTask, settingsLoadAccountId == accountId {
            await existing.value
            return
        }

        // A request for a different account supersedes the stale in-flight load.
        settingsLoadTask?.cancel()

        settingsLoadGeneration &+= 1
        let generation = settingsLoadGeneration
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSettingsLoad(accountId: accountId, generation: generation)
        }
        settingsLoadTask = task
        settingsLoadAccountId = accountId

        await task.value

        // Only clear ownership if no newer load has since taken over this slot.
        if settingsLoadTask == task {
            settingsLoadTask = nil
            settingsLoadAccountId = nil
        }
    }

    /// Performs the actual settings fetches for `accountId`. Guarded so that if the active account
    /// changes (or the task is canceled) mid-flight, no stale results are written to the UI.
    ///
    /// `generation` is the monotonic token assigned when this load was started. The `defer` clears
    /// `isLoadingSettings` only while this is still the current generation. If a newer load has
    /// since superseded this one, that newer load owns the spinner and we must not dismiss it; if
    /// instead the load was cancelled with no replacement (active account cleared), the
    /// no-active-account branch in `loadSettingsData()` has already cleared the spinner. Keying on
    /// the generation rather than `activeAccountId` also handles a rapid A→B→A switch, where the
    /// account id alone would spuriously match.
    func performSettingsLoad(accountId: String, generation: UInt64) async {
        guard let client, let activeAccount, activeAccount.id == accountId else { return }

        isLoadingSettings = true
        defer {
            // Only the still-current owner clears the loading flag, so a superseded stale load
            // cannot prematurely dismiss the spinner for the newer account's load.
            if settingsLoadGeneration == generation {
                isLoadingSettings = false
            }
        }

        let accountIdHex = activeAccount.accountIdHex
        let accountRef = activeAccount.accountRef
        let fallbackName = activeAccount.displayName
        let pictureURL = activeAccount.pictureURL

        // `FFIExecutor.run` is not cancellation-aware, so an A→B switch during any of the FFI awaits below
        // leaves account A's load resuming and writing `profileDraft` / `relaySettings` — and, via the
        // live `activeAccountId`, clobbering account B's `accounts[]` entry. Re-check after every await
        // before writing (mirroring `loadKeyPackages` / `saveProfile`) so a stale load can't leak
        // account A's metadata onto B.
        do {
            let profile = try await FFIExecutor.run {
                try client.userProfile(accountIdHex: accountIdHex)
            }
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            profileDraft = ProfileDraft(profile: profile, fallbackName: fallbackName)
            let displayName = profileDraft.primaryDisplayName(fallback: fallbackName)
            updateActiveAccountProfile(displayName: displayName, pictureURL: profileDraft.picture)
        } catch {
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            lastError = error.localizedDescription
            profileDraft = ProfileDraft(fallbackName: fallbackName)
            let displayName =
                (try? await FFIExecutor.run {
                    client.displayName(accountIdHex: accountIdHex)
                }) ?? nil
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            if let displayName = displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !displayName.isEmpty
            {
                updateActiveAccountProfile(displayName: displayName, pictureURL: pictureURL)
            }
        }

        do {
            let lists = try await FFIExecutor.run {
                try client.accountRelayLists(accountRef: accountRef)
            }
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            relaySettings = RelaySettingsSnapshot(lists: lists)
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        } catch {
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            lastError = error.localizedDescription
            relaySettings = .defaults
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        }

        await refreshNotificationAuthorizationStatus()
        // The active account may have changed during the await above; abandon stale writes.
        guard !Task.isCancelled, activeAccountId == accountId else { return }
        await loadNotificationSettings()
        await loadPrivacySecuritySettings()
    }

    func loadKeyPackages() async {
        guard let client, let activeAccount else {
            keyPackages = []
            return
        }

        // The FFI call is not cancellation-aware, so an A→B account switch can leave account A's
        // slower-resolving load in flight. Capture the account id on entry and re-check after the
        // await (mirroring `performSettingsLoad` / `loadMediaAttachment`) so a stale result can't
        // overwrite — or, on error, blank — the newer account's key-package list.
        let accountId = activeAccount.id

        do {
            let packages = try await client.accountKeyPackages(
                accountRef: activeAccount.accountRef,
                bootstrapRelays: relaySettings.networkBootstrapRelays
            )
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            keyPackages = packages.map(KeyPackageItem.init(package:))
        } catch {
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            lastError = error.localizedDescription
            keyPackages = []
        }
    }

    func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await localNotificationCenter.authorizationStatus()
    }

    /// Re-reads the system permission, which lives in System Settings and can change while
    /// White Noise is in the background, and retires the "allow notifications, then try again"
    /// guidance once the user has actually granted it. The guidance is the one error the user
    /// resolves outside the app, so nothing else in the settings pane would ever clear it —
    /// it stayed on screen even after permission was granted.
    /// Only that exact message is cleared, so an unrelated failure on the pane survives.
    func refreshNotificationPermissionState() async {
        await refreshNotificationAuthorizationStatus()
        guard notificationAuthorizationStatus.canPostNotifications,
            lastError == Self.notificationPermissionGuidance
        else { return }
        lastError = nil
    }

    func beginNotificationSettingsOperation() -> UInt64 {
        notificationSettingsGeneration &+= 1
        return notificationSettingsGeneration
    }

    func invalidateNotificationSettingsOperations() {
        notificationSettingsGeneration &+= 1
    }

    func ownsNotificationSettingsOperation(accountId: String, generation: UInt64) -> Bool {
        !Task.isCancelled
            && activeAccountId == accountId
            && notificationSettingsGeneration == generation
    }

    /// Claims the privacy/security page for one account's save, returning the token that save must
    /// present to commit anything.
    func beginPrivacySecuritySave(accountId: String) -> UInt64 {
        isSavingPrivacySecurity = true
        privacySecuritySaveAccountId = accountId
        privacySecuritySettingsGeneration &+= 1
        return privacySecuritySettingsGeneration
    }

    /// Whether the save holding this token still speaks for the active account. Checked after every
    /// suspension point: the FFI write lands in the account that asked for it either way, but the
    /// published snapshot and `lastError` belong to whoever is on screen now.
    func ownsPrivacySecuritySave(accountId: String, generation: UInt64) -> Bool {
        activeAccountId == accountId
            && privacySecuritySaveAccountId == accountId
            && privacySecuritySettingsGeneration == generation
    }

    /// Drops the claim, but only if this save still holds it — an account switch, or the new
    /// identity's own save, has already taken it over, and clearing it from here would leave that
    /// save running with the toggles enabled behind it.
    func endPrivacySecuritySave(accountId: String, generation: UInt64) {
        guard privacySecuritySaveAccountId == accountId,
            privacySecuritySettingsGeneration == generation
        else { return }
        isSavingPrivacySecurity = false
        privacySecuritySaveAccountId = nil
    }

    /// Hands the privacy/security page to a new active account: whatever save was in flight no
    /// longer owns it, so the incoming identity can load and save on a page the outgoing one was
    /// midway through writing to.
    func invalidatePrivacySecurityOperations() {
        privacySecuritySettingsGeneration &+= 1
        privacySecuritySaveAccountId = nil
        isSavingPrivacySecurity = false
        // The toggles move optimistically, so the outgoing account can leave a value here that it
        // never committed anywhere — and the save that put it there is refused on the way out and
        // cannot take it back down. Clear the pane instead; the incoming identity's load fills it.
        privacySecuritySettings = .defaults
    }

    func requestLocalNotificationPermission() async {
        lastError = nil
        do {
            notificationAuthorizationStatus = try await localNotificationCenter.requestAuthorization()
            if !notificationAuthorizationStatus.canPostNotifications {
                lastError = Self.notificationPermissionGuidance
            }
        } catch {
            await handleNotificationPermissionError(error)
        }
    }

    func setLocalNotificationsEnabled(_ enabled: Bool) async {
        guard let client, let activeAccount, !isSavingNotifications else { return }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        let generation = beginNotificationSettingsOperation()

        lastError = nil
        isSavingNotifications = true
        defer { isSavingNotifications = false }

        if enabled {
            var status = notificationAuthorizationStatus
            if !status.canPostNotifications {
                do {
                    status = try await localNotificationCenter.requestAuthorization()
                    let isCurrent = ownsNotificationSettingsOperation(accountId: accountId, generation: generation)
                    guard isCurrent else { return }
                    notificationAuthorizationStatus = status
                } catch {
                    let isCurrent = ownsNotificationSettingsOperation(accountId: accountId, generation: generation)
                    guard isCurrent else { return }
                    await handleNotificationPermissionError(error) { [accountId, generation] in
                        self.ownsNotificationSettingsOperation(accountId: accountId, generation: generation)
                    }
                    return
                }
            }

            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            guard status.canPostNotifications else {
                lastError = Self.notificationPermissionGuidance
                return
            }
        }

        do {
            let settings = try await FFIExecutor.run {
                try client.setLocalNotificationsEnabled(
                    accountRef: accountRef,
                    enabled: enabled
                )
            }
            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        } catch {
            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            lastError = error.localizedDescription
        }
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func publishNewKeyPackage() async {
        guard let client, let activeAccount, !isPublishingKeyPackage else { return }
        lastError = nil
        isPublishingKeyPackage = true
        defer { isPublishingKeyPackage = false }

        do {
            _ = try await client.publishNewKeyPackage(accountRef: activeAccount.accountRef)
            await loadKeyPackages()
        } catch {
            if isNotificationsNotAllowedError(error) {
                await handleNotificationPermissionError(error)
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    func republishKeyPackage() async {
        guard let client, let activeAccount, !isRepublishingKeyPackage else { return }
        lastError = nil
        isRepublishingKeyPackage = true
        defer { isRepublishingKeyPackage = false }

        do {
            _ = try await client.republishKeyPackage(accountRef: activeAccount.accountRef)
            await loadKeyPackages()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteKeyPackage(_ package: KeyPackageItem) async {
        guard let client, let activeAccount, deletingKeyPackageId == nil else { return }
        guard !package.eventIdHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = L10n.string("Key package is missing an event id.")
            return
        }

        lastError = nil
        deletingKeyPackageId = package.id
        defer { deletingKeyPackageId = nil }

        do {
            _ = try await client.deleteAccountKeyPackage(
                accountRef: activeAccount.accountRef,
                eventIdHex: package.eventIdHex,
                relays: relaySettings.networkBootstrapRelays
            )
            await loadKeyPackages()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectRelaySection(_ section: RelaySettingsSection) {
        selectedRelaySection = section
        relayDraft = relaySettings.relays(for: section)
    }

    func addRelayDraftURL() {
        let url = newRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        guard isRelayURL(url) else {
            lastError = L10n.string("Relay URLs must use wss:// (cleartext ws:// is allowed only for localhost).")
            return
        }
        if !relayDraft.contains(url) {
            relayDraft.append(url)
        }
        newRelayURL = ""
    }

    func removeRelayDraftURL(_ url: String) {
        relayDraft.removeAll { $0 == url }
    }

    func restoreRelayDraftDefaults() {
        relayDraft = MarmotClient.seedRelays
        newRelayURL = ""
    }

    func saveRelaySettings() async {
        guard let client, let activeAccount, !isSavingRelays else { return }
        let relays = normalizedRelays(relayDraft)
        guard !relays.isEmpty else {
            lastError = L10n.string("Add at least one relay before saving.")
            return
        }
        guard relays.allSatisfy(isRelayURL) else {
            lastError = L10n.string("Relay URLs must use wss:// (cleartext ws:// is allowed only for localhost).")
            return
        }

        // The relay write targets the captured `accountRef`, but on return we write `relaySettings` /
        // `relayDraft` via the live active account. Capture the account id so an A→B switch during the
        // save can't misattribute A's relays to B (mirroring `performSettingsLoad` / `loadKeyPackages`).
        let accountId = activeAccount.id
        lastError = nil
        isSavingRelays = true
        defer { isSavingRelays = false }

        do {
            let lists: AccountRelayListsFfi
            let bootstrapRelays = relaySettings.networkBootstrapRelays
            switch selectedRelaySection {
            case .nip65:
                lists = try await client.setAccountNip65Relays(
                    accountRef: activeAccount.accountRef,
                    relays: relays,
                    bootstrapRelays: bootstrapRelays
                )
            case .inbox:
                lists = try await client.setAccountInboxRelays(
                    accountRef: activeAccount.accountRef,
                    relays: relays,
                    bootstrapRelays: bootstrapRelays
                )
            }
            guard activeAccountId == accountId else { return }
            relaySettings = RelaySettingsSnapshot(lists: lists)
            relayDraft = relaySettings.relays(for: selectedRelaySection)
            // `peerProfileLookupRelays(for:)` memoizes the seed + NIP-65 union for the whole
            // session, so without this a user who edits their relays here keeps searching the
            // pre-edit set for peer kind:0 until they switch accounts. Drop just this
            // account's entry; the next lookup rebuilds it from the list we were handed.
            peerProfileLookupRelaysByAccountId[accountId] = nil
        } catch {
            guard activeAccountId == accountId else { return }
            lastError = error.localizedDescription
        }
    }

    func saveProfile() async {
        guard let client, let activeAccount, !isSavingProfile else { return }
        // `publishUserProfile` targets the captured `accountRef`, but on return we write UI state via
        // the live `activeAccountId`. Capture the account id so an A→B switch during the publish
        // can't misattribute A's profile to B (mirroring `performSettingsLoad` / `loadKeyPackages`).
        let accountId = activeAccount.id
        lastError = nil
        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            let published = try await client.publishUserProfile(
                accountRef: activeAccount.accountRef,
                profile: profileDraft.metadata,
                defaultRelays: relaySettings.publishRelays,
                bootstrapRelays: relaySettings.networkBootstrapRelays
            )
            guard activeAccountId == accountId else { return }
            profileDraft = ProfileDraft(profile: published, fallbackName: activeAccount.displayName)
            let displayName = profileDraft.primaryDisplayName(fallback: activeAccount.displayName)
            updateActiveAccountProfile(displayName: displayName, pictureURL: profileDraft.picture)
        } catch {
            guard activeAccountId == accountId else { return }
            lastError = error.localizedDescription
        }
    }

    func showProfileImagePicker() {
        guard activeAccount != nil else { return }
        presentProfileImagePicker(destination: .activeAccount)
    }

    /// The shared body of `showProfileImagePicker()` and `showSignUpImagePicker()`. The caller
    /// owns the precondition — an account for one, the sign-up pane for the other — because the
    /// two have nothing in common beyond opening the same sheet.
    func presentProfileImagePicker(destination: ProfileImagePickerDestination) {
        lastError = nil
        profileImageSearchGeneration &+= 1
        profileImageSearchQuery = ""
        profileImageResults = []
        profileImageResultsQuery = nil
        selectedProfileImageResult = nil
        isSearchingProfileImages = false
        profileImagePickerDestination = destination
        isProfileImagePickerPresented = true
    }

    func closeProfileImagePicker() {
        isProfileImagePickerPresented = false
        profileImageSearchGeneration &+= 1
        profileImageResults = []
        profileImageResultsQuery = nil
        selectedProfileImageResult = nil
        isSearchingProfileImages = false
    }

    /// Point the profile-image machinery at a destination without opening the web picker.
    ///
    /// **Choose from Files** hangs off the avatar's own menu now — see `ProfileImageSourceMenu` —
    /// and never presents the sheet, so the destination `beginProfileImageSelection()` switches on
    /// has to be set somewhere other than `presentProfileImagePicker(destination:)`. Returns
    /// whether the caller may go on, which is the precondition the two entry points differ over:
    /// an account for one, the sign-up pane for the other.
    @discardableResult
    func prepareProfileImageDestination(_ destination: ProfileImagePickerDestination) -> Bool {
        switch destination {
        case .activeAccount:
            guard activeAccount != nil else { return false }
        case .signUpDraft:
            guard authenticationMode == .signUp, !isAuthenticating else { return false }
        }

        lastError = nil
        profileImagePickerDestination = destination
        return true
    }

    /// Take the selection, or drop it when the tile already holding it is pressed again.
    ///
    /// Nothing is downloaded here. The prototype's grid is a radio group whose commit is a
    /// separate button, and a selection that fetched bytes on the way in would spend a round trip
    /// on every glance.
    func selectProfileImage(_ result: GroupImageSearchResult) {
        guard !isUploadingProfileImage else { return }
        lastError = nil
        selectedProfileImageResult = selectedProfileImageResult == result ? nil : result
    }

    /// The web picker's confirmation: commit whatever tile is wearing the badge.
    func useSelectedProfileImage() async {
        guard let selectedProfileImageResult else { return }
        await setProfileImage(selectedProfileImageResult)
    }

    func searchProfileImages() async {
        let query = profileImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            profileImageSearchGeneration &+= 1
            profileImageResults = []
            profileImageResultsQuery = nil
            isSearchingProfileImages = false
            return
        }

        lastError = nil
        profileImageSearchGeneration &+= 1
        let generation = profileImageSearchGeneration
        isSearchingProfileImages = true
        defer {
            if profileImageSearchGeneration == generation {
                isSearchingProfileImages = false
            }
        }

        do {
            let results = try await groupImageSearchClient.searchImages(query: query)
            guard profileImageSearchGeneration == generation,
                isProfileImagePickerPresented,
                profileImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            profileImageResults = results
            profileImageResultsQuery = query
        } catch {
            guard profileImageSearchGeneration == generation, isProfileImagePickerPresented else { return }
            profileImageResults = []
            // A search that failed answered nothing, so the empty state goes back to asking for
            // one rather than blaming the spelling of a query that was never run.
            profileImageResultsQuery = nil
            lastError = error.localizedDescription
        }
    }

    func setProfileImage(_ result: GroupImageSearchResult) async {
        guard let context = beginProfileImageSelection() else { return }
        defer { finishProfileImageSelection(context) }

        guard let sourceURL = RemoteImageURLPolicy.sanitizedURL(from: result.imageURL) else {
            lastError = ProfileImageSelectionError.invalidWebImage.localizedDescription
            return
        }
        guard let data = await groupImageSourceLoader.data(for: sourceURL) else {
            lastError = ProfileImageSelectionError.downloadFailed.localizedDescription
            return
        }

        do {
            let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(
                fromPastedImageData: data,
                typeIdentifier: nil
            )
            try await commitSelectedProfileImage(attachment, context: context)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setProfileImage(fileURL: URL) async {
        guard let context = beginProfileImageSelection() else { return }
        defer { finishProfileImageSelection(context) }

        let isSecurityScoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: fileURL)
            try await commitSelectedProfileImage(attachment, context: context)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func beginProfileImageSelection() -> ProfileImageSelectionContext? {
        guard !isUploadingProfileImage else { return nil }
        switch profileImagePickerDestination {
        case .activeAccount:
            guard let client, let activeAccount else { return nil }
            profileImageUploadGeneration &+= 1
            lastError = nil
            isUploadingProfileImage = true
            return .upload(
                ProfileImageUploadContext(
                    client: client,
                    accountId: activeAccount.id,
                    accountRef: activeAccount.accountRef,
                    generation: profileImageUploadGeneration
                )
            )
        case .signUpDraft:
            profileImageUploadGeneration &+= 1
            lastError = nil
            isUploadingProfileImage = true
            return .stage(generation: profileImageUploadGeneration)
        }
    }

    private func finishProfileImageSelection(_ context: ProfileImageSelectionContext) {
        if profileImageUploadGeneration == context.generation {
            isUploadingProfileImage = false
        }
    }

    /// Turn prepared bytes into whatever the destination stores: a Blossom URL on
    /// `profileDraft.picture`, or the bytes themselves on `signUpDraft.image`.
    ///
    /// `isUploadingProfileImage` covers both, despite the name — it is what the sheet disables its
    /// controls on, and on the sign-up path it still spans the download-and-re-encode that a web
    /// image goes through before it can be staged.
    private func commitSelectedProfileImage(
        _ attachment: PendingMediaAttachment,
        context: ProfileImageSelectionContext
    ) async throws {
        guard attachment.kind == .image else {
            throw ProfileImageSelectionError.notAnImage
        }

        switch context {
        case .stage(let generation):
            // The pane check is the one the generation cannot make: backing out of sign-up
            // discards the draft without touching this counter, and a selection that was still
            // downloading would otherwise write a photo into a draft the user has abandoned.
            guard profileImageUploadGeneration == generation, authenticationMode == .signUp else {
                return
            }
            signUpDraft.image = SignUpProfileImage(attachment: attachment)
            closeProfileImagePicker()

        case .upload(let uploadContext):
            guard activeAccountId == uploadContext.accountId,
                profileImageUploadGeneration == uploadContext.generation
            else { return }

            let url = try await uploadContext.client.uploadProfileImage(
                accountRef: uploadContext.accountRef,
                data: attachment.data,
                mediaType: attachment.mediaType,
                blossomServer: nil
            )
            guard activeAccountId == uploadContext.accountId,
                profileImageUploadGeneration == uploadContext.generation
            else { return }
            primeUploadedProfileImage(url: url, data: attachment.data)
            profileDraft.picture = url
            closeProfileImagePicker()
        }
    }

    /// Hands the image loader the bytes just uploaded to `url`, so the avatars that are about to
    /// point at it draw the picture now.
    ///
    /// Without this, setting a profile picture reads as broken for as long as the round trip
    /// takes: the form's own 96pt avatar, the account rail beside the chat list, and Settings'
    /// profile card all take the new URL at once and every one shows initials until Blossom serves back
    /// the image the app had just finished sending it. Both upload sites call this — the settings
    /// picker here and `completeSignUp()` — because both are places where the app, and only the
    /// app, knows that these bytes are what lives at that URL.
    func primeUploadedProfileImage(url: String, data: Data) {
        guard let sanitized = RemoteImageURLPolicy.sanitizedURL(from: url) else { return }
        RemoteImageLoader.shared.primeRemoteImage(url: sanitized, data: data)
    }

    func loadNotificationSettings() async {
        guard let client, let activeAccount else {
            notificationSettings = .defaults
            return
        }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        let generation = beginNotificationSettingsOperation()

        do {
            let settings = try await FFIExecutor.run {
                try client.notificationSettings(accountRef: accountRef)
            }
            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        } catch {
            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            notificationSettings = .defaults
            lastError = error.localizedDescription
        }
    }

    func loadPrivacySecuritySettings() async {
        guard client != nil, let accountId = activeAccountId else {
            privacySecurityLoadTask?.cancel()
            privacySecurityLoadTask = nil
            privacySecurityLoadAccountId = nil
            privacySecurityLoadGeneration &+= 1
            privacySecuritySettings = .defaults
            return
        }
        // An in-flight save owns the published snapshot, a read here could resolve
        // before its commit and revert the toggle the user just saved.
        guard !isSavingPrivacySecurity else { return }

        if let existing = privacySecurityLoadTask, privacySecurityLoadAccountId == accountId {
            await existing.value
            return
        }

        privacySecurityLoadTask?.cancel()
        privacySecurityLoadGeneration &+= 1
        let loadGeneration = privacySecurityLoadGeneration
        let task = Task<Void, Never> { [weak self] in
            await self?.performPrivacySecuritySettingsLoad(
                accountId: accountId,
                loadGeneration: loadGeneration
            )
        }
        privacySecurityLoadTask = task
        privacySecurityLoadAccountId = accountId
        await task.value

        if privacySecurityLoadTask == task {
            privacySecurityLoadTask = nil
            privacySecurityLoadAccountId = nil
        }
    }

    private func performPrivacySecuritySettingsLoad(accountId: String, loadGeneration: UInt64) async {
        guard let client, activeAccountId == accountId else { return }
        let saveGeneration = privacySecuritySettingsGeneration

        // Runtime configuration is best-effort for this read: a transient failure must not
        // hide the persisted telemetry and audit settings from the user.
        var observabilityConfigurationError: Error?
        do {
            try await configureObservabilityRuntime()
        } catch {
            observabilityConfigurationError = error
        }
        guard !Task.isCancelled, privacySecurityLoadGeneration == loadGeneration,
            activeAccountId == accountId
        else { return }

        do {
            let (telemetry, auditLog) = try await FFIExecutor.run {
                (
                    try client.relayTelemetrySettings(),
                    try client.auditLogSettings()
                )
            }
            // A save, account switch, or newer load that started mid-flight supersedes this snapshot.
            guard !Task.isCancelled, privacySecurityLoadGeneration == loadGeneration,
                activeAccountId == accountId, privacySecuritySettingsGeneration == saveGeneration
            else { return }
            let config = telemetryBuildConfig
            privacySecuritySettings = PrivacySecuritySettingsSnapshot(
                relayTelemetryEnabled: telemetry.exportEnabled,
                relayTelemetryIntervalSeconds: telemetry.exportIntervalSeconds,
                auditLoggingEnabled: auditLog.enabled,
                telemetryCredentialsAvailable: config.telemetryCredentialsAvailable,
                auditLogCredentialsAvailable: config.auditLogCredentialsAvailable
            )
            if let observabilityConfigurationError {
                lastError = observabilityConfigurationError.localizedDescription
            }
            await loadAuditLogFiles()
        } catch {
            guard !Task.isCancelled, privacySecurityLoadGeneration == loadGeneration,
                activeAccountId == accountId, privacySecuritySettingsGeneration == saveGeneration
            else { return }
            privacySecuritySettings = .defaults
            auditLogFiles = []
            lastError = error.localizedDescription
        }
    }

    func setRelayTelemetryEnabled(_ enabled: Bool) async {
        guard let client, let accountId = activeAccountId, !isSavingPrivacySecurity else { return }
        let config = telemetryBuildConfig
        guard enabled == false || config.telemetryCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.telemetryNotConfigured.localizedDescription
            return
        }

        lastError = nil
        let generation = beginPrivacySecuritySave(accountId: accountId)
        defer { endPrivacySecuritySave(accountId: accountId, generation: generation) }
        // The toggle renders from this value, so leaving it at the old one until the relay write
        // returns makes the switch spring back under the pointer and then flip a moment later.
        // Move it now; the `catch` puts it back if the write never lands.
        let previousEnabled = privacySecuritySettings.relayTelemetryEnabled
        privacySecuritySettings.relayTelemetryEnabled = enabled

        do {
            try await configureObservabilityRuntime()
            let current = try await FFIExecutor.run {
                try client.relayTelemetrySettings()
            }
            let settings = RelayTelemetrySettingsFfi(
                exportEnabled: enabled,
                exportIntervalSeconds: current.exportIntervalSeconds
            )
            let stored = try await client.setRelayTelemetrySettings(settings: settings)
            guard ownsPrivacySecuritySave(accountId: accountId, generation: generation) else { return }
            privacySecuritySettings.relayTelemetryEnabled = stored.exportEnabled
            privacySecuritySettings.relayTelemetryIntervalSeconds = stored.exportIntervalSeconds
            privacySecuritySettings.telemetryCredentialsAvailable = telemetryBuildConfig.telemetryCredentialsAvailable
        } catch {
            guard ownsPrivacySecuritySave(accountId: accountId, generation: generation) else { return }
            privacySecuritySettings.relayTelemetryEnabled = previousEnabled
            lastError = error.localizedDescription
        }
    }

    func setAuditLoggingEnabled(_ enabled: Bool) async {
        guard let client, let accountId = activeAccountId, !isSavingPrivacySecurity else { return }
        let config = telemetryBuildConfig
        guard enabled == false || config.auditLogCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.auditLogNotConfigured.localizedDescription
            return
        }

        lastError = nil
        let generation = beginPrivacySecuritySave(accountId: accountId)
        defer { endPrivacySecuritySave(accountId: accountId, generation: generation) }
        // Same as the telemetry toggle above: the switch reads this value, so it moves now and
        // the `catch` puts it back, rather than lagging a round trip behind the pointer.
        let previousEnabled = privacySecuritySettings.auditLoggingEnabled
        privacySecuritySettings.auditLoggingEnabled = enabled

        do {
            try await configureObservabilityRuntime()
            // Audit logging is a single on/off choice here. Every write pins the data mode to
            // the minimum privacy-safe record set, which also downgrades a `.fullData` posture
            // left behind by another client or an older build.
            let stored = try await client.setAuditLogSettings(
                settings: AuditLogSettingsFfi(enabled: enabled, dataMode: .obfuscatedSensitiveData)
            )
            guard ownsPrivacySecuritySave(accountId: accountId, generation: generation) else { return }
            privacySecuritySettings.auditLoggingEnabled = stored.enabled
            privacySecuritySettings.auditLogCredentialsAvailable = telemetryBuildConfig.auditLogCredentialsAvailable
            await loadAuditLogFiles()
        } catch {
            guard ownsPrivacySecuritySave(accountId: accountId, generation: generation) else { return }
            privacySecuritySettings.auditLoggingEnabled = previousEnabled
            lastError = error.localizedDescription
        }
    }

    func loadAuditLogFiles() async {
        guard let client else {
            auditLogFiles = []
            shouldReloadAuditLogFilesAfterCurrentLoad = false
            return
        }
        guard !isLoadingAuditLogFiles else {
            shouldReloadAuditLogFilesAfterCurrentLoad = true
            return
        }

        isLoadingAuditLogFiles = true
        defer {
            isLoadingAuditLogFiles = false
            shouldReloadAuditLogFilesAfterCurrentLoad = false
        }

        repeat {
            shouldReloadAuditLogFilesAfterCurrentLoad = false
            do {
                auditLogFiles = try await FFIExecutor.run {
                    try client.auditLogFiles()
                }
            } catch {
                auditLogFiles = []
                lastError = error.localizedDescription
            }
        } while shouldReloadAuditLogFilesAfterCurrentLoad
    }

    func deleteAllAuditLogFiles() async {
        guard let client, !isDeletingAuditLogFiles else { return }

        isDeletingAuditLogFiles = true
        lastError = nil
        auditLogUploadStatus = nil
        defer { isDeletingAuditLogFiles = false }

        do {
            for file in auditLogFiles {
                _ = try await client.deleteAuditLogFile(path: file.path)
            }
        } catch {
            lastError = error.localizedDescription
        }

        await loadAuditLogFiles()
    }

    func uploadAuditLogFiles() async {
        guard let client, !isUploadingAuditLogFiles else { return }
        let config = telemetryBuildConfig
        guard config.auditLogCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.auditLogNotConfigured.localizedDescription
            return
        }

        isUploadingAuditLogFiles = true
        lastError = nil
        auditLogUploadStatus = nil
        defer { isUploadingAuditLogFiles = false }

        do {
            try await configureObservabilityRuntime()
            let result = try await client.postAuditLogTrackerUpdate()
            auditLogUploadStatus = Self.auditLogUploadStatusMessage(result)
            await loadAuditLogFiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func auditLogUploadStatusMessage(_ result: AuditLogTrackerUpdateResultFfi) -> String {
        if let skippedReason = result.skippedReason, !skippedReason.isEmpty {
            return String(format: L10n.string("Audit upload skipped: %@"), skippedReason)
        }
        guard !result.uploaded.isEmpty else {
            return L10n.string("No audit logs uploaded.")
        }
        let totalBytes = result.uploaded.reduce(UInt64(0)) { $0 + $1.bytesSent }
        return String(
            format: L10n.string("Uploaded %d audit log files (%@)."),
            result.uploaded.count,
            ByteCountFormatter.string(fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
        )
    }

    func normalizedRelays(_ relays: [String]) -> [String] {
        var seen = Set<String>()
        return
            relays
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    func isRelayURL(_ value: String) -> Bool {
        RelayURLValidator.isAcceptable(value)
    }

    /// Whether a saved relay uses cleartext `ws://` transport (loopback dev
    /// relay, or a pre-existing public `ws://` relay that loaded from a saved
    /// relay list) and should be surfaced as insecure in the UI.
    func isInsecureRelay(_ value: String) -> Bool {
        RelayURLValidator.isCleartext(value)
    }
}
