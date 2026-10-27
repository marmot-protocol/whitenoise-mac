import Observation

@MainActor
@Observable
final class SettingsViewModel {
    let agentSettings: AgentSettingsViewModel
    let blockedUsersModel: BlockedUsersViewModel?
    let keyPackageSettings: KeyPackageSettingsViewModel
    let relays: RelaySettingsViewModel
    let quarantinedGroups: QuarantinedGroupsViewModel
    let storage: StorageSettingsViewModel
    let manageStorage: ManageStorageViewModel
    let diagnostics: DiagnosticsSettingsViewModel

    init(
        account: AccountItem,
        runtime: (any MarmotRuntime)?,
        attachmentPolicyController: AttachmentPolicyController? = nil,
        blockedUsersModel: BlockedUsersViewModel? = nil,
        productAnalytics: ProductAnalyticsRecorder? = nil,
        chatListModel: ChatListViewModel? = nil,
        relayListsDidChange: @escaping @MainActor () -> Void = {},
        attachmentsDidChange: @escaping @MainActor () async -> Void = {}
    ) {
        agentSettings = AgentSettingsViewModel(account: account, runtime: runtime)
        self.blockedUsersModel = blockedUsersModel
        keyPackageSettings = KeyPackageSettingsViewModel(accountRef: account.accountRef, runtime: runtime)
        relays = RelaySettingsViewModel(
            accountRef: account.accountRef,
            runtime: runtime,
            relayListsDidChange: relayListsDidChange
        )
        quarantinedGroups = QuarantinedGroupsViewModel(accountRef: account.accountRef, runtime: runtime)
        storage = StorageSettingsViewModel(
            accountRef: account.accountRef,
            runtime: runtime,
            attachmentPolicyController: attachmentPolicyController
        )
        manageStorage = ManageStorageViewModel(
            accountRef: account.accountRef,
            activeAccountIdHex: account.accountIdHex,
            runtime: runtime,
            chatList: chatListModel,
            attachmentsDidChange: attachmentsDidChange
        )
        diagnostics = DiagnosticsSettingsViewModel(
            runtime: runtime,
            productAnalytics: productAnalytics
        )
    }

    static func preview() -> SettingsViewModel {
        SettingsViewModel(account: AccountItem.samples[0], runtime: nil)
    }

    func deactivate() {
        relays.deactivate()
    }
}
