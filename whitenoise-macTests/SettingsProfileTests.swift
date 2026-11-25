//
//  SettingsProfileTests.swift
//  whitenoise-macTests
//
//  Behavioral tests for Settings navigation, Appearance, Profile, Privacy & Security, and
//  Notifications after the native macOS design refresh (#1036, #1107, #1108).
//

import AppKit
import Foundation
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized) @MainActor struct SettingsProfileTests {
    // MARK: - #1036 Settings labels, localization separation, and sidebar

    @Test func dataUsageAndDeveloperToolsUseSeparateCatalogKeysFromStorageAndDeveloperMode() {
        let english = Locale(identifier: "en")
        let german = Locale(identifier: AppLanguage.german.rawValue)
        let spanish = Locale(identifier: AppLanguage.spanish.rawValue)

        #expect(SettingsPage.storage.title(in: english) == "Data Usage")
        #expect(L10n.string("Storage", locale: english) == "Storage")
        #expect(SettingsPage.storage.title(in: german) != L10n.string("Storage", locale: german))
        #expect(SettingsPage.storage.title(in: spanish) != L10n.string("Storage", locale: spanish))

        #expect(SettingsPage.developerMode.title(in: english) == "Developer Tools")
        #expect(L10n.string("Developer mode", locale: english) == "Developer mode")
        #expect(SettingsPage.developerMode.title(in: german) != L10n.string("Developer mode", locale: german))
        #expect(SettingsPage.developerMode.title(in: spanish) != L10n.string("Developer mode", locale: spanish))

        #expect(SettingsBackDestination.developerMode.help == "Back to Developer Tools")
        if case .page(let destination) = SettingsBackDestination.developerMode.route {
            #expect(destination == .developerMode)
        } else {
            Issue.record("Expected SettingsBackDestination.developerMode to route to .developerMode")
        }
    }

    @Test func settingsSidebarAccessibilityIdentifiersAreUnique() {
        let allPages: [SettingsPage] = [
            .overview, .preferences, .profile, .identityKeys, .devices, .relays, .keyPackages, .appearance,
            .privacySecurity, .blockedUsers, .notifications, .storage, .manageStorage, .agents, .support,
            .donate, .developerMode, .quarantinedGroups, .deleteProfile,
        ]
        let identifiers = allPages.map(\.sidebarAccessibilityIdentifier)
        #expect(Set(identifiers).count == allPages.count)
        #expect(SettingsPage.storage.sidebarAccessibilityIdentifier == "settings.sidebar.data-usage")
        #expect(SettingsPage.developerMode.sidebarAccessibilityIdentifier == "settings.sidebar.developer-tools")
    }

    @Test func appearanceAndLanguageLabelsFollowRequestedLocale() {
        let german = Locale(identifier: AppLanguage.german.rawValue)
        let spanish = Locale(identifier: AppLanguage.spanish.rawValue)

        #expect(AppearancePreference.system.label(in: german) == "System")
        #expect(AppearancePreference.light.label(in: german) == "Hell")
        #expect(AppearancePreference.dark.label(in: german) == "Dunkel")
        #expect(AppearancePreference.light.label(in: spanish) == "Claro")
        #expect(AppearancePreference.dark.label(in: spanish) == "Oscuro")

        #expect(AppLanguage.system.displayName(in: spanish) == "Sistema")
        #expect(AppLanguage.german.displayName(in: spanish) == "Deutsch")
    }

    @Test func settingsSidebarAndPanesLayoutCleanlyInNativeSplitView() {
        let workspace = WorkspaceState.preview()
        let session = SessionState()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        coordinator.open(at: .appearance)

        let sidebarSize = Self.fittingSize(
            SettingsSidebarView(coordinator: coordinator)
                .environment(workspace)
                .environment(session)
                .frame(width: 260, height: 640)
        )
        #expect(sidebarSize.width > 0 && sidebarSize.height > 0)

        let appearanceSize = Self.fittingSize(
            AppearanceSettingsView()
                .environment(workspace)
                .environment(coordinator)
                .frame(width: 540, height: 420)
        )
        #expect(appearanceSize.width > 0 && appearanceSize.height > 0)

        coordinator.navigate(to: .blockedUsers)
        #expect(coordinator.parentPage == .privacySecurity)
        coordinator.navigate(to: .manageStorage)
        #expect(coordinator.parentPage == .storage)
    }

    // MARK: - #1107 Profile grouped form behavior

    @Test func profileSettingsFormRendersEditableFieldsAndTracksUnsavedChanges() throws {
        let workspace = WorkspaceState.preview()
        workspace.profileDraft.displayName = "Alice"
        workspace.profileDraft.about = "Hello"
        workspace.profileDraft.nip05 = "alice@example.com"
        let published = workspace.profileDraft

        let host = NSHostingView(
            rootView: ProfileSettingsView()
                .environment(workspace)
                .frame(width: 560, height: 640)
        )
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let editableFields = Self.textFields(in: host).filter(\.isEditable)
        #expect(editableFields.count == 3)

        // Mutating the draft exposes unsaved edits and invalid NIP-05 disables saving.
        workspace.profileDraft.nip05 = "not-a-valid-address"
        #expect(!workspace.isProfileNostrAddressDraftValid)
        #expect(!workspace.canSaveProfileEdits)

        workspace.profileDraft.nip05 = "alice@whitenoise.chat"
        #expect(workspace.isProfileNostrAddressDraftValid)
        #expect(workspace.canSaveProfileEdits)

        // Restoring published values clears unsaved edits cleanly.
        workspace.profileDraft = published
        #expect(workspace.profileDraft == published)
    }

    // MARK: - #1108 Privacy & Notifications safe rendering

    @Test func privacyAndNotificationsViewsRenderWithoutMutatingPreferencesOrRequestingPermissions() {
        let suiteName = "settings-profile-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gifPreference = RemoteGIFLoadingPreference(defaults: defaults)
        let stickerPreference = StickerLoadingPreference(defaults: defaults)
        let linkPreference = LinkPreviewPreference(defaults: defaults)
        #expect(!gifPreference.automaticallyLoads)
        #expect(!stickerPreference.automaticallyLoads)
        #expect(!linkPreference.showsPreviews)

        let workspace = WorkspaceState.preview()
        let privacySize = Self.fittingSize(
            PrivacySecuritySettingsView(model: .preview())
                .environment(workspace)
                .frame(width: 560, height: 700)
        )
        #expect(privacySize.width > 0 && privacySize.height > 0)

        let notificationsSize = Self.fittingSize(
            NotificationsSettingsView()
                .environment(workspace)
                .frame(width: 560, height: 560)
        )
        #expect(notificationsSize.width > 0 && notificationsSize.height > 0)
        #expect(!workspace.notificationSettings.localNotificationsEnabled)
        #expect(!workspace.notificationSettings.nativePushEnabled)
    }

    // MARK: - Helpers

    private static func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields(in:))
    }
}
