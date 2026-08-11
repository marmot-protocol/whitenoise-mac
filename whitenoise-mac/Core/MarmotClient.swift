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
    func createIdentity(defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi
    func login(identity: String, defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi
    func publishUserProfile(
        accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]
    ) async throws -> UserProfileMetadataFfi
    func uploadProfileImage(accountRef: String, data: Data, mediaType: String, blossomServer: String?) async throws
        -> String
    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi
    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi]
    func accountFollows(accountRef: String) throws -> [String]
    func isFollowing(accountRef: String, userRef: String) throws -> Bool
    func followUser(accountRef: String, userRef: String) async throws -> [String]
    func unfollowUser(accountRef: String, userRef: String) async throws -> [String]
    func auditLogFiles() throws -> [AuditLogFileFfi]
    func auditLogSettings() throws -> AuditLogSettingsFfi
    func deleteAuditLogFile(path: String) async throws -> AuditLogDeleteResultFfi
    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi
    func postAuditLogTrackerUpdate() async throws -> AuditLogTrackerUpdateResultFfi
    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi
    func setAuditLogSettings(settings: AuditLogSettingsFfi) async throws -> AuditLogSettingsFfi
    func setAuditLogTrackerConfig(config: AuditLogTrackerConfigFfi) throws -> AuditLogTrackerConfigFfi
    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi
    func setRelayTelemetryRuntimeConfig(config: RelayTelemetryRuntimeConfigFfi) async throws
    func setRelayTelemetrySettings(settings: RelayTelemetrySettingsFfi) async throws -> RelayTelemetrySettingsFfi
    func telemetryInstallId() throws -> String
    func deleteAllLocalData() async throws
    func removeAccount(accountRef: String) async throws
    func publishNewKeyPackage(accountRef: String) async throws -> UInt64
    func republishKeyPackage(accountRef: String) async throws -> UInt64
    func deleteAccountKeyPackage(accountRef: String, eventIdHex: String, relays: [String]) async throws -> UInt64
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
    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription
    func subscribeNotifications() async throws -> NotificationsSubscription
    /// The one MarmotRuntime call that is not a local DB read: it traverses the searcher's web of
    /// trust over relays and streams matches as each radius resolves. Note the parameter is an
    /// `accountIdHex`, not the `accountRef` every neighbouring call takes.
    func searchUsers(accountIdHex: String, query: String, radiusStart: UInt8, radiusEnd: UInt8) async throws
        -> UserSearchSubscription
    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi
    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws
        -> TimelineMessagesSubscription
    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi?
    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi?
    func messageDrafts(accountRef: String) throws -> [MessageDraftSummaryFfi]
    func messageDraft(accountRef: String, groupIdHex: String) throws -> MessageDraftFfi?
    func saveMessageDraft(
        accountRef: String,
        groupIdHex: String,
        content: String,
        replyToMessageIdHex: String?,
        mediaAttachments: [MessageDraftAttachmentFfi]
    ) throws -> MessageDraftFfi
    func deleteMessageDraft(accountRef: String, groupIdHex: String) throws
    func listMedia(accountRef: String, groupIdHex: String, limit: UInt32?) throws -> [MediaRecordFfi]
    func downloadMedia(accountRef: String, groupIdHex: String, reference: MediaAttachmentReferenceFfi) async throws
        -> MediaDownloadResultFfi
    func uploadMedia(accountRef: String, groupIdHex: String, request: MediaUploadRequestFfi) async throws
        -> MediaUploadResultFfi
    func sendMediaAttachments(
        accountRef: String,
        groupIdHex: String,
        attachments: [MediaAttachmentReferenceFfi],
        caption: String?
    ) async throws -> SendSummaryFfi
    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi
    func retryGroupConvergence(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi
    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws
        -> SendSummaryFfi
    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws
        -> SendSummaryFfi
    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi
    func editMessage(accountRef: String, groupIdHex: String, targetMessageId: String, content: String) async throws
        -> SendSummaryFfi
    func parseMarkdown(text: String) -> MarkdownDocumentFfi
    func accountUnreadSummary() throws -> [AccountUnreadFfi]
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

    init(rootPath: String, relayUrls: [String]) throws {
        self.rootPath = rootPath
        self.marmot = try Marmot(rootPath: rootPath, relayUrls: relayUrls)
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

    func createIdentity(defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        try await marmot.createIdentity(defaultRelays: defaultRelays, bootstrapRelays: bootstrapRelays)
    }

    func login(identity: String, defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        try await marmot.login(identity: identity, defaultRelays: defaultRelays, bootstrapRelays: bootstrapRelays)
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

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        try await marmot.accountKeyPackages(accountRef: accountRef, bootstrapRelays: bootstrapRelays)
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

    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi {
        try marmot.relayTelemetrySettings()
    }

    func setAuditLogSettings(settings: AuditLogSettingsFfi) async throws -> AuditLogSettingsFfi {
        try await marmot.setAuditLogSettings(settings: settings)
    }

    func setAuditLogTrackerConfig(config: AuditLogTrackerConfigFfi) throws -> AuditLogTrackerConfigFfi {
        try marmot.setAuditLogTrackerConfig(config: config)
    }

    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi {
        try marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: enabled)
    }

    func setRelayTelemetryRuntimeConfig(config: RelayTelemetryRuntimeConfigFfi) async throws {
        try await marmot.setRelayTelemetryRuntimeConfig(config: config)
    }

    func setRelayTelemetrySettings(settings: RelayTelemetrySettingsFfi) async throws -> RelayTelemetrySettingsFfi {
        try await marmot.setRelayTelemetrySettings(settings: settings)
    }

    func telemetryInstallId() throws -> String {
        try marmot.telemetryInstallId()
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

    func publishNewKeyPackage(accountRef: String) async throws -> UInt64 {
        try await marmot.publishNewKeyPackage(accountRef: accountRef)
    }

    func republishKeyPackage(accountRef: String) async throws -> UInt64 {
        try await marmot.republishKeyPackage(accountRef: accountRef)
    }

    func deleteAccountKeyPackage(accountRef: String, eventIdHex: String, relays: [String]) async throws -> UInt64 {
        try await marmot.deleteAccountKeyPackage(
            accountRef: accountRef,
            eventIdHex: eventIdHex,
            relays: relays
        )
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

    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription {
        try await marmot.subscribeChatList(accountRef: accountRef, includeArchived: includeArchived)
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

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws
        -> TimelineMessagesSubscription
    {
        try await marmot.subscribeTimelineMessages(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            limit: limit
        )
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

    func saveMessageDraft(
        accountRef: String,
        groupIdHex: String,
        content: String,
        replyToMessageIdHex: String?,
        mediaAttachments: [MessageDraftAttachmentFfi]
    ) throws -> MessageDraftFfi {
        try marmot.saveMessageDraft(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            content: content,
            replyToMessageIdHex: replyToMessageIdHex,
            mediaAttachments: mediaAttachments
        )
    }

    func deleteMessageDraft(accountRef: String, groupIdHex: String) throws {
        try marmot.deleteMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
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

    func sendMediaAttachments(
        accountRef: String,
        groupIdHex: String,
        attachments: [MediaAttachmentReferenceFfi],
        caption: String?
    ) async throws -> SendSummaryFfi {
        try await marmot.sendMediaAttachments(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            attachments: attachments,
            caption: caption
        )
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        try await marmot.sendText(accountRef: accountRef, groupIdHex: groupIdHex, text: text)
    }

    func retryGroupConvergence(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.retryGroupConvergence(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws
        -> SendSummaryFfi
    {
        try await marmot.replyToMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageId,
            text: text
        )
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

    func accountUnreadSummary() throws -> [AccountUnreadFfi] {
        try marmot.accountUnreadSummary()
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
