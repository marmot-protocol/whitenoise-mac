import Foundation
import MarmotKit
import Security

// The project defaults to `@MainActor` isolation, but every MarmotRuntime method is a
// thread-safe bridge into the Rust core. Marking the protocol `nonisolated` lets these
// calls run off the main thread (see FFIExecutor.run) instead of blocking the UI.
nonisolated protocol MarmotRuntime: Sendable {
    var storageRootPath: String { get }

    func start() async throws
    func listAccounts() throws -> [AccountSummaryFfi]
    func npub(accountIdHex: String) -> String?
    func displayName(accountIdHex: String) -> String?
    func userProfile(accountIdHex: String) throws -> UserProfileMetadataFfi?
    func normalizeMemberRef(memberRef: String) throws -> MemberRefFfi
    func refreshProfile(accountIdHex: String, relays: [String]) async throws
    func createIdentityWithProfile(defaultRelays: [String], bootstrapRelays: [String]) async throws
        -> IdentityCreationResultFfi
    func login(identity: String, defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi
    func beginOnboarding(nsec: String, options: OnboardingOptionsFfi) async throws -> OnboardingSnapshotFfi
    func beginExternalSignerOnboarding(
        publicKey: String,
        signer: ExternalAccountSignerFfi,
        options: OnboardingOptionsFfi
    ) async throws -> OnboardingSnapshotFfi
    func publishUserProfile(
        accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]
    ) async throws -> UserProfileMetadataFfi
    func uploadProfileImage(accountRef: String, data: Data, mediaType: String, blossomServer: String?) async throws
        -> String
    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi
    func localAccountKeyPackages(accountRef: String) throws -> [AccountKeyPackageInventoryEntryFfi]
    func refreshAccountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws
        -> [AccountKeyPackageInventoryEntryFfi]
    func accountKeyPackageRelayEvents(accountRef: String, bootstrapRelays: [String]) async throws
        -> [AccountKeyPackageRelayEventFfi]
    func accountFollows(accountRef: String) throws -> [String]
    func isFollowing(accountRef: String, userRef: String) throws -> Bool
    func followUser(accountRef: String, userRef: String) async throws -> [String]
    func unfollowUser(accountRef: String, userRef: String) async throws -> [String]
    func auditLogFiles() throws -> [AuditLogFileFfi]
    func auditLogSettings() throws -> AuditLogSettingsFfi
    func deleteAuditLogFile(path: String) async throws -> AuditLogDeleteResultFfi
    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi
    func postAuditLogTrackerUpdate() async throws -> AuditLogTrackerUpdateResultFfi
    func setAuditLogSettings(settings: AuditLogSettingsFfi) async throws -> AuditLogSettingsFfi
    func setAuditLogTrackerConfig(config: AuditLogTrackerConfigV4Ffi) throws -> AuditLogTrackerConfigV4Ffi
    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi
    func setNativePushEnabled(accountRef: String, enabled: Bool) async throws -> NotificationSettingsFfi
    func setRelayTelemetryRuntimeConfig(config: RelayTelemetryRuntimeConfigFfi) async throws
    func usageDiagnosticsSettings() throws -> UsageDiagnosticsSettingsFfi
    func usageDiagnosticsStatus() throws -> UsageDiagnosticsStatusFfi
    func setUsageDiagnosticsConsent(enabled: Bool) throws -> UsageDiagnosticsSettingsFfi
    func recordHostTiming(
        name: String,
        durationMs: UInt64,
        outcome: HostPerformanceOutcomeFfi
    ) throws -> ProductRecordResultFfi
    func recordProductEvent(event: ProductEventFfi) throws -> ProductRecordResultFfi
    func setProductAnalyticsRuntimeConfig(config: ProductAnalyticsRuntimeConfigFfi) throws
    func setProductAnalyticsActivity(activity: ProductAnalyticsActivityFfi) async throws
    func flushProductAnalytics() async throws
    func accountSetupReadiness(accountRef: String) throws -> AccountSetupReadinessFfi
    func attachmentDownloadPolicy(accountRef: String) async throws -> AttachmentDownloadPolicyFfi
    func setAttachmentDownloadPolicy(accountRef: String, policy: AttachmentDownloadPolicyFfi) async throws
    func beginAttachmentPermissionUpdate(accountRef: String) async throws -> String
    func setAttachmentAutomaticPermission(
        accountRef: String, generation: String, permission: AttachmentAutomaticPermissionFfi
    ) async throws -> Bool
    func attachmentHistoryPage(
        accountRef: String, groupIdHex: String, limit: UInt32, cursor: AttachmentHistoryCursor?
    ) async throws -> AttachmentPageReadFfi
    func attachmentLocalAssets(
        accountRef: String, groupIdHex: String, targets: [AttachmentLocalTargetFfi]
    ) async throws -> [AttachmentLocalAssetFfi]
    func attachmentTransferSnapshot(
        accountRef: String, groupIdHex: String, targets: [AttachmentLocalTargetFfi]
    ) async throws -> AttachmentTransferSnapshotFfi
    func subscribeAttachmentTransfers(
        accountRef: String, groupIdHex: String, targets: [AttachmentLocalTargetFfi]
    ) async throws -> AttachmentTransferSubscription
    func nextAttachmentTransferSnapshot(subscription: AttachmentTransferSubscription) async throws
        -> AttachmentTransferSnapshotFfi?
    func cancelAttachmentTransfers(subscription: AttachmentTransferSubscription)
    func requestAutomaticAttachment(
        accountRef: String, groupIdHex: String, target: AttachmentLocalTargetFfi
    ) async throws -> AutomaticAttachmentRequestFfi
    func downloadAttachmentAgain(
        accountRef: String, groupIdHex: String, target: AttachmentLocalTargetFfi
    ) async throws -> String?
    func controlAttachment(accountRef: String, reference: String, control: AttachmentControlFfi) async throws -> Bool
    func readAttachmentAsset(accountRef: String, reference: String, offset: UInt64, limit: UInt32) async throws
        -> AttachmentLocalBytesFfi
    func requestAvatarAssets(accountRef: String, targets: [String]) async throws -> [AvatarAssetFfi]
    func readAvatarAssets(accountRef: String, references: [String], maxBytes: UInt64) async throws -> [AvatarBytesFfi]
    func clearAvatarCache(accountRef: String) async throws
    func getBlockedUsers(accountRef: String) throws -> [BlockedUserFfi]
    func subscribeBlockedUsers(accountRef: String) throws -> BlockListSubscription
    func blockedUsersSnapshot(subscription: BlockListSubscription) -> BlockListSnapshotFfi?
    func nextBlockedUsersSnapshot(subscription: BlockListSubscription) async throws -> BlockListSnapshotFfi?
    func blockUser(accountRef: String, userAccountIdHex: String) async throws
    func unblockUser(accountRef: String, userAccountIdHex: String) async throws
    func quarantinedGroups(accountRef: String) async throws -> [AppQuarantinedGroupFfi]
    func retryHydrateQuarantinedGroup(accountRef: String, groupIdHex: String) async throws -> Bool
    func groupRecoveryStatus(accountRef: String, groupIdHex: String) async throws -> GroupRecoveryStatusFfi
    func confirmGroupRejoin(
        accountRef: String, welcomeIdHex: String, localStateToken: String
    ) async throws -> GroupRecoveryStatusFfi
    func declineGroupRejoin(accountRef: String, welcomeIdHex: String) async throws
    func reportMessage(
        accountRef: String,
        groupIdHex: String,
        messageId: String,
        reason: ReportReasonFfi,
        explanation: String
    ) async throws -> SendSummaryFfi
    func contentReports(
        accountRef: String, groupIdHex: String, messageId: String?, after: String?, limit: UInt32
    ) throws -> ContentReportPageFfi
    func dismissReports(
        accountRef: String, groupIdHex: String, reportIds: [String], explanation: String
    ) async throws -> SendSummaryFfi
    func reportedMessage(accountRef: String, groupIdHex: String, messageId: String) throws
        -> TimelineMessageRecordFfi?
    func forgetGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool
    func openAgentPublisher(
        accountRef: String, groupIdHex: String, options: PublisherOptionsFfi
    ) async throws -> AgentTextPublisher
    func onboardingRecoveryRequired(accountRef: String) throws -> Bool
    func onboardingSnapshot(accountRef: String) throws -> OnboardingSnapshotFfi?
    func subscribeOnboarding(accountRef: String) throws -> OnboardingSubscription
    func onboardingSubscriptionSnapshot(subscription: OnboardingSubscription) -> OnboardingSnapshotFfi
    func nextOnboardingSnapshot(subscription: OnboardingSubscription) async throws -> OnboardingSnapshotFfi?
    func runOnboarding(accountRef: String) async throws -> OnboardingSnapshotFfi
    func retryOnboardingStep(accountRef: String, step: OnboardingStepFfi) async throws -> OnboardingSnapshotFfi
    func continueOnboardingWithout(accountRef: String, step: OnboardingStepFfi) async throws -> OnboardingSnapshotFfi
    func approveOnboardingRepair(accountRef: String, revision: UInt64) async throws -> OnboardingSnapshotFfi
    func acknowledgeOnboardingSingleDevice(accountRef: String, revision: UInt64) async throws -> OnboardingSnapshotFfi
    func cancelOnboardingRepair(accountRef: String) async throws -> OnboardingSnapshotFfi
    func cancelOnboarding(accountRef: String) async throws
    func recoverOnboarding(accountRef: String, acknowledgeLatestOnlyEvidence: Bool) async throws -> String
    func proposeOnboardingProfile(accountRef: String, profile: UserProfileMetadataFfi) async throws
        -> OnboardingSnapshotFfi
    func proposeOnboardingFollows(accountRef: String, follows: [String]) async throws -> OnboardingSnapshotFfi
    func proposeOnboardingRelays(
        accountRef: String,
        step: OnboardingStepFfi,
        readRelays: [String],
        writeRelays: [String]
    ) async throws -> OnboardingSnapshotFfi
    func proposeOnboardingRecommendedRelays(accountRef: String, step: OnboardingStepFfi) async throws
        -> OnboardingSnapshotFfi
    func setOnboardingDiscoveryRelays(accountRef: String, discoveryRelays: [String]) async throws
        -> OnboardingSnapshotFfi
    func deleteAllLocalData() async throws
    func removeAccount(accountRef: String) async throws
    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws
        -> String
    func acceptGroupInvite(accountRef: String, groupIdHex: String) async throws -> AppGroupRecordFfi
    func declineGroupInvite(accountRef: String, groupIdHex: String) async throws -> GroupInviteDeclineResultFfi
    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi
    func groupManagementState(accountRef: String, groupIdHex: String) async throws -> GroupManagementStateFfi
    func inviteMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    func leaveGroup(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi
    func promoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    func demoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    func removeMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    func selfDemoteAdminDetailed(accountRef: String, groupIdHex: String) async throws -> GroupMutationResultFfi
    func setGroupArchived(accountRef: String, groupIdHex: String, archived: Bool) async throws -> AppGroupRecordFfi
    func updateGroupAvatarUrl(accountRef: String, groupIdHex: String, url: String?, dim: String?, thumbhash: String?)
        async throws -> SendSummaryFfi
    func updateGroupImage(accountRef: String, groupIdHex: String, plaintext: Data, mediaType: String) async throws
        -> SendSummaryFfi
    func clearGroupImage(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi
    func downloadGroupBlossomImage(accountRef: String, groupIdHex: String) async throws -> Data
    func updateGroupProfile(accountRef: String, groupIdHex: String, name: String?, description: String?) async throws
        -> SendSummaryFfi
    func openChatListWindow(accountRef: String, view: ChatListViewFfi, initialRows: UInt32?) async throws
        -> ChatListWindowSubscription
    func chatListWindowSnapshot(subscription: ChatListWindowSubscription) -> ChatListWindowSnapshotFfi?
    func nextChatListWindowSnapshot(subscription: ChatListWindowSubscription) async throws -> ChatListWindowSnapshotFfi?
    func openPresentedChatList(accountRef: String, includeArchived: Bool) async throws
        -> PresentedChatListSubscription
    func presentedChatListSubscriptionSnapshot(subscription: PresentedChatListSubscription)
        -> PresentedChatListUpdateFfi?
    func nextPresentedChatListUpdate(subscription: PresentedChatListSubscription) async throws
        -> PresentedChatListUpdateFfi?
    func presentedChatList(accountRef: String, includeArchived: Bool) async throws -> PresentedChatListSnapshotFfi
    func presentedChatListRow(accountRef: String, groupIdHex: String) async throws -> PresentedChatRowFfi?
    /// One-shot read of an account's chat-list projection.
    func chatList(accountRef: String, includeArchived: Bool) throws -> [ChatListRowFfi]
    func subscribeNotifications() async throws -> NotificationsSubscription
    /// The one MarmotRuntime call that is not a local DB read: it traverses the searcher's web of
    /// trust over relays and streams matches as each radius resolves. Note the parameter is an
    /// `accountIdHex`, not the `accountRef` every neighbouring call takes.
    func searchUsers(accountIdHex: String, query: String, radiusStart: UInt8, radiusEnd: UInt8) async throws
        -> UserSearchSubscription
    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi
    func messageEditHistory(
        accountRef: String,
        groupIdHex: String,
        targetMessageIdHex: String,
        beforeEditedAt: UInt64?,
        beforeMessageIdHex: String?,
        limit: UInt32
    ) throws -> TimelineEditHistoryPageFfi
    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws
        -> TimelineMessagesSubscription
    func openConversationWindow(
        accountRef: String,
        groupIdHex: String,
        mode: ConversationOpenModeFfi,
        messageIdHex: String?,
        initialRows: UInt32?,
        timeoutMs: UInt32
    ) async throws -> ConversationWindowSubscription
    func conversationWindowSnapshot(subscription: ConversationWindowSubscription) -> ConversationWindowSnapshotFfi?
    func nextConversationWindowSnapshot(subscription: ConversationWindowSubscription) async throws
        -> ConversationWindowSnapshotFfi?
    func cancelConversationWindow(subscription: ConversationWindowSubscription) async
    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi?
    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi?
    func messageDrafts(accountRef: String) throws -> [MessageDraftSummaryFfi]
    func messageDraft(accountRef: String, groupIdHex: String) throws -> MessageDraftFfi?
    func selectedMessageDraft(accountRef: String, groupIdHex: String) throws -> SelectedMessageDraftFfi
    func messageDraftAttachmentIfRevision(
        accountRef: String,
        revision: MessageDraftRevisionFfi,
        attachmentId: String
    ) throws -> Data?
    func saveMessageDraftIfRevision(
        accountRef: String,
        revision: MessageDraftRevisionFfi,
        content: String,
        replyToMessageIdHex: String?,
        mediaAttachments: [MessageDraftAttachmentFfi]
    ) throws -> SelectedMessageDraftFfi
    func clearMessageDraftIfRevision(accountRef: String, revision: MessageDraftRevisionFfi) throws
        -> SelectedMessageDraftFfi
    func listMedia(accountRef: String, groupIdHex: String, limit: UInt32?) throws -> [MediaRecordFfi]
    func downloadMedia(accountRef: String, groupIdHex: String, reference: MediaAttachmentReferenceFfi) async throws
        -> MediaDownloadResultFfi
    func uploadMedia(accountRef: String, groupIdHex: String, request: MediaUploadRequestFfi) async throws
        -> MediaUploadResultFfi
    func uploadMediaWithClientToken(
        accountRef: String,
        groupIdHex: String,
        request: MediaUploadRequestFfi,
        clientToken: String
    ) async throws -> MediaUploadSubmissionFfi
    func sendTextWithClientToken(accountRef: String, groupIdHex: String, text: String, clientToken: String) async throws
        -> LocalSendAcceptanceFfi
    func replyToMessageWithClientToken(
        accountRef: String,
        groupIdHex: String,
        targetMessageId: String,
        text: String,
        clientToken: String
    ) async throws -> LocalSendAcceptanceFfi
    func sendMessageDraftWithClientToken(
        accountRef: String,
        revision: MessageDraftRevisionFfi,
        attachments: [MediaAttachmentReferenceFfi],
        clientToken: String
    ) async throws -> LocalSendAcceptanceFfi
    func localSendStatus(accountRef: String, groupIdHex: String, clientToken: String) throws -> LocalSendStatusFfi?
    func retryGroupConvergence(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi
    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws
        -> SendSummaryFfi
    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi
    func editMessage(accountRef: String, groupIdHex: String, targetMessageId: String, content: String) async throws
        -> SendSummaryFfi
    func parseMarkdown(text: String) -> MarkdownDocumentFfi
    func subscribeAccountAttention() async throws -> AccountAttentionSubscription
    func accountAttentionSnapshot(subscription: AccountAttentionSubscription) -> AccountAttentionSnapshotFfi?
    func nextAccountAttentionSnapshot(subscription: AccountAttentionSubscription) async throws
        -> AccountAttentionSnapshotFfi?
    func signOut(accountRef: String, deleteKeyPackages: Bool) async throws -> SignOutOutcomeFfi
    func signInAccount(accountRef: String) async throws -> AccountSummaryFfi
    func revealNsec(accountRef: String) throws -> String
    func exportEncryptedSecretKey(accountRef: String, passphrase: String) throws -> String
    func deleteGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool
    func updateMessageRetention(accountRef: String, groupIdHex: String, disappearingMessageSecs: UInt64) async throws
        -> SendSummaryFfi
    func secureDeleteExpired(accountRef: String, groupIdHex: String) async throws -> SecureDeleteExpiredResultFfi
    func sweepExpiredRetention(accountRef: String, nowMs: UInt64) async throws -> RetentionSweepReportFfi
    func setChatManuallyUnread(accountRef: String, groupIdHex: String, manuallyUnread: Bool) throws -> ChatListRowFfi?
    func chatNotificationSettings(accountRef: String, groupIdHex: String) throws -> ChatNotificationSettingsFfi
    func setChatMuted(accountRef: String, groupIdHex: String, mutedUntilMs: Int64?) throws
        -> ChatNotificationSettingsFfi
    func clearChatMuted(accountRef: String, groupIdHex: String) throws -> ChatNotificationSettingsFfi
    func recordHostPerformance(
        operation: HostPerformanceOperationFfi,
        durationMs: UInt64,
        outcome: HostPerformanceOutcomeFfi
    )
}

// `marmot` is a UniFFI handle whose Rust object is internally Send + Sync, and all
// stored properties are immutable, so MarmotClient is safe to share across threads.
nonisolated final class MarmotClient: MarmotRuntime, @unchecked Sendable {
    static let seedRelays: [String] = [
        "wss://relay.eu.whitenoise.chat",
        "wss://relay.us.whitenoise.chat",
    ]

    let marmot: Marmot
    let rootPath: String
    var storageRootPath: String { rootPath }

    convenience init() throws {
        try self.init(rootPath: MarmotStorageRoot.resolve(), relayUrls: Self.seedRelays)
    }

    static func defaultStorageRootPath() -> String {
        MarmotStorageRoot.expectedPath()
    }

    init(
        rootPath: String,
        relayUrls: [String],
        cursorPersistence: CursorPersistenceFfi = .advance
    ) throws {
        self.rootPath = rootPath
        self.marmot = try Marmot.newWithConfiguration(
            rootPath: rootPath,
            relayUrls: relayUrls,
            options: MarmotOptions(
                cursorPersistence: cursorPersistence,
                clientName: "whitenoise",
                attachmentAcquisitionMode: .hostManaged
            )
        )
    }

    func start() async throws {
        try await marmot.start()
    }

    func listAccounts() throws -> [AccountSummaryFfi] {
        try marmot.listAccounts()
    }

    func npub(accountIdHex: String) -> String? {
        marmot.npub(accountIdHex: accountIdHex)
    }

    func displayName(accountIdHex: String) -> String? {
        marmot.displayName(accountIdHex: accountIdHex)
    }

    func userProfile(accountIdHex: String) throws -> UserProfileMetadataFfi? {
        try marmot.userProfile(accountIdHex: accountIdHex)
    }

    func normalizeMemberRef(memberRef: String) throws -> MemberRefFfi {
        try marmot.normalizeMemberRef(memberRef: memberRef)
    }

    func refreshProfile(accountIdHex: String, relays: [String]) async throws {
        try await marmot.refreshProfile(accountIdHex: accountIdHex, relays: relays)
    }

    func createIdentityWithProfile(defaultRelays: [String], bootstrapRelays: [String]) async throws
        -> IdentityCreationResultFfi
    {
        try await marmot.createIdentityWithProfile(defaultRelays: defaultRelays, bootstrapRelays: bootstrapRelays)
    }

    func login(identity: String, defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        try await marmot.login(identity: identity, defaultRelays: defaultRelays, bootstrapRelays: bootstrapRelays)
    }

    func beginOnboarding(nsec: String, options: OnboardingOptionsFfi) async throws -> OnboardingSnapshotFfi {
        try await marmot.beginOnboarding(nsec: nsec, options: options)
    }

    func beginExternalSignerOnboarding(
        publicKey: String,
        signer: ExternalAccountSignerFfi,
        options: OnboardingOptionsFfi
    ) async throws -> OnboardingSnapshotFfi {
        try await marmot.beginExternalSignerOnboarding(publicKey: publicKey, signer: signer, options: options)
    }

    func publishUserProfile(
        accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]
    ) async throws -> UserProfileMetadataFfi {
        try await marmot.publishUserProfile(
            accountRef: accountRef,
            profile: profile,
            defaultRelays: defaultRelays,
            bootstrapRelays: bootstrapRelays
        )
    }

    func uploadProfileImage(accountRef: String, data: Data, mediaType: String, blossomServer: String?) async throws
        -> String
    {
        try await marmot.uploadProfileImage(
            accountRef: accountRef,
            data: data,
            mediaType: mediaType,
            blossomServer: blossomServer
        )
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        try marmot.accountRelayLists(accountRef: accountRef)
    }

    func localAccountKeyPackages(accountRef: String) throws -> [AccountKeyPackageInventoryEntryFfi] {
        try marmot.localAccountKeyPackages(accountRef: accountRef)
    }

    func refreshAccountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws
        -> [AccountKeyPackageInventoryEntryFfi]
    {
        try await marmot.refreshAccountKeyPackages(accountRef: accountRef, bootstrapRelays: bootstrapRelays)
    }

    func accountKeyPackageRelayEvents(accountRef: String, bootstrapRelays: [String]) async throws
        -> [AccountKeyPackageRelayEventFfi]
    {
        try await marmot.accountKeyPackageRelayEvents(accountRef: accountRef, bootstrapRelays: bootstrapRelays)
    }

    func accountFollows(accountRef: String) throws -> [String] {
        try marmot.accountFollows(accountRef: accountRef)
    }

    func isFollowing(accountRef: String, userRef: String) throws -> Bool {
        try marmot.isFollowing(accountRef: accountRef, userRef: userRef)
    }

    func followUser(accountRef: String, userRef: String) async throws -> [String] {
        try await marmot.followUser(accountRef: accountRef, userRef: userRef)
    }

    func unfollowUser(accountRef: String, userRef: String) async throws -> [String] {
        try await marmot.unfollowUser(accountRef: accountRef, userRef: userRef)
    }

    func auditLogFiles() throws -> [AuditLogFileFfi] {
        try marmot.auditLogFiles()
    }

    func auditLogSettings() throws -> AuditLogSettingsFfi {
        try marmot.auditLogSettings()
    }

    func deleteAuditLogFile(path: String) async throws -> AuditLogDeleteResultFfi {
        try await marmot.deleteAuditLogFile(path: path)
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        try marmot.notificationSettings(accountRef: accountRef)
    }

    func postAuditLogTrackerUpdate() async throws -> AuditLogTrackerUpdateResultFfi {
        try await marmot.postAuditLogTrackerUpdate()
    }

    func setAuditLogSettings(settings: AuditLogSettingsFfi) async throws -> AuditLogSettingsFfi {
        try await marmot.setAuditLogSettings(settings: settings)
    }

    func setAuditLogTrackerConfig(config: AuditLogTrackerConfigV4Ffi) throws -> AuditLogTrackerConfigV4Ffi {
        try marmot.setAuditLogTrackerConfig(config: config)
    }

    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi {
        try marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: enabled)
    }

    func setNativePushEnabled(accountRef: String, enabled: Bool) async throws -> NotificationSettingsFfi {
        try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
    }

    func setRelayTelemetryRuntimeConfig(config: RelayTelemetryRuntimeConfigFfi) async throws {
        try await marmot.setRelayTelemetryRuntimeConfig(config: config)
    }

    func usageDiagnosticsSettings() throws -> UsageDiagnosticsSettingsFfi {
        try marmot.usageDiagnosticsSettings()
    }

    func usageDiagnosticsStatus() throws -> UsageDiagnosticsStatusFfi {
        try marmot.usageDiagnosticsStatus()
    }

    func setUsageDiagnosticsConsent(enabled: Bool) throws -> UsageDiagnosticsSettingsFfi {
        try marmot.setUsageDiagnosticsConsent(enabled: enabled)
    }

    func recordHostTiming(
        name: String,
        durationMs: UInt64,
        outcome: HostPerformanceOutcomeFfi
    ) throws -> ProductRecordResultFfi {
        try marmot.recordHostTiming(name: name, durationMs: durationMs, outcome: outcome)
    }

    func recordProductEvent(event: ProductEventFfi) throws -> ProductRecordResultFfi {
        try marmot.recordProductEvent(event: event)
    }

    func setProductAnalyticsRuntimeConfig(config: ProductAnalyticsRuntimeConfigFfi) throws {
        try marmot.setProductAnalyticsRuntimeConfig(config: config)
    }

    func setProductAnalyticsActivity(activity: ProductAnalyticsActivityFfi) async throws {
        try await marmot.setProductAnalyticsActivity(activity: activity)
    }

    func flushProductAnalytics() async throws {
        try await marmot.flushProductAnalytics()
    }

    func accountSetupReadiness(accountRef: String) throws -> AccountSetupReadinessFfi {
        try marmot.accountSetupReadiness(accountRef: accountRef)
    }

    func attachmentDownloadPolicy(accountRef: String) async throws -> AttachmentDownloadPolicyFfi {
        try await marmot.attachmentDownloadPolicy(accountRef: accountRef)
    }

    func setAttachmentDownloadPolicy(accountRef: String, policy: AttachmentDownloadPolicyFfi) async throws {
        try await marmot.setAttachmentDownloadPolicy(accountRef: accountRef, policy: policy)
    }

    func beginAttachmentPermissionUpdate(accountRef: String) async throws -> String {
        try await marmot.beginAttachmentPermissionUpdate(accountRef: accountRef)
    }

    func setAttachmentAutomaticPermission(
        accountRef: String, generation: String, permission: AttachmentAutomaticPermissionFfi
    ) async throws -> Bool {
        try await marmot.setAttachmentAutomaticPermission(
            accountRef: accountRef, generation: generation, permission: permission
        )
    }

    func attachmentHistoryPage(
        accountRef: String, groupIdHex: String, limit: UInt32, cursor: AttachmentHistoryCursor?
    ) async throws -> AttachmentPageReadFfi {
        try await marmot.attachmentHistoryPage(
            accountRef: accountRef, groupIdHex: groupIdHex, limit: limit, cursor: cursor
        )
    }

    func attachmentLocalAssets(
        accountRef: String, groupIdHex: String, targets: [AttachmentLocalTargetFfi]
    ) async throws -> [AttachmentLocalAssetFfi] {
        try await marmot.attachmentLocalAssets(accountRef: accountRef, groupIdHex: groupIdHex, targets: targets)
    }

    func attachmentTransferSnapshot(
        accountRef: String, groupIdHex: String, targets: [AttachmentLocalTargetFfi]
    ) async throws -> AttachmentTransferSnapshotFfi {
        try await marmot.attachmentTransferSnapshot(accountRef: accountRef, groupIdHex: groupIdHex, targets: targets)
    }

    func subscribeAttachmentTransfers(
        accountRef: String, groupIdHex: String, targets: [AttachmentLocalTargetFfi]
    ) async throws -> AttachmentTransferSubscription {
        try await marmot.subscribeAttachmentTransfers(accountRef: accountRef, groupIdHex: groupIdHex, targets: targets)
    }

    func nextAttachmentTransferSnapshot(subscription: AttachmentTransferSubscription) async throws
        -> AttachmentTransferSnapshotFfi?
    {
        try await subscription.nextCancellable()
    }

    func cancelAttachmentTransfers(subscription: AttachmentTransferSubscription) {
        subscription.cancel()
    }

    func requestAutomaticAttachment(
        accountRef: String, groupIdHex: String, target: AttachmentLocalTargetFfi
    ) async throws -> AutomaticAttachmentRequestFfi {
        try await marmot.requestAutomaticAttachment(accountRef: accountRef, groupIdHex: groupIdHex, target: target)
    }

    func downloadAttachmentAgain(
        accountRef: String, groupIdHex: String, target: AttachmentLocalTargetFfi
    ) async throws -> String? {
        try await marmot.downloadAttachmentAgain(accountRef: accountRef, groupIdHex: groupIdHex, target: target)
    }

    func controlAttachment(accountRef: String, reference: String, control: AttachmentControlFfi) async throws -> Bool {
        try await marmot.controlAttachment(accountRef: accountRef, reference: reference, control: control)
    }

    func readAttachmentAsset(accountRef: String, reference: String, offset: UInt64, limit: UInt32) async throws
        -> AttachmentLocalBytesFfi
    {
        try await marmot.readAttachmentAsset(accountRef: accountRef, reference: reference, offset: offset, limit: limit)
    }

    func requestAvatarAssets(accountRef: String, targets: [String]) async throws -> [AvatarAssetFfi] {
        try await marmot.requestAvatarAssets(accountRef: accountRef, targets: targets)
    }

    func readAvatarAssets(accountRef: String, references: [String], maxBytes: UInt64) async throws -> [AvatarBytesFfi] {
        try await marmot.readAvatarAssets(accountRef: accountRef, references: references, maxBytes: maxBytes)
    }

    func clearAvatarCache(accountRef: String) async throws {
        try await marmot.clearAvatarCache(accountRef: accountRef)
    }

    func getBlockedUsers(accountRef: String) throws -> [BlockedUserFfi] {
        try marmot.getBlockedUsers(accountRef: accountRef)
    }

    func subscribeBlockedUsers(accountRef: String) throws -> BlockListSubscription {
        try marmot.subscribeBlockedUsers(accountRef: accountRef)
    }

    func blockedUsersSnapshot(subscription: BlockListSubscription) -> BlockListSnapshotFfi? {
        subscription.snapshot()
    }

    func nextBlockedUsersSnapshot(subscription: BlockListSubscription) async throws -> BlockListSnapshotFfi? {
        try await subscription.nextCancellable()
    }

    func blockUser(accountRef: String, userAccountIdHex: String) async throws {
        try await marmot.blockUser(accountRef: accountRef, userAccountIdHex: userAccountIdHex)
    }

    func unblockUser(accountRef: String, userAccountIdHex: String) async throws {
        try await marmot.unblockUser(accountRef: accountRef, userAccountIdHex: userAccountIdHex)
    }

    func quarantinedGroups(accountRef: String) async throws -> [AppQuarantinedGroupFfi] {
        try await marmot.quarantinedGroups(accountRef: accountRef)
    }

    func retryHydrateQuarantinedGroup(accountRef: String, groupIdHex: String) async throws -> Bool {
        try await marmot.retryHydrateQuarantinedGroup(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupRecoveryStatus(accountRef: String, groupIdHex: String) async throws -> GroupRecoveryStatusFfi {
        try await marmot.groupRecoveryStatus(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func confirmGroupRejoin(
        accountRef: String, welcomeIdHex: String, localStateToken: String
    ) async throws -> GroupRecoveryStatusFfi {
        try await marmot.confirmGroupRejoin(
            accountRef: accountRef, welcomeIdHex: welcomeIdHex, localStateToken: localStateToken
        )
    }

    func declineGroupRejoin(accountRef: String, welcomeIdHex: String) async throws {
        try await marmot.declineGroupRejoin(accountRef: accountRef, welcomeIdHex: welcomeIdHex)
    }

    func reportMessage(
        accountRef: String,
        groupIdHex: String,
        messageId: String,
        reason: ReportReasonFfi,
        explanation: String
    ) async throws -> SendSummaryFfi {
        try await marmot.reportMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            messageId: messageId,
            reason: reason,
            explanation: explanation
        )
    }

    func contentReports(
        accountRef: String, groupIdHex: String, messageId: String?, after: String?, limit: UInt32
    ) throws -> ContentReportPageFfi {
        try marmot.contentReports(
            accountRef: accountRef, groupIdHex: groupIdHex, messageId: messageId, after: after, limit: limit
        )
    }

    func dismissReports(
        accountRef: String, groupIdHex: String, reportIds: [String], explanation: String
    ) async throws -> SendSummaryFfi {
        try await marmot.dismissReports(
            accountRef: accountRef, groupIdHex: groupIdHex, reportIds: reportIds, explanation: explanation
        )
    }

    func reportedMessage(accountRef: String, groupIdHex: String, messageId: String) throws
        -> TimelineMessageRecordFfi?
    {
        try marmot.reportedMessage(accountRef: accountRef, groupIdHex: groupIdHex, messageId: messageId)
    }

    func forgetGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool {
        try await marmot.forgetGroupLocal(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func openAgentPublisher(
        accountRef: String, groupIdHex: String, options: PublisherOptionsFfi
    ) async throws -> AgentTextPublisher {
        try await marmot.openAgentPublisher(accountRef: accountRef, groupIdHex: groupIdHex, options: options)
    }

    func onboardingRecoveryRequired(accountRef: String) throws -> Bool {
        try marmot.onboardingRecoveryRequired(accountRef: accountRef)
    }

    func onboardingSnapshot(accountRef: String) throws -> OnboardingSnapshotFfi? {
        try marmot.onboardingSnapshot(accountRef: accountRef)
    }

    func subscribeOnboarding(accountRef: String) throws -> OnboardingSubscription {
        try marmot.subscribeOnboarding(accountRef: accountRef)
    }

    func onboardingSubscriptionSnapshot(subscription: OnboardingSubscription) -> OnboardingSnapshotFfi {
        subscription.snapshot()
    }

    func nextOnboardingSnapshot(subscription: OnboardingSubscription) async throws -> OnboardingSnapshotFfi? {
        try await subscription.nextCancellable()
    }

    func runOnboarding(accountRef: String) async throws -> OnboardingSnapshotFfi {
        try await marmot.runOnboarding(accountRef: accountRef)
    }

    func retryOnboardingStep(accountRef: String, step: OnboardingStepFfi) async throws -> OnboardingSnapshotFfi {
        try await marmot.retryOnboardingStep(accountRef: accountRef, step: step)
    }

    func continueOnboardingWithout(accountRef: String, step: OnboardingStepFfi) async throws -> OnboardingSnapshotFfi {
        try await marmot.continueOnboardingWithout(accountRef: accountRef, step: step)
    }

    func approveOnboardingRepair(accountRef: String, revision: UInt64) async throws -> OnboardingSnapshotFfi {
        try await marmot.approveOnboardingRepair(accountRef: accountRef, revision: revision)
    }

    func acknowledgeOnboardingSingleDevice(accountRef: String, revision: UInt64) async throws
        -> OnboardingSnapshotFfi
    {
        try await marmot.acknowledgeOnboardingSingleDevice(accountRef: accountRef, revision: revision)
    }

    func cancelOnboardingRepair(accountRef: String) async throws -> OnboardingSnapshotFfi {
        try await marmot.cancelOnboardingRepair(accountRef: accountRef)
    }

    func cancelOnboarding(accountRef: String) async throws {
        try await marmot.cancelOnboarding(accountRef: accountRef)
    }

    func recoverOnboarding(accountRef: String, acknowledgeLatestOnlyEvidence: Bool) async throws -> String {
        try await marmot.recoverOnboarding(
            accountRef: accountRef, acknowledgeLatestOnlyEvidence: acknowledgeLatestOnlyEvidence
        )
    }

    func proposeOnboardingProfile(accountRef: String, profile: UserProfileMetadataFfi) async throws
        -> OnboardingSnapshotFfi
    {
        try await marmot.proposeOnboardingProfile(accountRef: accountRef, profile: profile)
    }

    func proposeOnboardingFollows(accountRef: String, follows: [String]) async throws -> OnboardingSnapshotFfi {
        try await marmot.proposeOnboardingFollows(accountRef: accountRef, follows: follows)
    }

    func proposeOnboardingRelays(
        accountRef: String,
        step: OnboardingStepFfi,
        readRelays: [String],
        writeRelays: [String]
    ) async throws -> OnboardingSnapshotFfi {
        try await marmot.proposeOnboardingRelays(
            accountRef: accountRef, step: step, readRelays: readRelays, writeRelays: writeRelays
        )
    }

    func proposeOnboardingRecommendedRelays(accountRef: String, step: OnboardingStepFfi) async throws
        -> OnboardingSnapshotFfi
    {
        try await marmot.proposeOnboardingRecommendedRelays(accountRef: accountRef, step: step)
    }

    func setOnboardingDiscoveryRelays(accountRef: String, discoveryRelays: [String]) async throws
        -> OnboardingSnapshotFfi
    {
        try await marmot.setOnboardingDiscoveryRelays(
            accountRef: accountRef,
            discoveryRelays: discoveryRelays
        )
    }

    func deleteAllLocalData() async throws {
        try await Self.deleteAllLocalData(
            shutdown: { await marmot.shutdown() },
            rootPath: rootPath
        )
    }

    static func deleteAllLocalData(
        purgeAccountKeychain: () throws -> Void = MarmotAccountKeychain.purgeAllAccountKeys,
        shutdown: () async -> Void,
        rootPath: String,
        fileManager: FileManager = .default
    ) async throws {
        try purgeAccountKeychain()
        await shutdown()

        do {
            if fileManager.fileExists(atPath: rootPath) {
                try fileManager.removeItem(atPath: rootPath)
            }
            try fileManager.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        } catch {
            // Keychain credentials are already gone and the runtime has already shut down. Mark
            // the error so callers never attempt to revive this invalidated client.
            throw MarmotLocalDataDeletionError.runtimeInvalidated(underlying: error)
        }
    }

    func removeAccount(accountRef: String) async throws {
        try await marmot.removeAccount(accountRef: accountRef)
    }

    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    {
        try await marmot.setAccountInboxRelays(
            accountRef: accountRef,
            relays: relays,
            bootstrapRelays: bootstrapRelays
        )
    }

    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    {
        try await marmot.setAccountNip65Relays(
            accountRef: accountRef,
            relays: relays,
            bootstrapRelays: bootstrapRelays
        )
    }

    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws
        -> String
    {
        try await marmot.createGroup(
            accountRef: accountRef,
            name: name,
            memberRefs: memberRefs,
            description: description
        )
    }

    func acceptGroupInvite(accountRef: String, groupIdHex: String) async throws -> AppGroupRecordFfi {
        try await marmot.acceptGroupInvite(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func declineGroupInvite(accountRef: String, groupIdHex: String) async throws -> GroupInviteDeclineResultFfi {
        try await marmot.declineGroupInvite(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi {
        try await marmot.groupDetails(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupManagementState(accountRef: String, groupIdHex: String) async throws -> GroupManagementStateFfi {
        try await marmot.groupManagementState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func inviteMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    {
        try await marmot.inviteMembersDetailed(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            memberRefs: memberRefs
        )
    }

    func leaveGroup(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.leaveGroup(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func promoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    {
        try await marmot.promoteAdminDetailed(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            memberRef: memberRef
        )
    }

    func demoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    {
        try await marmot.demoteAdminDetailed(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            memberRef: memberRef
        )
    }

    func removeMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    {
        try await marmot.removeMembersDetailed(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            memberRefs: memberRefs
        )
    }

    func selfDemoteAdminDetailed(accountRef: String, groupIdHex: String) async throws -> GroupMutationResultFfi {
        try await marmot.selfDemoteAdminDetailed(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func setGroupArchived(accountRef: String, groupIdHex: String, archived: Bool) async throws -> AppGroupRecordFfi {
        try await marmot.setGroupArchived(accountRef: accountRef, groupIdHex: groupIdHex, archived: archived)
    }

    func updateGroupAvatarUrl(accountRef: String, groupIdHex: String, url: String?, dim: String?, thumbhash: String?)
        async throws -> SendSummaryFfi
    {
        try await marmot.updateGroupAvatarUrl(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            url: url,
            dim: dim,
            thumbhash: thumbhash
        )
    }

    func updateGroupImage(accountRef: String, groupIdHex: String, plaintext: Data, mediaType: String) async throws
        -> SendSummaryFfi
    {
        try await marmot.updateGroupImage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            plaintext: plaintext,
            mediaType: mediaType
        )
    }

    func clearGroupImage(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.clearGroupImage(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func downloadGroupBlossomImage(accountRef: String, groupIdHex: String) async throws -> Data {
        try await marmot.downloadGroupBlossomImage(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func updateGroupProfile(accountRef: String, groupIdHex: String, name: String?, description: String?) async throws
        -> SendSummaryFfi
    {
        try await marmot.updateGroupProfile(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            name: name,
            description: description
        )
    }

    func openChatListWindow(accountRef: String, view: ChatListViewFfi, initialRows: UInt32?) async throws
        -> ChatListWindowSubscription
    {
        try await marmot.openChatListWindow(accountRef: accountRef, view: view, initialRows: initialRows)
    }

    func chatListWindowSnapshot(subscription: ChatListWindowSubscription) -> ChatListWindowSnapshotFfi? {
        subscription.snapshot()
    }

    func nextChatListWindowSnapshot(subscription: ChatListWindowSubscription) async throws
        -> ChatListWindowSnapshotFfi?
    {
        try await subscription.nextCancellable()
    }

    func openPresentedChatList(accountRef: String, includeArchived: Bool) async throws
        -> PresentedChatListSubscription
    {
        try await marmot.openPresentedChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func presentedChatListSubscriptionSnapshot(subscription: PresentedChatListSubscription)
        -> PresentedChatListUpdateFfi?
    {
        subscription.snapshot()
    }

    func nextPresentedChatListUpdate(subscription: PresentedChatListSubscription) async throws
        -> PresentedChatListUpdateFfi?
    {
        try await subscription.nextCancellable()
    }

    func presentedChatList(accountRef: String, includeArchived: Bool) async throws -> PresentedChatListSnapshotFfi {
        try await marmot.presentedChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func presentedChatListRow(accountRef: String, groupIdHex: String) async throws -> PresentedChatRowFfi? {
        try await marmot.presentedChatListRow(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func chatList(accountRef: String, includeArchived: Bool) throws -> [ChatListRowFfi] {
        try marmot.chatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func subscribeNotifications() async throws -> NotificationsSubscription {
        try await marmot.subscribeNotifications()
    }

    func searchUsers(accountIdHex: String, query: String, radiusStart: UInt8, radiusEnd: UInt8) async throws
        -> UserSearchSubscription
    {
        try await marmot.searchUsers(
            accountIdHex: accountIdHex,
            query: query,
            radiusStart: radiusStart,
            radiusEnd: radiusEnd
        )
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        try marmot.timelineMessages(accountRef: accountRef, query: query)
    }

    func messageEditHistory(
        accountRef: String,
        groupIdHex: String,
        targetMessageIdHex: String,
        beforeEditedAt: UInt64?,
        beforeMessageIdHex: String?,
        limit: UInt32
    ) throws -> TimelineEditHistoryPageFfi {
        try marmot.messageEditHistory(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageIdHex: targetMessageIdHex,
            beforeEditedAt: beforeEditedAt,
            beforeMessageIdHex: beforeMessageIdHex,
            limit: limit
        )
    }

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws
        -> TimelineMessagesSubscription
    {
        try await marmot.subscribeTimelineMessages(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            limit: limit
        )
    }

    func openConversationWindow(
        accountRef: String,
        groupIdHex: String,
        mode: ConversationOpenModeFfi,
        messageIdHex: String?,
        initialRows: UInt32?,
        timeoutMs: UInt32
    ) async throws -> ConversationWindowSubscription {
        try await marmot.openConversationWindow(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            mode: mode,
            messageIdHex: messageIdHex,
            initialRows: initialRows,
            timeoutMs: timeoutMs
        )
    }

    func conversationWindowSnapshot(subscription: ConversationWindowSubscription) -> ConversationWindowSnapshotFfi? {
        subscription.snapshot()
    }

    func nextConversationWindowSnapshot(subscription: ConversationWindowSubscription) async throws
        -> ConversationWindowSnapshotFfi?
    {
        try await subscription.nextCancellable()
    }

    func cancelConversationWindow(subscription: ConversationWindowSubscription) async {
        await subscription.cancel()
    }

    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi? {
        try marmot.initializeChatReadState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi?
    {
        try marmot.markTimelineMessageRead(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            messageIdHex: messageIdHex
        )
    }

    func messageDrafts(accountRef: String) throws -> [MessageDraftSummaryFfi] {
        try marmot.messageDrafts(accountRef: accountRef)
    }

    func messageDraft(accountRef: String, groupIdHex: String) throws -> MessageDraftFfi? {
        try marmot.messageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func selectedMessageDraft(accountRef: String, groupIdHex: String) throws -> SelectedMessageDraftFfi {
        try marmot.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func messageDraftAttachmentIfRevision(
        accountRef: String,
        revision: MessageDraftRevisionFfi,
        attachmentId: String
    ) throws -> Data? {
        try marmot.messageDraftAttachmentIfRevision(
            accountRef: accountRef,
            revision: revision,
            attachmentId: attachmentId
        )
    }

    func saveMessageDraftIfRevision(
        accountRef: String,
        revision: MessageDraftRevisionFfi,
        content: String,
        replyToMessageIdHex: String?,
        mediaAttachments: [MessageDraftAttachmentFfi]
    ) throws -> SelectedMessageDraftFfi {
        try marmot.saveMessageDraftIfRevision(
            accountRef: accountRef,
            revision: revision,
            content: content,
            replyToMessageIdHex: replyToMessageIdHex,
            mediaAttachments: mediaAttachments
        )
    }

    func clearMessageDraftIfRevision(accountRef: String, revision: MessageDraftRevisionFfi) throws
        -> SelectedMessageDraftFfi
    {
        try marmot.clearMessageDraftIfRevision(accountRef: accountRef, revision: revision)
    }

    func listMedia(accountRef: String, groupIdHex: String, limit: UInt32?) throws -> [MediaRecordFfi] {
        try marmot.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: limit)
    }

    func downloadMedia(accountRef: String, groupIdHex: String, reference: MediaAttachmentReferenceFfi) async throws
        -> MediaDownloadResultFfi
    {
        try await marmot.downloadMedia(accountRef: accountRef, groupIdHex: groupIdHex, reference: reference)
    }

    func uploadMedia(accountRef: String, groupIdHex: String, request: MediaUploadRequestFfi) async throws
        -> MediaUploadResultFfi
    {
        try await marmot.uploadMedia(accountRef: accountRef, groupIdHex: groupIdHex, request: request)
    }

    func uploadMediaWithClientToken(
        accountRef: String,
        groupIdHex: String,
        request: MediaUploadRequestFfi,
        clientToken: String
    ) async throws -> MediaUploadSubmissionFfi {
        try await marmot.uploadMediaWithClientToken(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            request: request,
            clientToken: clientToken
        )
    }

    func sendTextWithClientToken(accountRef: String, groupIdHex: String, text: String, clientToken: String) async throws
        -> LocalSendAcceptanceFfi
    {
        try await marmot.sendTextWithClientToken(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            text: text,
            clientToken: clientToken
        )
    }

    func replyToMessageWithClientToken(
        accountRef: String,
        groupIdHex: String,
        targetMessageId: String,
        text: String,
        clientToken: String
    ) async throws -> LocalSendAcceptanceFfi {
        try await marmot.replyToMessageWithClientToken(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageId,
            text: text,
            clientToken: clientToken
        )
    }

    func sendMessageDraftWithClientToken(
        accountRef: String,
        revision: MessageDraftRevisionFfi,
        attachments: [MediaAttachmentReferenceFfi],
        clientToken: String
    ) async throws -> LocalSendAcceptanceFfi {
        try await marmot.sendMessageDraftWithClientToken(
            accountRef: accountRef,
            revision: revision,
            attachments: attachments,
            clientToken: clientToken
        )
    }

    func localSendStatus(accountRef: String, groupIdHex: String, clientToken: String) throws -> LocalSendStatusFfi? {
        try marmot.localSendStatus(accountRef: accountRef, groupIdHex: groupIdHex, clientToken: clientToken)
    }

    func retryGroupConvergence(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.retryGroupConvergence(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws
        -> SendSummaryFfi
    {
        try await marmot.reactToMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageId,
            emoji: emoji
        )
    }

    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        try await marmot.deleteMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageId
        )
    }

    func editMessage(accountRef: String, groupIdHex: String, targetMessageId: String, content: String) async throws
        -> SendSummaryFfi
    {
        try await marmot.editMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageId,
            content: content
        )
    }

    func parseMarkdown(text: String) -> MarkdownDocumentFfi {
        marmot.parseMarkdown(text: text)
    }

    func subscribeAccountAttention() async throws -> AccountAttentionSubscription {
        try await marmot.subscribeAccountAttention()
    }

    func accountAttentionSnapshot(subscription: AccountAttentionSubscription) -> AccountAttentionSnapshotFfi? {
        subscription.snapshot()
    }

    func nextAccountAttentionSnapshot(subscription: AccountAttentionSubscription) async throws
        -> AccountAttentionSnapshotFfi?
    {
        try await subscription.nextCancellable()
    }

    func signOut(accountRef: String, deleteKeyPackages: Bool) async throws -> SignOutOutcomeFfi {
        try await marmot.signOut(accountRef: accountRef, deleteKeyPackages: deleteKeyPackages)
    }

    func signInAccount(accountRef: String) async throws -> AccountSummaryFfi {
        try await marmot.signInAccount(accountRef: accountRef)
    }

    func revealNsec(accountRef: String) throws -> String {
        try marmot.revealNsec(accountRef: accountRef)
    }

    func exportEncryptedSecretKey(accountRef: String, passphrase: String) throws -> String {
        try marmot.exportEncryptedSecretKey(accountRef: accountRef, passphrase: passphrase)
    }

    func deleteGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool {
        try await marmot.deleteGroupLocal(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func updateMessageRetention(accountRef: String, groupIdHex: String, disappearingMessageSecs: UInt64) async throws
        -> SendSummaryFfi
    {
        try await marmot.updateMessageRetention(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            disappearingMessageSecs: disappearingMessageSecs
        )
    }

    func secureDeleteExpired(accountRef: String, groupIdHex: String) async throws -> SecureDeleteExpiredResultFfi {
        try await marmot.secureDeleteExpired(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func sweepExpiredRetention(accountRef: String, nowMs: UInt64) async throws -> RetentionSweepReportFfi {
        try await marmot.sweepExpiredRetention(accountRef: accountRef, nowMs: nowMs)
    }

    func setChatManuallyUnread(accountRef: String, groupIdHex: String, manuallyUnread: Bool) throws -> ChatListRowFfi? {
        try marmot.setChatManuallyUnread(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            manuallyUnread: manuallyUnread
        )
    }

    func chatNotificationSettings(accountRef: String, groupIdHex: String) throws -> ChatNotificationSettingsFfi {
        try marmot.chatNotificationSettings(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func setChatMuted(accountRef: String, groupIdHex: String, mutedUntilMs: Int64?) throws
        -> ChatNotificationSettingsFfi
    {
        try marmot.setChatMuted(accountRef: accountRef, groupIdHex: groupIdHex, mutedUntilMs: mutedUntilMs)
    }

    func clearChatMuted(accountRef: String, groupIdHex: String) throws -> ChatNotificationSettingsFfi {
        try marmot.clearChatMuted(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func recordHostPerformance(
        operation: HostPerformanceOperationFfi,
        durationMs: UInt64,
        outcome: HostPerformanceOutcomeFfi
    ) {
        marmot.recordHostPerformance(operation: operation, durationMs: durationMs, outcome: outcome)
    }
}

nonisolated enum MarmotLocalDataDeletionError: LocalizedError {
    case runtimeInvalidated(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .runtimeInvalidated(let error):
            error.localizedDescription
        }
    }
}

nonisolated enum MarmotAccountKeychainPurgeError: LocalizedError, Equatable {
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deleteFailed(let status):
            return String(
                format: L10n.string("Unable to delete Marmot account keys from Keychain (%@)."), String(status))
        }
    }
}

nonisolated enum MarmotAccountKeychain {
    private static let service = "com.marmot.whitenoise"

    static func purgeAllAccountKeys() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MarmotAccountKeychainPurgeError.deleteFailed(status)
        }
    }
}

enum MarmotStorageRootError: LocalizedError {
    case applicationSupportUnavailable(Error)
    case createDirectoryFailed(path: String, underlying: Error)
    case rootIsNotDirectory(path: String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable(let error):
            return String(
                format: L10n.string(
                    "Unable to resolve a durable Application Support directory for Marmot storage: %@"),
                error.localizedDescription)
        case .createDirectoryFailed(let path, let error):
            return String(
                format: L10n.string("Unable to create durable Marmot storage directory at %@: %@"), path,
                error.localizedDescription)
        case .rootIsNotDirectory(let path):
            return String(
                format: L10n.string("Marmot storage path exists but is not a directory: %@"), path)
        }
    }
}

nonisolated enum MarmotStorageRoot {
    private static let appSupportDirectoryName = "White Noise"
    private static let marmotDirectoryName = "Marmot"

    static func resolve(
        fileManager: FileManager = .default,
        applicationSupportDirectory: (FileManager) throws -> URL = { fileManager in
            try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    ) throws -> String {
        let base: URL
        do {
            base = try applicationSupportDirectory(fileManager)
        } catch {
            throw MarmotStorageRootError.applicationSupportUnavailable(error)
        }

        return try resolve(baseURL: base, fileManager: fileManager)
    }

    static func resolve(baseURL: URL, fileManager: FileManager = .default) throws -> String {
        let root = storageRootURL(baseURL: baseURL)
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MarmotStorageRootError.rootIsNotDirectory(path: root.path)
            }
            return root.path
        }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw MarmotStorageRootError.createDirectoryFailed(path: root.path, underlying: error)
        }

        return root.path
    }

    // Best-effort display label used before bootstrap; resolve() is the authoritative path.
    static func expectedPath(fileManager: FileManager = .default) -> String {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return L10n.string("Application Support unavailable")
        }
        return storageRootURL(baseURL: base).path
    }

    private static func storageRootURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(marmotDirectoryName, isDirectory: true)
    }
}
