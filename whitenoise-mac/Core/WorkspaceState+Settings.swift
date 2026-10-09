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
    case notAnImage

    var errorDescription: String? {
        switch self {
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
    /// Loads the legacy aggregate settings snapshot (profile, relays, and notifications)
    /// for the active account.
    ///
    /// Settings loading is driven from more than one entry point — the settings view's
    /// `.task(id: workspace.activeAccountId)` and explicit reloads after account mutations (e.g.
    /// `removeAccount`, which changes `activeAccountId` *and* calls this directly). Without
    /// coalescing those paths can issue two overlapping loads for the same account, doubling the
    /// profile/relay/notification work and racing each other to write UI state. This
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
            resetProfileEditingState()
            relaySettings = .defaults
            notificationSettings = .defaults
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
        // before writing (mirroring `saveProfile`) so a stale load can't leak
        // account A's metadata onto B.
        do {
            let profile = try await FFIExecutor.run {
                try client.userProfile(accountIdHex: accountIdHex)
            }
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            profileDraft = ProfileDraft(profile: profile, fallbackName: fallbackName)
            publishedProfile = profileDraft
            let displayName = profileDraft.primaryDisplayName(fallback: fallbackName)
            updateActiveAccountProfile(displayName: displayName, pictureURL: profileDraft.picture)
            beginProfileNostrAddressCheck()
        } catch {
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            lastError = error.localizedDescription
            profileDraft = ProfileDraft(fallbackName: fallbackName)
            // A profile that could not be read is not a profile with unsaved edits in it. Without
            // this the page would open showing Cancel and Save over a form nobody has touched.
            publishedProfile = profileDraft
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
        } catch {
            guard !Task.isCancelled, activeAccountId == accountId else { return }
            lastError = error.localizedDescription
            relaySettings = .defaults
        }

        await refreshNotificationAuthorizationStatus()
        // The active account may have changed during the await above; abandon stale writes.
        guard !Task.isCancelled, activeAccountId == accountId else { return }
        await loadNotificationSettings()
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

        let localResult: NotificationSettingsFfi
        do {
            localResult = try await FFIExecutor.run {
                try client.setLocalNotificationsEnabled(
                    accountRef: accountRef,
                    enabled: enabled
                )
            }
        } catch {
            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            lastError = error.localizedDescription
            return
        }

        // Committed before the clean-up below is even attempted. The core has already changed by
        // this point, and mdk offers no call that moves both flags at once, so the two writes can
        // only fail apart — and a clean-up that throws must not take the write that succeeded down
        // with it. Publishing here is what keeps the pane telling the truth about the core when
        // that happens; the alternative left local alerts drawn as *on* after the core had turned
        // them off.
        guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
        notificationSettings = NotificationSettingsSnapshot(settings: localResult)

        // Native push only supplements local notifications: it wakes White Noise so it can post
        // one, so it cannot outlive the alerts it exists to deliver. Turning local alerts off
        // therefore withdraws the push registration's reason to exist in the core too, rather
        // than leaving a flag set that the pane draws as off.
        guard !enabled, localResult.nativePushEnabled else { return }

        do {
            let cleared = try await client.setNativePushEnabled(accountRef: accountRef, enabled: false)
            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            notificationSettings = NotificationSettingsSnapshot(settings: cleared)
        } catch {
            guard ownsNotificationSettingsOperation(accountId: accountId, generation: generation) else { return }
            // The snapshot keeps saying native push is on, because in the core it is. The pane
            // still draws that switch off — it reads local alerts first — so the reader is not
            // told about a wake-up that can no longer reach them, and the next load reconciles.
            lastError = error.localizedDescription
        }
    }

    /// The generic wake-up White Noise asks the push service for. It carries nothing about the
    /// message, so it needs no permission of its own beyond the one local alerts already hold —
    /// which is why this, unlike `setLocalNotificationsEnabled(_:)`, never prompts.
    func setNativePushEnabled(_ enabled: Bool) async {
        guard let client, let activeAccount, !isSavingNotifications else { return }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        let generation = beginNotificationSettingsOperation()

        lastError = nil
        isSavingNotifications = true
        defer { isSavingNotifications = false }

        do {
            let settings = try await client.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
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

    func saveProfile() async {
        guard let client, let activeAccount, !isSavingProfile else { return }
        // Normalized on the way out rather than on every keystroke: `NIP05Identifier` lowercases
        // the local part and canonicalizes the domain, and doing that under the cursor would
        // rewrite what someone is halfway through typing.
        profileDraft.nip05 = Self.normalizedNostrAddress(profileDraft.nip05)
        // `publishUserProfile` targets the captured `accountRef`, but on return we write UI state via
        // the live `activeAccountId`. Capture the account id so an A→B switch during the publish
        // can't misattribute A's profile to B (mirroring `performSettingsLoad`).
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
            // Only a publish that landed moves the baseline, which is what puts Cancel and Save
            // away. A failure leaves the fields as typed against the old baseline, so the actions
            // stay up and the same Save can be pressed again.
            publishedProfile = profileDraft
            beginProfileNostrAddressCheck()
        } catch {
            guard activeAccountId == accountId else { return }
            lastError = error.localizedDescription
        }
    }

    // MARK: - Editing the profile

    /// Whether the form has been moved off what is published — the question the page's actions are
    /// the answer to.
    ///
    /// **This is what replaced an Edit button.** The page used to open read-only and wake up on a
    /// press; it is live now, and Cancel and Save appear only once there is something for them to
    /// do. A whole-value `!=` rather than a per-field audit, which is why `ProfileDraft` is
    /// `Equatable`: every field on the page is one somebody could have changed, the picture
    /// included, and a comparison that listed them would silently stop covering the next one added.
    ///
    /// `false` while `publishedProfile` is `nil` — before the load lands there is nothing to differ
    /// from, and an empty form is not an edit.
    var hasUnsavedProfileEdits: Bool {
        guard let publishedProfile else { return false }
        return profileDraft != publishedProfile
    }

    /// Put back everything that is published — the picture too, which is the field a cancel is most
    /// likely to be *about*, and the one that has already changed by the time you get here.
    ///
    /// The baseline is kept, not cleared: it is the published profile, not a session, so there is
    /// nothing to end. Restoring it simply makes `hasUnsavedProfileEdits` false again, which is
    /// what puts the actions away.
    func discardProfileEdits() {
        guard let publishedProfile else { return }
        profileDraft = publishedProfile
        lastError = nil
    }

    /// Whether Settings → Profile's fields accept input.
    ///
    /// Off mid-publish, which is the obvious half — and off while the settings load is in flight,
    /// which is not. `performSettingsLoad(accountId:generation:)` *replaces* `profileDraft` with
    /// what it reads, so anything typed before it lands is discarded without a word. That window
    /// used to be unreachable: the page opened read-only and its Edit button was disabled while
    /// loading. With the fields live from the moment the page appears, the window is exactly when
    /// somebody arrives and starts typing.
    var isProfileFormEnabled: Bool {
        !isSavingProfile && !isLoadingSettings
    }

    /// Whether the form as typed can be published: a name, and an address that is either absent or
    /// address-shaped. Nothing else on this page is required.
    var canSaveProfileEdits: Bool {
        !profileDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isProfileNostrAddressDraftValid
    }

    /// An empty address is valid — it is how the field is cleared. Anything else has to parse.
    var isProfileNostrAddressDraftValid: Bool {
        let trimmed = profileDraft.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || NIP05Identifier(trimmed) != nil
    }

    /// What the seal on the address field should say *right now*.
    ///
    /// `publishedNostrAddressVerification` is a statement about the address that was published.
    /// Typing a different one into the field does not inherit it — the seal drops the moment the
    /// draft diverges, and comes back if the stored value is typed again, which is
    /// `wn-ios-prototype`'s rule verbatim. Nothing here touches the network: a keystroke must not
    /// fire a request at a half-typed domain.
    var profileNostrAddressSeal: NostrAddressVerification {
        let draft = profileDraft.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return .none }
        guard let publishedProfile else { return publishedNostrAddressVerification }
        let stored = publishedProfile.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.caseInsensitiveCompare(stored) == .orderedSame else { return .unverified }
        return publishedNostrAddressVerification
    }

    /// Ask the published address's own domain whether it names this account, in the background.
    ///
    /// Started rather than awaited by its callers — the settings load must not wait on someone
    /// else's web server — but the handle is kept so a test can await the answer instead of
    /// polling for it, and so an account switch can cancel it.
    func beginProfileNostrAddressCheck() {
        profileNostrAddressCheckTask?.cancel()
        profileNostrAddressCheckTask = Task { [weak self] in
            await self?.refreshProfileNostrAddressVerification()
        }
    }

    func refreshProfileNostrAddressVerification() async {
        profileNostrAddressCheckGeneration &+= 1
        let generation = profileNostrAddressCheckGeneration

        guard let activeAccount else {
            publishedNostrAddressVerification = .none
            return
        }
        let accountId = activeAccount.id
        let accountIdHex = activeAccount.accountIdHex
        let npub = activeAccount.npub
        // The **published** address, not `profileDraft`'s. What this writes is
        // `publishedNostrAddressVerification`, a statement about what the profile publishes, and
        // the two are not the same value for as long as this task exists: `beginProfileNostrAddressCheck()`
        // schedules it rather than running it, so anything typed into the field between the
        // scheduling and the first line of this body is what a draft read would pick up. The
        // verdict then outlives the draft that earned it — `discardProfileEdits()` puts the
        // published address back and leaves the stale verdict standing, so `profileNostrAddressSeal`
        // hands the published address a seal (or withholds one) on a different address's evidence.
        guard let publishedProfile else {
            publishedNostrAddressVerification = .none
            return
        }
        let address = publishedProfile.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, NIP05Identifier(address) != nil else {
            publishedNostrAddressVerification = .none
            return
        }

        publishedNostrAddressVerification = .checking
        let verdict: NostrAddressVerification
        do {
            let reference = try await nip05Resolver.accountReference(for: address)
            verdict = Self.nostrAddressVerdict(reference: reference, accountIdHex: accountIdHex, npub: npub)
        } catch {
            // A domain that cannot be reached has not verified anything. The page says so by
            // drawing no seal, and never by reporting a network error over a field nobody asked
            // to publish just now.
            verdict = .unverified
        }
        guard !Task.isCancelled,
            activeAccountId == accountId,
            profileNostrAddressCheckGeneration == generation
        else { return }
        publishedNostrAddressVerification = verdict
    }

    /// The well-known document maps a name to a hex public key; some hosts write an npub instead.
    /// Either spelling of *this* account earns the seal, and anything else — including a perfectly
    /// valid key belonging to somebody else — does not.
    nonisolated static func nostrAddressVerdict(
        reference: String,
        accountIdHex: String,
        npub: String?
    ) -> NostrAddressVerification {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unverified }
        if trimmed.caseInsensitiveCompare(accountIdHex) == .orderedSame { return .verified }
        if let npub, trimmed.caseInsensitiveCompare(npub) == .orderedSame { return .verified }
        return .unverified
    }

    /// `NIP05Identifier`'s canonical spelling — lowercased local part, canonical domain — or the
    /// trimmed input unchanged when it does not parse, so a value the user has to fix is still the
    /// value they typed.
    /// Not `nonisolated`, unlike its neighbour above: `NIP05Identifier` inherits the module's
    /// MainActor default, so parsing from a nonisolated context is a Release-build warning that
    /// Debug never shows.
    static func normalizedNostrAddress(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = NIP05Identifier(trimmed) else { return trimmed }
        return "\(parsed.name)@\(parsed.domain)"
    }

    /// Drop everything the profile page is holding for the account being torn down.
    func resetProfileEditingState() {
        profileNostrAddressCheckTask?.cancel()
        profileNostrAddressCheckTask = nil
        profileNostrAddressCheckGeneration &+= 1
        publishedNostrAddressVerification = .none
        publishedProfile = nil
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

    /// Commit a picture that has already been through `AvatarCropSheet`.
    ///
    /// Every source — a file, a web search result — reaches this as the cropped JPEG the editor
    /// rendered, so the only thing left to do is send it where `profileImagePickerDestination`
    /// says. Throws what went wrong so the crop editor can show it beside the picture — including
    /// `CommitError.busy` while another picture is still saving, which the editor stays open over.
    /// A selection with no account left to save to, or superseded by a newer one, returns quietly.
    func setProfileImage(croppedImageData data: Data) async throws {
        guard !isUploadingProfileImage else { throw AvatarImageCropper.CommitError.busy }
        guard let context = beginProfileImageSelection() else { return }
        defer { finishProfileImageSelection(context) }

        do {
            let attachment = try await AvatarImageCropper.attachment(fromCroppedImageData: data)
            try await commitSelectedProfileImage(attachment, context: context)
        } catch is CancellationError {
            return
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
