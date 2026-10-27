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
    let model: SettingsViewModel

    private var page: SettingsPage {
        if case .settings(let page) = workspace.selection { return page }
        return .overview
    }

    private var loadKey: SettingsPanelLoadKey {
        SettingsPanelLoadKey(accountID: workspace.activeAccountId, page: page)
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
                ProfileKeysSettingsView()
            case .relays:
                RelaySettingsView(model: model.relays)
            case .keyPackages:
                KeyPackageSettingsView(model: model.keyPackageSettings)
            case .appearance:
                AppearanceSettingsView()
            case .privacySecurity:
                PrivacySecuritySettingsView(model: model.diagnostics)
            case .blockedUsers:
                BlockedUsersSettingsView(model: model.blockedUsersModel)
            case .notifications:
                NotificationsSettingsView()
            case .storage:
                StorageSettingsView(model: model.storage)
            case .manageStorage:
                ManageStorageSettingsView(
                    model: model.manageStorage,
                    nicknames: workspace.activeContactNicknames
                )
            case .agents:
                AIAgentsSettingsView(model: model.agentSettings)
            case .support:
                SupportSettingsView()
            case .donate:
                DonateSettingsView()
            case .developerMode:
                DeveloperModeSettingsView(model: model.diagnostics)
            case .quarantinedGroups:
                QuarantinedGroupsSettingsView(model: model.quarantinedGroups)
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
        .task(id: loadKey) {
            guard page.usesLegacyWorkspaceSettings else { return }
            await workspace.loadSettingsData()
        }
    }
}

private struct SettingsPanelLoadKey: Equatable {
    let accountID: String?
    let page: SettingsPage
}

private extension SettingsPage {
    var usesLegacyWorkspaceSettings: Bool {
        switch self {
        case .overview, .profile, .identityKeys, .notifications:
            true
        case .preferences, .relays, .keyPackages, .appearance, .privacySecurity, .blockedUsers, .storage,
            .manageStorage, .agents, .support, .donate, .developerMode, .quarantinedGroups:
            false
        }
    }
}

#Preview {
    SettingsPanelView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 640)
}
