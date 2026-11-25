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

    @Test func settingsSidebarOrdersCategoriesFiltersDevicesAndGuardsDeleteDuringMutation() {
        let expectedOrder: [SettingsPage] = [
            .profile, .identityKeys, .devices, .notifications, .appearance, .privacySecurity,
            .storage, .relays, .agents, .preferences, .support, .donate, .developerMode,
        ]
        #expect(SettingsPage.sidebarPages == expectedOrder)

        let withDevices = SettingsPage.sidebarGroups.flatMap {
            SettingsSidebarView.visiblePages(in: $0, devicesAvailable: true)
        }
        let withoutDevices = SettingsPage.sidebarGroups.flatMap {
            SettingsSidebarView.visiblePages(in: $0, devicesAvailable: false)
        }
        #expect(withDevices.contains(.devices))
        #expect(!withoutDevices.contains(.devices))
        #expect(withoutDevices.count == expectedOrder.count - 1)

        let workspace = WorkspaceState.preview()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        coordinator.open(at: .profile)

        let mutatingSidebar = SettingsSidebarView(
            coordinator: coordinator,
            account: AccountItem.samples[0],
            devicesAvailable: true,
            isAccountMutationInProgress: true,
            preferredLocale: .current
        )
        mutatingSidebar.select(.deleteProfile)
        #expect(coordinator.page == .profile)

        let idleSidebar = SettingsSidebarView(
            coordinator: coordinator,
            account: AccountItem.samples[0],
            devicesAvailable: true,
            isAccountMutationInProgress: false,
            preferredLocale: .current
        )
        idleSidebar.select(.deleteProfile)
        #expect(coordinator.page == .deleteProfile)
    }

    @Test func clickingSelectedParentRowInSettingsSidebarReturnsFromNestedSubpage() async {
        let workspace = WorkspaceState.preview()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        coordinator.open(at: .manageStorage)
        #expect(coordinator.page == .manageStorage)
        #expect(coordinator.parentPage == .storage)

        let sidebar = SettingsSidebarView(
            coordinator: coordinator,
            account: AccountItem.samples[0],
            devicesAvailable: true,
            isAccountMutationInProgress: false,
            preferredLocale: Locale(identifier: "en")
        )
        let host = HostedViewWindow(
            sidebar
                .environment(workspace)
                .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 260, height: 640)
        )
        defer { host.close() }

        var selectedRowTarget: (tableView: NSTableView, row: Int)?
        _ = await host.settle {
            guard let contentView = host.window.contentView,
                let tableView = Self.tableView(in: contentView),
                tableView.selectedRow >= 0
            else { return false }
            selectedRowTarget = (tableView, tableView.selectedRow)
            return true
        }
        guard let selectedRowTarget, let contentView = host.window.contentView else {
            Issue.record("Expected selected parent row in native Settings sidebar list")
            return
        }

        let rowRect = selectedRowTarget.tableView.rect(ofRow: selectedRowTarget.row)
        let windowRect = selectedRowTarget.tableView.convert(rowRect, to: nil)
        let topLeftPoint = CGPoint(x: windowRect.midX, y: contentView.bounds.height - windowRect.midY)
        host.click(at: topLeftPoint)
        let returned = await host.settle { coordinator.page == .storage }
        #expect(returned)
        #expect(coordinator.page == .storage)
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

    // MARK: - #1107 Profile grouped form behavior

    @Test func profileSettingsFormRendersEditableFieldsAndTracksUnsavedChanges() async {
        let account = AccountSummaryFfi(
            label: "Alice",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()
        await workspace.loadSettingsData()

        let host = HostedViewWindow(
            ProfileSettingsView().environment(workspace),
            size: CGSize(width: 560, height: 640)
        )
        defer { host.close() }

        let renderedFields = await host.settle {
            guard let contentView = host.window.contentView else { return false }
            return Self.textFields(in: contentView).filter(\.isEditable).count == 3
        }
        #expect(renderedFields)
        #expect(!workspace.hasUnsavedProfileEdits)

        // Mutating the draft exposes unsaved edits, and invalid NIP-05 disables saving.
        workspace.profileDraft.nip05 = "not-a-valid-address"
        #expect(workspace.hasUnsavedProfileEdits)
        #expect(!workspace.isProfileNostrAddressDraftValid)
        #expect(!workspace.canSaveProfileEdits)

        workspace.profileDraft.nip05 = "alice@whitenoise.chat"
        #expect(workspace.hasUnsavedProfileEdits)
        #expect(workspace.isProfileNostrAddressDraftValid)
        #expect(workspace.canSaveProfileEdits)

        // Discarding restores the published draft and clears unsaved edits.
        workspace.discardProfileEdits()
        #expect(!workspace.hasUnsavedProfileEdits)
        #expect(workspace.profileDraft.nip05.isEmpty)
    }

    // MARK: - #1108 Privacy & Notifications safe rendering

    @Test func privacyAndNotificationsViewsRenderWithoutMutatingPreferencesOrRequestingPermissions() async {
        let suiteName = "settings-profile-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gifPreference = RemoteGIFLoadingPreference(defaults: defaults)
        let stickerPreference = StickerLoadingPreference(defaults: defaults)
        let linkPreference = LinkPreviewPreference(defaults: defaults)
        #expect(!gifPreference.automaticallyLoads)
        #expect(!stickerPreference.automaticallyLoads)
        #expect(!linkPreference.showsPreviews)

        let account = AccountSummaryFfi(
            label: "Alice",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let notificationCenter = FakeLocalNotificationCenter(status: .notDetermined)
        let workspace = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )
        await workspace.bootstrap()

        let privacyHost = HostedViewWindow(
            PrivacySecuritySettingsView(
                model: .preview(),
                gifPreference: gifPreference,
                stickerPreference: stickerPreference,
                linkPreviewPreference: linkPreference
            )
            .environment(workspace),
            size: CGSize(width: 560, height: 700)
        )
        defer { privacyHost.close() }
        _ = await privacyHost.steadyDrawing()

        let notificationsHost = HostedViewWindow(
            NotificationsSettingsView().environment(workspace),
            size: CGSize(width: 560, height: 560)
        )
        defer { notificationsHost.close() }
        _ = await notificationsHost.steadyDrawing()
        await workspace.refreshNotificationPermissionState()

        #expect(!gifPreference.automaticallyLoads)
        #expect(!stickerPreference.automaticallyLoads)
        #expect(!linkPreference.showsPreviews)
        #expect(!notificationCenter.didRequestAuthorization)
        #expect(workspace.notificationAuthorizationStatus == .notDetermined)
        #expect(!workspace.notificationSettings.localNotificationsEnabled)
        #expect(!workspace.notificationSettings.nativePushEnabled)
    }

    // MARK: - Helpers

    private static func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields(in:))
    }

    private static func tableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView { return tableView }
        for subview in view.subviews {
            if let found = tableView(in: subview) { return found }
        }
        return nil
    }
}
