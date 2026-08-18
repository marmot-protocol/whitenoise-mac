//
//  SettingsPanelView.swift
//  whitenoise-mac
//
//  The settings surface's router: one page per `SettingsPage`, each of them a file of
//  its own beside this one. Switching identities is not a page here — it lives in the
//  switcher at the top of the settings drawer, in SettingsAccountSwitcherViews.swift.
//

import SwiftUI

struct SettingsPanelView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var page: SettingsPage {
        if case .settings(let page) = workspace.selection { return page }
        return .overview
    }

    var body: some View {
        Group {
            switch page {
            case .overview:
                ProfileSettingsView()
            case .preferences:
                PreferencesSettingsView()
            case .profile:
                ProfileSettingsView()
            case .identityKeys:
                IdentityKeysSettingsView()
            case .relays:
                RelaySettingsView()
            case .keyPackages:
                KeyPackageSettingsView()
            case .appearance:
                AppearanceSettingsView()
            case .privacySecurity:
                PrivacySecuritySettingsView()
            case .notifications:
                NotificationsSettingsView()
            case .storage:
                StorageSettingsView()
            case .developerMode:
                DeveloperModeSettingsView()
            }
        }
        // The same surface the transcript and the group/contact detail panes draw on, rather than
        // the glass wash this used to be. A settings page is a reading surface in the content
        // column, so it takes the reading surface: `backgroundPrimary`. The glass wash never
        // reached that value in light appearance — a material over `backgroundSecondary` with a
        // partial white tint lands visibly grayer than the chat beside it, which is the whole
        // complaint. Glass stays where it belongs in settings: the header (`GlassToolbarBackground`)
        // and the sheets that lift off this pane.
        .background {
            MessagesTranscriptBackground()
        }
        .task(id: workspace.activeAccountId) {
            await workspace.loadSettingsData()
        }
    }
}
