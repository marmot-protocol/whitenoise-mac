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
    /// Which groups, and whether the inbox, are still catching up after time offline.
    let recoveryStatus: AccountRecoveryStatusViewModel
    /// Toasts for queued sends MDK dropped once their group settled (`QueuedIntentRefused`).
    let refusedIntents: RefusedIntentNoticesViewModel
    /// Reports to the White Noise team and Block and Report, with their transient feedback.
    let moderationReporter: ModerationReporter
    /// Installed and discoverable sticker packs, and the sticker images this account has loaded.
    let stickers: StickerLibrary
    /// Installed and discoverable NIP-51 emoji sets, whose emoji every chat's picker offers.
    let emojiSets: EmojiSetLibrary
    /// Asks before a group change MDK refused as advisory (`GroupCatchingUp`,
    /// `GroupCommitUndelivered`) is acknowledged and retried.
    let groupChangeAdvisory = GroupChangeAdvisoryPrompter()
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
        relayListsDidChange: @escaping @MainActor () -> Void = {},
        attachmentsDidChange: @escaping @MainActor () async -> Void = {},
        removeAccount: DeleteProfileViewModel.RemoveAccount? = nil
    ) {
        let attachmentPolicy = AttachmentPolicyController(accountRef: account.accountRef, runtime: runtime)
        let blockedUsers = BlockedUsersViewModel(accountRef: account.accountRef, runtime: runtime)
        let productAnalytics = ProductAnalyticsRecorder()
        let chatListModel = ChatListViewModel(
            account: account,
            runtime: runtime,
            blockedUsersModel: blockedUsers
        )
        self.account = account
        self.runtime = runtime
        self.settingsModel = SettingsViewModel(
            account: account,
            runtime: runtime,
            attachmentPolicyController: attachmentPolicy,
            blockedUsersModel: blockedUsers,
            productAnalytics: productAnalytics,
            chatListModel: chatListModel,
            relayListsDidChange: relayListsDidChange,
            attachmentsDidChange: attachmentsDidChange,
            removeAccount: removeAccount
        )
        self.chatListModel = chatListModel
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
        self.recoveryStatus = AccountRecoveryStatusViewModel(
            accountRef: account.accountRef,
            accountIdHex: account.accountIdHex,
            runtime: runtime
        )
        self.refusedIntents = RefusedIntentNoticesViewModel(
            accountIdHex: account.accountIdHex,
            runtime: runtime
        )
        self.productAnalytics = productAnalytics
        self.moderationReporter = ModerationReporter(
            accountRef: account.accountRef,
            accountIdHex: account.accountIdHex,
            runtime: runtime,
            blockedUsers: blockedUsers
        )
        self.stickers = StickerLibrary(accountRef: account.accountRef, runtime: runtime)
        self.emojiSets = EmojiSetLibrary(accountRef: account.accountRef, runtime: runtime)
    }

    func start(connectivityAvailable: Bool) {
        chatListModel.start()
        attentionModel.start()
        blockedUsers.start()
        onboarding.start()
        historyNotices.start()
        recoveryStatus.start()
        refusedIntents.start()
        let diagnosticsTask = Task { [settingsModel] in
            await settingsModel.diagnostics.load()
        }
        addCancellation {
            [
                chatListModel, attentionModel, blockedUsers, onboarding, historyNotices, recoveryStatus,
                refusedIntents, productAnalytics, settingsModel, groupChangeAdvisory, moderationReporter, stickers,
                emojiSets
            ] in
            chatListModel.stop()
            attentionModel.stop()
            blockedUsers.stop()
            onboarding.stop()
            historyNotices.stop()
            recoveryStatus.stop()
            refusedIntents.stop()
            // A pending prompt belongs to this account's change: Wait it out rather than strand it.
            groupChangeAdvisory.cancelPending()
            productAnalytics.deactivate()
            settingsModel.deactivate()
            moderationReporter.stop()
            stickers.stop()
            emojiSets.stop()
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

    /// Conversations open in `.automatic`: MarmotKit anchors the window on the first unread row,
    /// which the transcript positions under a "New messages" divider, else on the latest row.
    func conversationModel(
        groupIdHex: String,
        mode: ConversationOpenModeFfi = .automatic,
        messageIdHex: String? = nil
    ) -> ConversationViewModel {
        if let existing = conversations[groupIdHex]?.model {
            return existing
        }
        let model = ConversationViewModel(
            account: account,
            groupIdHex: groupIdHex,
            runtime: runtime,
            productAnalytics: productAnalytics,
            stickers: stickers,
            emojiSets: emojiSets
        )
        let cancellation = addCancellation { [model] in model.stop() }
        conversations[groupIdHex] = (model, cancellation)
        model.start(mode: mode, messageIdHex: messageIdHex)
        return model
    }

    @discardableResult
    func selectConversation(
        groupIdHex: String,
        mode: ConversationOpenModeFfi = .automatic,
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
            historyNotices: historyNotices,
            moderation: moderationReporter
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
