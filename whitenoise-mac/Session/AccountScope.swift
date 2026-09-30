import Foundation
import MarmotKit
import Observation

/// Owns everything whose lifetime is exactly one signed-in account.
///
/// Feature subscriptions register their cancellation with this scope instead of
/// relying on account-id checks after every await. Replacing the scope therefore
/// tears down the old account before the new account can publish view state.
@MainActor
@Observable
final class AccountScope {
    let account: AccountItem
    @ObservationIgnored let runtime: any MarmotRuntime
    let settingsModel: SettingsViewModel
    let chatListModel: ChatListViewModel
    let attentionModel: AccountAttentionViewModel
    let attachmentPolicy: AttachmentPolicyController
    let avatarAssets: AvatarAssetStore
    let blockedUsers: BlockedUsersViewModel
    let onboarding: OnboardingCoordinator
    let historyNotices: HistoryNoticesViewModel
    let productAnalytics: ProductAnalyticsRecorder
    private(set) var selectedConversationModel: ConversationViewModel?
    @ObservationIgnored private var attachmentPolicyTask: Task<Void, Never>?
    @ObservationIgnored private var cancellations: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var conversations: [String: (model: ConversationViewModel, cancellation: UUID)] = [:]
    @ObservationIgnored private var attachments: [String: (model: AttachmentViewModel, cancellation: UUID)] = [:]
    @ObservationIgnored private var groupSafety: [String: GroupSafetyViewModel] = [:]

    init(
        account: AccountItem,
        runtime: any MarmotRuntime,
        relayListsDidChange: @escaping @MainActor () -> Void = {}
    ) {
        let attachmentPolicy = AttachmentPolicyController(accountRef: account.accountRef, runtime: runtime)
        let blockedUsers = BlockedUsersViewModel(accountRef: account.accountRef, runtime: runtime)
        let productAnalytics = ProductAnalyticsRecorder()
        self.account = account
        self.runtime = runtime
        self.settingsModel = SettingsViewModel(
            account: account,
            runtime: runtime,
            attachmentPolicyController: attachmentPolicy,
            blockedUsersModel: blockedUsers,
            productAnalytics: productAnalytics,
            relayListsDidChange: relayListsDidChange
        )
        self.chatListModel = ChatListViewModel(
            account: account,
            runtime: runtime,
            blockedUsersModel: blockedUsers
        )
        self.attentionModel = AccountAttentionViewModel(runtime: runtime)
        self.attachmentPolicy = attachmentPolicy
        self.avatarAssets = AvatarAssetStore(accountRef: account.accountRef, runtime: runtime)
        self.blockedUsers = blockedUsers
        self.onboarding = OnboardingCoordinator(accountRef: account.accountRef, runtime: runtime)
        self.historyNotices = HistoryNoticesViewModel(
            accountRef: account.accountRef,
            accountIdHex: account.accountIdHex,
            runtime: runtime
        )
        self.productAnalytics = productAnalytics
    }

    func start(connectivityAvailable: Bool) {
        chatListModel.start()
        attentionModel.start()
        blockedUsers.start()
        onboarding.start()
        historyNotices.start()
        let diagnosticsTask = Task { [settingsModel] in
            await settingsModel.diagnostics.load()
        }
        addCancellation {
            [chatListModel, attentionModel, blockedUsers, onboarding, historyNotices, productAnalytics, settingsModel]
            in
            chatListModel.stop()
            attentionModel.stop()
            blockedUsers.stop()
            onboarding.stop()
            historyNotices.stop()
            productAnalytics.deactivate()
            settingsModel.deactivate()
        }
        own(diagnosticsTask)
        updateConnectivity(available: connectivityAvailable)
    }

    func updateConnectivity(available: Bool) {
        attachmentPolicyTask?.cancel()
        attachmentPolicyTask = Task { [attachmentPolicy] in
            await attachmentPolicy.refresh(connectivityAvailable: available)
        }
    }

