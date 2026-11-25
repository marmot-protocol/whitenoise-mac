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
    @Environment(SessionState.self) private var session
    let model: SettingsViewModel
    let deviceLinking: DeviceLinkingViewModel

    var page: SettingsPage = .profile

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
                ProfileKeysSettingsView(model: model.profileKeys)
            case .devices:
                DevicesSettingsView(
                    model: deviceLinking,
                    profileName: workspace.activeAccount?.displayName,
                    otherProfileRequests: session.linkRequests.requests(
                        excluding: workspace.activeAccount?.accountIdHex, accounts: workspace.signedInAccounts),
                    onReviewOtherProfile: { request in
                        if let account = workspace.signedInAccounts.first(where: {
                            $0.accountIdHex.lowercased() == request.accountIdHex
                        }) {
                            workspace.selectAccount(account)
                        }
                    }
                )
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
            case .deleteProfile:
                if let account = workspace.activeAccount {
                    DeleteProfileSettingsView(
                        model: model.deleteProfile,
                        account: account,
                        isAccountMutationInProgress: workspace.isAccountMutationInProgress,
                        handsOffToLinkedDevices: session.accountScope.map {
                            $0.account.id == account.id && !$0.deviceLinking.otherDevices.isEmpty
                        } == true
                    )
                }
            }
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
        case .preferences, .devices, .relays, .keyPackages, .appearance, .privacySecurity, .blockedUsers, .storage,
            .manageStorage, .agents, .support, .donate, .developerMode, .quarantinedGroups, .deleteProfile:
            false
        }
    }
}

#Preview {
    SettingsPanelView(model: .preview(), deviceLinking: .preview())
        .environment(WorkspaceState.preview())
        .environment(SessionState())
        .frame(width: 760, height: 640)
}
