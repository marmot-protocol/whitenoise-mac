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

        do {
            let profile = try await runOffMain {
                try client.userProfile(accountIdHex: accountIdHex)
            }
            profileDraft = ProfileDraft(profile: profile, fallbackName: fallbackName)
            let displayName = profileDraft.primaryDisplayName(fallback: fallbackName)
            updateActiveAccountProfile(displayName: displayName, pictureURL: profileDraft.picture)
        } catch {
            lastError = error.localizedDescription
            profileDraft = ProfileDraft(fallbackName: fallbackName)
            let displayName =
                (try? await runOffMain {
                    client.displayName(accountIdHex: accountIdHex)
                }) ?? nil
            if let displayName = displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !displayName.isEmpty
            {
                updateActiveAccountProfile(displayName: displayName, pictureURL: pictureURL)
            }
        }

        do {
            let lists = try await runOffMain {
                try client.accountRelayLists(accountRef: accountRef)
            }
            relaySettings = RelaySettingsSnapshot(lists: lists)
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        } catch {
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

        do {
            let settings = try await runOffMain {
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
        newRelayURL = ""
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

    func loadNotificationSettings() async {
        guard let client, let activeAccount else {
            notificationSettings = .defaults
            return
        }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        let generation = beginNotificationSettingsOperation()

        do {
            let settings = try await runOffMain {
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
        guard let client else {
            privacySecuritySettings = .defaults
            return
        }

        do {
            try await configureObservabilityRuntime()
            let (telemetry, auditLog) = try await runOffMain {
                (
                    try client.relayTelemetrySettings(),
                    try client.auditLogSettings()
                )
            }
            let config = telemetryBuildConfig
            privacySecuritySettings = PrivacySecuritySettingsSnapshot(
                relayTelemetryEnabled: telemetry.exportEnabled,
                relayTelemetryIntervalSeconds: telemetry.exportIntervalSeconds,
                auditLoggingEnabled: auditLog.enabled,
                auditFullDataLogging: auditLog.dataMode == .fullData,
                telemetryCredentialsAvailable: config.telemetryCredentialsAvailable,
                auditLogCredentialsAvailable: config.auditLogCredentialsAvailable
            )
            await loadAuditLogFiles()
        } catch {
            privacySecuritySettings = .defaults
            auditLogFiles = []
            lastError = error.localizedDescription
        }
    }

    func setRelayTelemetryEnabled(_ enabled: Bool) async {
        guard let client, !isSavingPrivacySecurity else { return }
        let config = telemetryBuildConfig
        guard enabled == false || config.telemetryCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.telemetryNotConfigured.localizedDescription
            return
        }

        lastError = nil
        isSavingPrivacySecurity = true
        defer { isSavingPrivacySecurity = false }

        do {
            try await configureObservabilityRuntime()
            let current = try await runOffMain {
                try client.relayTelemetrySettings()
            }
            let settings = RelayTelemetrySettingsFfi(
                exportEnabled: enabled,
                exportIntervalSeconds: current.exportIntervalSeconds
            )
            let stored = try await client.setRelayTelemetrySettings(settings: settings)
            privacySecuritySettings.relayTelemetryEnabled = stored.exportEnabled
            privacySecuritySettings.relayTelemetryIntervalSeconds = stored.exportIntervalSeconds
            privacySecuritySettings.telemetryCredentialsAvailable = telemetryBuildConfig.telemetryCredentialsAvailable
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setAuditLoggingEnabled(_ enabled: Bool) async {
        guard let client, !isSavingPrivacySecurity else { return }
        let config = telemetryBuildConfig
        guard enabled == false || config.auditLogCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.auditLogNotConfigured.localizedDescription
            return
        }

        lastError = nil
        isSavingPrivacySecurity = true
        defer { isSavingPrivacySecurity = false }

        do {
            try await configureObservabilityRuntime()
            // Preserve the current data-mode posture when flipping the enabled flag.
            let dataMode: AuditDataModeFfi =
                privacySecuritySettings.auditFullDataLogging ? .fullData : .obfuscatedSensitiveData
            let stored = try await client.setAuditLogSettings(
                settings: AuditLogSettingsFfi(enabled: enabled, dataMode: dataMode)
            )
            privacySecuritySettings.auditLoggingEnabled = stored.enabled
            privacySecuritySettings.auditFullDataLogging = stored.dataMode == .fullData
            privacySecuritySettings.auditLogCredentialsAvailable = telemetryBuildConfig.auditLogCredentialsAvailable
            await loadAuditLogFiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setAuditFullDataLogging(_ enabled: Bool) async {
        guard let client, !isSavingPrivacySecurity else { return }

        lastError = nil
        isSavingPrivacySecurity = true
        defer { isSavingPrivacySecurity = false }

        do {
            try await configureObservabilityRuntime()
            let stored = try await client.setAuditLogSettings(
                settings: AuditLogSettingsFfi(
                    enabled: privacySecuritySettings.auditLoggingEnabled,
                    dataMode: enabled ? .fullData : .obfuscatedSensitiveData
                )
            )
            privacySecuritySettings.auditLoggingEnabled = stored.enabled
            privacySecuritySettings.auditFullDataLogging = stored.dataMode == .fullData
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadAuditLogFiles() async {
        guard let client else {
            auditLogFiles = []
            return
        }

        isLoadingAuditLogFiles = true
        defer { isLoadingAuditLogFiles = false }

        do {
            auditLogFiles = try await runOffMain {
                try client.auditLogFiles()
            }
        } catch {
            auditLogFiles = []
            lastError = error.localizedDescription
        }
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