    @discardableResult
    func own(_ task: Task<Void, Never>) -> UUID {
        addCancellation { task.cancel() }
    }

    @discardableResult
    func addCancellation(_ cancellation: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        cancellations[id] = cancellation
        return id
    }

    func releaseCancellation(_ id: UUID) {
        cancellations[id] = nil
    }

    /// Conversations open at the live edge (`.latest`). MarmotKit's `.automatic` anchors the
    /// window on the first unread row instead, leaving it detached from the tail; the transcript
    /// has no first-unread position to honor, so it pinned to the foot of that detached window and
    /// long unread conversations opened far above their newest message.
    func conversationModel(
        groupIdHex: String,
        mode: ConversationOpenModeFfi = .latest,
        messageIdHex: String? = nil
    ) -> ConversationViewModel {
        if let existing = conversations[groupIdHex]?.model {
            return existing
        }
        let model = ConversationViewModel(
            account: account,
            groupIdHex: groupIdHex,
            runtime: runtime,
            productAnalytics: productAnalytics
        )
        let cancellation = addCancellation { [model] in model.stop() }
        conversations[groupIdHex] = (model, cancellation)
        model.start(mode: mode, messageIdHex: messageIdHex)
        return model
    }

    @discardableResult
    func selectConversation(
        groupIdHex: String,
        mode: ConversationOpenModeFfi = .latest,
        messageIdHex: String? = nil
    ) -> ConversationViewModel {
        if let selectedConversationModel, selectedConversationModel.groupIdHex == groupIdHex {
            return selectedConversationModel
        }
        let staleGroupIds = conversations.keys.filter { $0 != groupIdHex }
        for existingGroupId in staleGroupIds {
            releaseConversation(groupIdHex: existingGroupId)
        }
        let model = conversationModel(groupIdHex: groupIdHex, mode: mode, messageIdHex: messageIdHex)
        selectedConversationModel = model
        return model
    }

    func releaseSelectedConversation() {
        guard let groupIdHex = selectedConversationModel?.groupIdHex else { return }
        selectedConversationModel = nil
        releaseConversation(groupIdHex: groupIdHex)
    }

    func releaseConversation(groupIdHex: String) {
        guard let owned = conversations.removeValue(forKey: groupIdHex) else { return }
        if selectedConversationModel === owned.model {
            selectedConversationModel = nil
        }
        releaseCancellation(owned.cancellation)
        owned.model.stop()
        releaseAttachments(groupIdHex: groupIdHex)
        groupSafety[groupIdHex] = nil
    }

    func attachmentModel(groupIdHex: String) -> AttachmentViewModel {
        if let existing = attachments[groupIdHex]?.model {
            return existing
        }
        let model = AttachmentViewModel(accountRef: account.accountRef, groupIdHex: groupIdHex, runtime: runtime)
        let cancellation = addCancellation { [model] in model.stopTransferObservation() }
        attachments[groupIdHex] = (model, cancellation)
        return model
    }

    func releaseAttachments(groupIdHex: String) {
        guard let owned = attachments.removeValue(forKey: groupIdHex) else { return }
        releaseCancellation(owned.cancellation)
        owned.model.stopTransferObservation()
    }

    func safetyModel(groupIdHex: String) -> GroupSafetyViewModel {
        if let existing = groupSafety[groupIdHex] { return existing }
        let model = GroupSafetyViewModel(
            accountRef: account.accountRef,
            groupIdHex: groupIdHex,
            runtime: runtime,
            historyNotices: historyNotices
        )
        groupSafety[groupIdHex] = model
        return model
    }

    func cancelAll() async {
        attachmentPolicyTask?.cancel()
        attachmentPolicyTask = nil
        let pending = Array(cancellations.values)
        cancellations.removeAll()
        selectedConversationModel = nil
        conversations.removeAll()
        attachments.removeAll()
        groupSafety.removeAll()
        for cancel in pending {
            cancel()
        }
        await attachmentPolicy.revoke()
    }
}
