import AppKit
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

struct TimelinePagingState: Equatable {
    var hasMoreBefore: Bool
    var hasMoreAfter: Bool
    var isLoadingBefore: Bool
    var isLoadingAfter: Bool

    static let empty = TimelinePagingState(
        hasMoreBefore: false,
        hasMoreAfter: false,
        isLoadingBefore: false,
        isLoadingAfter: false
    )
}

/// Tracks ownership of incremental, per-row chat-list enrichment tasks (issue #40).
///
/// Single-row chat-list updates spawn one enrichment `Task` per group. Exactly one such task
/// should "own" a group's slot at a time: a newer update must supersede (coalesce) an in-flight
/// one, listener teardown / account switch must cancel them all, and a finishing task must
/// release its slot only if it is still the current owner.
///
/// Ownership is keyed by a process-monotonic token that is **never reused** — not even after
/// `cancelAll()` clears the maps on reload / account switch. That is the crux of the fix: a
/// per-group counter that reset to its first value on clear would let a stale, already-canceled
/// task match a *future* task's reused token and erroneously drop the future task's slot,
/// reintroducing the untracked / uncancellable enrichment work this is meant to prevent.
struct ChatListRowEnrichmentTracker {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: Int] = [:]
    private var nextToken: Int = 0

    /// Number of currently tracked (live) tasks. Diagnostic / test helper.
    var trackedTaskCount: Int { tasks.count }

    /// The current ownership token for `group`, if any. Diagnostic / test helper.
    func currentToken(forGroup group: String) -> Int? { tokens[group] }

    /// Allocates a globally unique, never-reused ownership token for `group` and cancels any
    /// task currently owning it. Call before spawning the replacement task.
    mutating func beginTask(forGroup group: String) -> Int {
        tasks[group]?.cancel()
        nextToken += 1
        let token = nextToken
        tokens[group] = token
        return token
    }

    /// Records `task` as the owner of `group` for `token`. If `token` is no longer current
    /// (a newer `beginTask` has since run for this group) the late registration is ignored and
    /// the task canceled, so it cannot clobber a newer owner.
    mutating func register(task: Task<Void, Never>, forGroup group: String, token: Int) {
        guard tokens[group] == token else {
            task.cancel()
            return
        }
        tasks[group] = task
    }

    /// Releases `group`'s slot iff `token` is still the current owner. A stale token (from an
    /// older, already-superseded or canceled task) is a no-op, so it can never drop a newer task.
    mutating func finishTask(forGroup group: String, token: Int) {
        guard tokens[group] == token else { return }
        tasks[group] = nil
        tokens[group] = nil
    }

    /// Cancels every tracked task and clears all ownership state. The token sequence is
    /// deliberately **not** reset, so tokens issued after this call stay unique with respect to
    /// any still-unwinding canceled task.
    mutating func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        tokens.removeAll()
    }
}

@MainActor
@Observable
final class WorkspaceState {
    enum Phase: Equatable {
        case bootstrapping
        case onboarding
        case ready
        case failed(String)
    }

    enum AuthenticationMode: Equatable {
        case landing
        case login
    }

    private struct ComposerDraftKey: Hashable {
        let accountId: String
        let chatId: String
    }

    private(set) var phase: Phase = .bootstrapping
    private(set) var accounts: [AccountItem]
    private(set) var chatsByAccount: [String: [ChatItem]]
    private(set) var messagesByChat: [String: [MessageItem]]
    /// Error for the user-initiated action on the *current* screen. Rendered by form
    /// surfaces (login, settings, new-chat composer). Must never be written by
    /// background tasks — see `backgroundStatus`.
    private(set) var lastError: String?
    /// Status for failures originating in background tasks (subscription listeners,
    /// observability refresh, read-marking). These are not tied to anything the user
    /// just did, so they are surfaced on a non-modal global banner instead of the
    /// per-screen error view, preventing misattribution and clobbering of `lastError`.
    private(set) var backgroundStatus: String?

    var activeAccountId: String?
    var selection: WorkspaceSelection? {
        didSet { dismissGroupImagePickerIfSelectedChatUnavailable() }
    }
    var searchText = ""
    var isChatListVisible = true
    var draftText: String {
        get {
            guard let selectedComposerDraftKey else { return "" }
            return draftTextByConversation[selectedComposerDraftKey] ?? ""
        }
        set {
            guard let selectedComposerDraftKey else { return }
            if newValue.isEmpty {
                draftTextByConversation[selectedComposerDraftKey] = nil
            } else {
                draftTextByConversation[selectedComposerDraftKey] = newValue
            }
        }
    }
    var isRefreshing = false
    var isSending = false
    var authenticationMode: AuthenticationMode = .landing
    var loginIdentity = ""
    var isAuthenticating = false
    var profileDraft = ProfileDraft()
    var relaySettings = RelaySettingsSnapshot.defaults
    var selectedRelaySection: RelaySettingsSection = .nip65
    var relayDraft = MarmotClient.seedRelays
    var newRelayURL = ""
    var keyPackages: [KeyPackageItem] = []
    var notificationSettings = NotificationSettingsSnapshot.defaults
    var notificationAuthorizationStatus: LocalNotificationAuthorizationStatus = .notDetermined
    var privacySecuritySettings = PrivacySecuritySettingsSnapshot.defaults
    var auditLogFiles: [AuditLogFileFfi] = []
    var auditLogUploadStatus: String?
    var developerMode: Bool {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: Self.developerModeKey)
        }
    }
    var streamingDebugMode: Bool {
        didSet {
            UserDefaults.standard.set(streamingDebugMode, forKey: Self.streamingDebugModeKey)
        }
    }
    var streamingDebugEnabled: Bool {
        developerMode && streamingDebugMode
    }
    var appearancePreference: AppearancePreference {
        didSet {
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: Self.appearancePreferenceKey)
        }
    }
    var notificationPreviewMode: NotificationPreviewMode {
        didSet {
            UserDefaults.standard.set(notificationPreviewMode.rawValue, forKey: Self.notificationPreviewModeKey)
        }
    }
    var languagePreference: AppLanguage {
        didSet {
            UserDefaults.standard.set(languagePreference.rawValue, forKey: AppLanguage.storageKey)
            AppLanguage.refreshCachedLocale()
        }
    }
    var isLoadingSettings = false
    var isSavingProfile = false
    var isRemovingAccount = false
    var isSavingRelays = false
    var isPublishingKeyPackage = false
    var isRepublishingKeyPackage = false
    var isSavingNotifications = false
    var isSavingPrivacySecurity = false
    var isLoadingAuditLogFiles = false
    var isDeletingAuditLogFiles = false
    var isUploadingAuditLogFiles = false
    var isDeletingAllData = false
    var deletingKeyPackageId: String?
    var isNewChatComposerVisible = false
    var newChatQuery = ""
    var newChatName = ""
    var newChatDescription = ""
    var newChatRecipient: NewChatRecipient?
    var replyDraftContext: MessageReplyContext? {
        get {
            guard let selectedComposerDraftKey else { return nil }
            return replyDraftContextByConversation[selectedComposerDraftKey]
        }
        set {
            guard let selectedComposerDraftKey else { return }
            replyDraftContextByConversation[selectedComposerDraftKey] = newValue
        }
    }
    var isResolvingNewChat = false
    var isCreatingChat = false
    var isGroupImagePickerPresented = false
    var groupImageSearchQuery = ""
    var groupImageResults: [GroupImageSearchResult] = []
    var isSearchingGroupImages = false
    var isSavingGroupImage = false
    var isGroupDetailsPresented = false
    var groupDetailsSnapshot: GroupDetailsSnapshot?
    var groupProfileDraftName = ""
    var groupProfileDraftDescription = ""
    var groupInviteMemberQuery = ""
    var isLoadingGroupDetails = false
    var isSavingGroupProfile = false
    var isInvitingGroupMember = false
    var isArchivingGroup = false
    var isLeavingGroup = false
    var isExportingGroupTranscript = false
    var groupTranscriptExportStatus: String?
    var mutatingGroupMemberId: String?
    private(set) var storageRootPath = MarmotClient.defaultStorageRootPath()
    private(set) var timelinePagingByChat: [String: TimelinePagingState] = [:]
    private(set) var timelineInitialLoadGroupId: String?
    private var draftTextByConversation: [ComposerDraftKey: String] = [:]
    private var replyDraftContextByConversation: [ComposerDraftKey: MessageReplyContext] = [:]

    private var selectedComposerDraftKey: ComposerDraftKey? {
        guard let activeAccountId, case .chat(let chatId) = selection else { return nil }
        return ComposerDraftKey(accountId: activeAccountId, chatId: chatId)
    }

    private func clearAllComposerDrafts() {
        draftTextByConversation.removeAll()
        replyDraftContextByConversation.removeAll()
    }

    private func clearComposerDrafts(for chatIds: [String], accountId: String) {
        for chatId in chatIds {
            let key = ComposerDraftKey(accountId: accountId, chatId: chatId)
            draftTextByConversation[key] = nil
            replyDraftContextByConversation[key] = nil
        }
    }

    private func clearComposerDrafts(forAccountId accountId: String) {
        for key in draftTextByConversation.keys.filter({ $0.accountId == accountId }) {
            draftTextByConversation[key] = nil
        }
        for key in replyDraftContextByConversation.keys.filter({ $0.accountId == accountId }) {
            replyDraftContextByConversation[key] = nil
        }
    }

    private let clientFactory: @MainActor () throws -> any MarmotRuntime
    private let localNotificationCenter: any LocalNotificationCenter
    private let appActivityProvider: @MainActor () -> Bool
    private let conversationWindowVisibilityProvider: @MainActor () -> Bool
    private let copyTextHandler: @MainActor (String) -> Void
    private let telemetryBuildConfigProvider: @MainActor () -> TelemetryBuildConfig
    private let groupImageSearchClient: any GroupImageSearchClient
    private var client: (any MarmotRuntime)?
    private var hasStartedRuntime = false
    private var notificationTask: Task<Void, Never>?
    private var chatListTask: Task<Void, Never>?
    private var chatListTaskAccountId: String?
    private var chatListEnrichmentTask: Task<Void, Never>?
    /// Incremental, per-row chat-list enrichment task ownership (issue #40). Single-row updates
    /// (the chat-list subscription delta path) spawn one enrichment task per group; this tracker
    /// lets `stopChatListListener` cancel them on listener teardown / account switch and lets a
    /// newer update for the same group supersede (coalesce) an in-flight one. Ownership tokens
    /// are process-monotonic and never reused, so a stale canceled task can never match a future
    /// task's token and drop its tracking slot. See `ChatListRowEnrichmentTracker`.
    private var chatListRowEnrichment = ChatListRowEnrichmentTracker()
    private var timelineTask: Task<Void, Never>?
    private var timelineTaskGroupId: String?
    /// The live timeline subscription for the open conversation. It owns the
    /// authoritative, bounded, materialized window; scroll-back/forward pagination and
    /// live updates all flow through it (`paginateBackwards` / `paginateForwards` / `next`).
    /// Kept alive for pagination independent of the listener task (which may finish if the
    /// live stream ends), and cleared only when the conversation is torn down.
    private var activeTimelineSubscription: TimelineMessagesSubscription?
    private var activeTimelineGroupId: String?
    private var messageLookupByChat: [String: [String: MessageItem]] = [:]
    /// Cached per-chat message id arrays, materialized once per `messagesByChat`
    /// mutation and maintained in lockstep with it (alongside `messageLookupByChat`).
    /// SwiftUI re-evaluates `body` frequently; reading this cache avoids rebuilding a
    /// fresh `[String]` on every access. Invalidated/recomputed only when the
    /// underlying messages change.
    private var messageIDsByChat: [String: [String]] = [:]
    private var lastMarkedReadMarkers: [String: ReadMarker] = [:]
    private var deliveredNotificationKeys = Set<String>()
    private var deliveredNotificationKeyOrder: [String] = []
    private var newChatLookupGeneration = 0
    /// Raw per-sender FFI lookups (userProfile + directory displayName), cached so that
    /// scrolling back through history does not re-resolve the same senders from Rust on
    /// every page. Keyed by sender accountIdHex; invalidated when a peer profile refreshes.
    private var peerProfileFFICache: [String: ResolvedPeerFFI] = [:]

    private static let activeAccountKey = "whitenoise.mac.activeAccountId"
    private static let developerModeKey = "whitenoise.mac.developerMode"
    private static let streamingDebugModeKey = "whitenoise.mac.streamingDebugMode"
    private static let appearancePreferenceKey = "whitenoise.mac.appearancePreference"
    private static let notificationPreviewModeKey = "whitenoise.mac.notificationPreviewMode"
    private static let deliveredNotificationKeyLimit = 256
    private static let timelinePageLimit: UInt32 = 100

    /// Dedicated queue for blocking MarmotRuntime FFI calls. The Rust core runs
    /// synchronously (DB reads, MLS decryption); WorkspaceState is `@MainActor`, so
    /// calling these directly freezes the UI. We hop them onto this queue and await the
    /// result on the main actor. UniFFI objects are internally thread-safe.
    nonisolated private static let ffiQueue = DispatchQueue(
        label: "chat.whitenoise.marmot-ffi",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Cached raw output of the per-sender profile FFI lookups.
    struct ResolvedPeerFFI: Sendable {
        var profileDisplayName: String?
        var profileName: String?
        var profilePicture: String?
        var directoryDisplayName: String?
    }

    /// Runs a blocking FFI closure off the main thread and resumes on the caller's actor.
    nonisolated private func runOffMain<T>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Self.ffiQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
    private static var notificationPermissionGuidance: String {
        L10n.string("Open System Settings > Notifications and allow White Noise notifications, then try again.")
    }
    init(
        accounts: [AccountItem] = [],
        chatsByAccount: [String: [ChatItem]] = [:],
        messagesByChat: [String: [MessageItem]] = [:],
        localNotificationCenter: (any LocalNotificationCenter)? = nil,
        appActivityProvider: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
        conversationWindowVisibilityProvider: @escaping @MainActor () -> Bool = {
            WorkspaceState.defaultConversationWindowVisibilityProvider()
        },
        copyTextHandler: @escaping @MainActor (String) -> Void = WorkspaceState.copyToGeneralPasteboard,
        telemetryBuildConfigProvider: @escaping @MainActor () -> TelemetryBuildConfig = { TelemetryBuildConfig.current() },
        groupImageSearchClient: (any GroupImageSearchClient)? = nil,
        clientFactory: @escaping @MainActor () throws -> any MarmotRuntime = { try MarmotClient() }
    ) {
        self.accounts = accounts
        self.chatsByAccount = chatsByAccount
        self.messagesByChat = messagesByChat
        self.messageLookupByChat = messagesByChat.mapValues { messages in
            Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        }
        self.messageIDsByChat = messagesByChat.mapValues { $0.map(\.id) }
        self.localNotificationCenter = localNotificationCenter ?? MacLocalNotificationCenter()
        self.appActivityProvider = appActivityProvider
        self.conversationWindowVisibilityProvider = conversationWindowVisibilityProvider
        self.copyTextHandler = copyTextHandler
        self.telemetryBuildConfigProvider = telemetryBuildConfigProvider
        self.groupImageSearchClient = groupImageSearchClient ?? OpenverseGroupImageSearchClient()
        self.clientFactory = clientFactory
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.streamingDebugMode = UserDefaults.standard.bool(forKey: Self.streamingDebugModeKey)
        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearancePreferenceKey)
        self.appearancePreference = storedAppearance.flatMap(AppearancePreference.init(rawValue:)) ?? .system
        let storedPreviewMode = UserDefaults.standard.string(forKey: Self.notificationPreviewModeKey)
        self.notificationPreviewMode = storedPreviewMode.flatMap(NotificationPreviewMode.init(rawValue:)) ?? .full
        let storedLanguage = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        self.languagePreference = AppLanguage.resolved(rawValue: storedLanguage)
        self.activeAccountId = UserDefaults.standard.string(forKey: Self.activeAccountKey)
            ?? accounts.first?.id
        if let firstChat = activeChats.first {
            self.selection = .chat(firstChat.id)
        }
        if !accounts.isEmpty {
            self.phase = .ready
        }
        self.localNotificationCenter.setResponseHandler { [weak self] userInfo in
            self?.handleNotificationResponse(userInfo)
        }
    }

    private static func defaultConversationWindowVisibilityProvider() -> Bool {
        guard let keyWindow = NSApplication.shared.keyWindow else { return false }
        return keyWindow.isVisible && !keyWindow.isMiniaturized
    }

    private func selectedConversationIsVisible() -> Bool {
        appActivityProvider() && conversationWindowVisibilityProvider()
    }

    static func preview() -> WorkspaceState {
        WorkspaceState(
            accounts: AccountItem.samples,
            chatsByAccount: [
                AccountItem.samples[0].id: ChatItem.samples,
                AccountItem.samples[1].id: Array(ChatItem.samples.dropFirst()),
                AccountItem.samples[2].id: [ChatItem.samples[2]]
            ],
            messagesByChat: MessageItem.samples,
            clientFactory: { throw PreviewRuntimeError() }
        )
    }

    var activeAccount: AccountItem? {
        guard let activeAccountId else { return nil }
        return accounts.first { $0.id == activeAccountId }
    }

    var activeChats: [ChatItem] {
        guard let activeAccountId else { return [] }
        return chatsByAccount[activeAccountId] ?? []
    }

    var filteredChats: [ChatItem] {
        ChatFilter.filtered(activeChats, query: searchText)
    }

    var selectedChat: ChatItem? {
        guard case .chat(let chatId) = selection else { return nil }
        return activeChats.first { $0.id == chatId }
    }

    var resolvedNewChatRecipient: NewChatRecipient? {
        guard let newChatRecipient,
              newChatRecipient.matches(query: newChatQuery)
        else { return nil }

        return newChatRecipient
    }

    var selectedMessages: [MessageItem] {
        guard let selectedChat else { return [] }
        return messagesByChat[selectedChat.id] ?? []
    }

    var selectedMessageIDs: [String] {
        guard let selectedChat else { return [] }
        return messageIDsByChat[selectedChat.id] ?? []
    }

    var selectedTimelinePaging: TimelinePagingState {
        guard let selectedChat else { return .empty }
        return timelinePagingByChat[selectedChat.id] ?? .empty
    }

    var selectedTimelineIsLoadingInitialPage: Bool {
        guard let selectedChat else { return false }
        return timelineInitialLoadGroupId == selectedChat.id
            && messagesByChat[selectedChat.id] == nil
    }

    func timelineMessage(groupIdHex: String, messageId: String) -> MessageItem? {
        messageLookupByChat[groupIdHex]?[messageId]
    }

    var marmotBuildSummary: String {
        "\(MarmotKitVersion.darkmatterSHA) / \(MarmotKitVersion.builtAt)"
    }

    var diagnosticsInfo: [DiagnosticsInfoItem] {
        let config = telemetryBuildConfig
        return [
            DiagnosticsInfoItem(title: L10n.string("Tenant"), value: TelemetryBuildConfig.tenant),
            DiagnosticsInfoItem(title: L10n.string("Deployment"), value: config.deploymentEnvironment),
            DiagnosticsInfoItem(title: L10n.string("Service version"), value: config.serviceVersion),
            DiagnosticsInfoItem(title: L10n.string("OTLP endpoint"), value: config.otlpEndpoint),
            DiagnosticsInfoItem(
                title: L10n.string("Telemetry token"),
                value: config.telemetryCredentialsAvailable ? L10n.string("Configured") : L10n.string("Missing")
            ),
            DiagnosticsInfoItem(
                title: L10n.string("Audit token"),
                value: config.auditLogCredentialsAvailable ? L10n.string("Configured") : L10n.string("Missing")
            ),
            DiagnosticsInfoItem(title: L10n.string("OS"), value: config.osVersion),
            DiagnosticsInfoItem(title: L10n.string("Device model"), value: config.deviceModelIdentifier ?? L10n.string("Unknown")),
            DiagnosticsInfoItem(title: L10n.string("Marmot"), value: marmotBuildSummary)
        ]
    }

    var canSend: Bool {
        client != nil
            && selectedChat != nil
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
    }

    var showsMessengerChrome: Bool {
        phase == .ready
    }

    var preferredColorScheme: ColorScheme? {
        switch appearancePreference {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var preferredLocale: Locale {
        languagePreference.locale ?? .autoupdatingCurrent
    }

    func bootstrap() async {
        guard client == nil, case .bootstrapping = phase else { return }
        lastError = nil
        do {
            let runtime = try clientFactory()
            client = runtime
            storageRootPath = runtime.storageRootPath
            let summaries = try runtime.listAccounts()
            accounts = summaries.map { accountItem(from: $0) }
            restoreOrSelectFirstAccount()
            try await configureObservabilityRuntime()
            if accounts.isEmpty {
                phase = .onboarding
                return
            }

            try await startRuntimeIfNeeded(runtime)
            accounts = try runtime.listAccounts().map { accountItem(from: $0) }
            restoreOrSelectFirstAccount()
            try await configureObservabilityRuntime()
            phase = .ready
            await refreshNotificationAuthorizationStatus()
            loadNotificationSettings()
            await loadPrivacySecuritySettings()
            await reloadChats()
            startNotificationListener()
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func selectAccount(_ account: AccountItem) {
        stopTimelineListener()
        clearEnteredLoginIdentity()
        activeAccountId = account.id
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        searchText = ""
        closeNewChatComposer()
        pruneMessageCache(keeping: nil)
        refreshObservabilityRuntime()
        let chatToLoad = activeChats.first
        selection = chatToLoad.map { .chat($0.id) }
        if let chatToLoad {
            beginTimelineInitialLoadIfNeeded(groupIdHex: chatToLoad.id)
        }
        Task {
            await reloadChats()
            if let selectedChat {
                await loadMessages(groupIdHex: selectedChat.id)
            }
        }
    }

    func selectAccountFromSettings(_ account: AccountItem) {
        stopTimelineListener()
        clearEnteredLoginIdentity()
        activeAccountId = account.id
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        searchText = ""
        closeNewChatComposer()
        pruneMessageCache(keeping: nil)
        refreshObservabilityRuntime()
        selection = .settings(.accounts)
        Task {
            await reloadChats()
        }
    }

    func selectChat(_ chat: ChatItem) {
        stopTimelineListener()
        clearEnteredLoginIdentity()
        selection = .chat(chat.id)
        closeNewChatComposer()
        pruneMessageCache(keeping: chat.id)
        beginTimelineInitialLoadIfNeeded(groupIdHex: chat.id)
        Task { await loadMessages(groupIdHex: chat.id) }
    }

    func showNewChat() {
        isNewChatComposerVisible = true
        lastError = nil
        resetNewChatComposer()
    }

    func closeNewChatComposer() {
        isNewChatComposerVisible = false
        resetNewChatComposer()
    }

    func showSettings(_ page: SettingsPage = .profile) {
        stopTimelineListener()
        clearEnteredLoginIdentity()
        selection = .settings(page)
        closeNewChatComposer()
        pruneMessageCache(keeping: nil)
    }

    func showSettingsPage(_ page: SettingsPage) {
        showSettings(page)
    }

    func showLogin() {
        authenticationMode = .login
        clearEnteredLoginIdentity()
        lastError = nil
    }

    func cancelLogin() {
        authenticationMode = .landing
        clearEnteredLoginIdentity()
        lastError = nil
    }

    /// Scrubs the entered nsec (private key) from `loginIdentity` so it does not
    /// linger in observable memory longer than necessary. Used on login exit
    /// paths and when navigating away from the login / add-account UI. See #32.
    func clearEnteredLoginIdentity() {
        guard !loginIdentity.isEmpty else { return }
        loginIdentity = ""
    }

    func signUp() async {
        guard let client, !isAuthenticating else { return }
        lastError = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let summary = try await client.createIdentity(
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
            )
            try refreshAccounts(preferred: summary)
            try await startRuntimeIfNeeded(client)
            try refreshAccounts(preferred: summary)
            authenticationMode = .landing
            phase = .ready
            try await configureObservabilityRuntime()
            await refreshNotificationAuthorizationStatus()
            loadNotificationSettings()
            await loadPrivacySecuritySettings()
            await reloadChats()
            startNotificationListener()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func login() async {
        guard let client, !isAuthenticating else { return }
        let identity = loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { return }

        lastError = nil
        isAuthenticating = true
        // Scrub the entered nsec (private key) on every exit path so it never
        // outlives the login call, including failures. See issue #32.
        defer {
            isAuthenticating = false
            clearEnteredLoginIdentity()
        }

        do {
            let summary = try await client.login(
                identity: identity,
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
            )
            try refreshAccounts(preferred: summary)
            try await startRuntimeIfNeeded(client)
            try refreshAccounts(preferred: summary)
            authenticationMode = .landing
            phase = .ready
            try await configureObservabilityRuntime()
            await refreshNotificationAuthorizationStatus()
            loadNotificationSettings()
            await loadPrivacySecuritySettings()
            await reloadChats()
            startNotificationListener()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeActiveAccount() async {
        guard let client, let activeAccount, !isRemovingAccount else { return }

        lastError = nil
        isRemovingAccount = true
        defer { isRemovingAccount = false }

        let removedAccountId = activeAccount.id
        do {
            stopTimelineListener()
            stopChatListListener()
            try await client.removeAccount(accountRef: activeAccount.accountRef)
            clearComposerDrafts(forAccountId: removedAccountId)
            accounts = try client.listAccounts().map { accountItem(from: $0) }
            chatsByAccount[removedAccountId] = nil
            messagesByChat.removeAll()
            messageLookupByChat.removeAll()
            messageIDsByChat.removeAll()
            peerProfileFFICache.removeAll()
            timelinePagingByChat.removeAll()
            profileDraft = ProfileDraft()
            keyPackages = []
            auditLogFiles = []
            auditLogUploadStatus = nil

            if accounts.isEmpty {
                activeAccountId = nil
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
                selection = nil
                phase = .onboarding
                notificationSettings = .defaults
                privacySecuritySettings = .defaults
                return
            }

            restoreOrSelectFirstAccount()
            selection = .settings(.accounts)
            try await configureObservabilityRuntime()
            await loadSettingsData()
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAllData() async {
        guard let client, !isDeletingAllData else { return }

        isDeletingAllData = true
        lastError = nil
        defer { isDeletingAllData = false }

        do {
            stopNotificationListener()
            stopChatListListener()
            stopTimelineListener()

            try await client.deleteAllLocalData()
            self.client = nil
            hasStartedRuntime = false
            resetToNewInstallState(storageRootPath: client.storageRootPath)

            let runtime = try clientFactory()
            self.client = runtime
            storageRootPath = runtime.storageRootPath
            try await configureObservabilityRuntime()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleChatList() {
        withAnimation(.smooth(duration: 0.18)) {
            isChatListVisible.toggle()
        }
    }

    func loadSettingsData() async {
        guard let client, let activeAccount else {
            profileDraft = ProfileDraft()
            relaySettings = .defaults
            relayDraft = relaySettings.relays(for: selectedRelaySection)
            keyPackages = []
            notificationSettings = .defaults
            privacySecuritySettings = .defaults
            return
        }

        isLoadingSettings = true
        defer { isLoadingSettings = false }

        do {
            let profile = try client.userProfile(accountIdHex: activeAccount.accountIdHex)
            profileDraft = ProfileDraft(profile: profile, fallbackName: activeAccount.displayName)
            let displayName = profileDraft.primaryDisplayName(fallback: activeAccount.displayName)
            updateActiveAccountProfile(displayName: displayName, pictureURL: profileDraft.picture)
        } catch {
            lastError = error.localizedDescription
            profileDraft = ProfileDraft(fallbackName: activeAccount.displayName)
            if let displayName = client.displayName(accountIdHex: activeAccount.accountIdHex)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !displayName.isEmpty {
                updateActiveAccountProfile(displayName: displayName, pictureURL: activeAccount.pictureURL)
            }
        }

        do {
            let lists = try client.accountRelayLists(accountRef: activeAccount.accountRef)
            relaySettings = RelaySettingsSnapshot(lists: lists)
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        } catch {
            lastError = error.localizedDescription
            relaySettings = .defaults
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        }

        await refreshNotificationAuthorizationStatus()
        loadNotificationSettings()
        await loadPrivacySecuritySettings()
    }

    func loadKeyPackages() async {
        guard let client, let activeAccount else {
            keyPackages = []
            return
        }

        do {
            let packages = try await client.accountKeyPackages(
                accountRef: activeAccount.accountRef,
                bootstrapRelays: relaySettings.networkBootstrapRelays
            )
            keyPackages = packages.map(KeyPackageItem.init(package:))
        } catch {
            lastError = error.localizedDescription
            keyPackages = []
        }
    }

    func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await localNotificationCenter.authorizationStatus()
    }

    func requestLocalNotificationPermission() async {
        lastError = nil
        do {
            notificationAuthorizationStatus = try await localNotificationCenter.requestAuthorization()
            if !notificationAuthorizationStatus.canPostNotifications {
                lastError = Self.notificationPermissionGuidance
            }
        } catch {
            await handleNotificationPermissionError(error)
        }
    }

    func setLocalNotificationsEnabled(_ enabled: Bool) async {
        guard let client, let activeAccount, !isSavingNotifications else { return }

        lastError = nil
        isSavingNotifications = true
        defer { isSavingNotifications = false }

        if enabled {
            var status = notificationAuthorizationStatus
            if !status.canPostNotifications {
                do {
                    status = try await localNotificationCenter.requestAuthorization()
                    notificationAuthorizationStatus = status
                } catch {
                    await handleNotificationPermissionError(error)
                    return
                }
            }

            guard status.canPostNotifications else {
                lastError = Self.notificationPermissionGuidance
                return
            }
        }

        do {
            let settings = try client.setLocalNotificationsEnabled(
                accountRef: activeAccount.accountRef,
                enabled: enabled
            )
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func publishNewKeyPackage() async {
        guard let client, let activeAccount, !isPublishingKeyPackage else { return }
        lastError = nil
        isPublishingKeyPackage = true
        defer { isPublishingKeyPackage = false }

        do {
            _ = try await client.publishNewKeyPackage(accountRef: activeAccount.accountRef)
            await loadKeyPackages()
        } catch {
            if isNotificationsNotAllowedError(error) {
                await handleNotificationPermissionError(error)
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    func republishKeyPackage() async {
        guard let client, let activeAccount, !isRepublishingKeyPackage else { return }
        lastError = nil
        isRepublishingKeyPackage = true
        defer { isRepublishingKeyPackage = false }

        do {
            _ = try await client.republishKeyPackage(accountRef: activeAccount.accountRef)
            await loadKeyPackages()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteKeyPackage(_ package: KeyPackageItem) async {
        guard let client, let activeAccount, deletingKeyPackageId == nil else { return }
        guard !package.eventIdHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = L10n.string("Key package is missing an event id.")
            return
        }

        lastError = nil
        deletingKeyPackageId = package.id
        defer { deletingKeyPackageId = nil }

        do {
            _ = try await client.deleteAccountKeyPackage(
                accountRef: activeAccount.accountRef,
                eventIdHex: package.eventIdHex,
                relays: relaySettings.networkBootstrapRelays
            )
            await loadKeyPackages()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectRelaySection(_ section: RelaySettingsSection) {
        selectedRelaySection = section
        relayDraft = relaySettings.relays(for: section)
        newRelayURL = ""
    }

    func addRelayDraftURL() {
        let url = newRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        guard isRelayURL(url) else {
            lastError = L10n.string("Relay URLs must use wss:// (cleartext ws:// is allowed only for localhost).")
            return
        }
        if !relayDraft.contains(url) {
            relayDraft.append(url)
        }
        newRelayURL = ""
    }

    func removeRelayDraftURL(_ url: String) {
        relayDraft.removeAll { $0 == url }
    }

    func restoreRelayDraftDefaults() {
        relayDraft = MarmotClient.seedRelays
        newRelayURL = ""
    }

    func saveRelaySettings() async {
        guard let client, let activeAccount, !isSavingRelays else { return }
        let relays = normalizedRelays(relayDraft)
        guard !relays.isEmpty else {
            lastError = L10n.string("Add at least one relay before saving.")
            return
        }
        guard relays.allSatisfy(isRelayURL) else {
            lastError = L10n.string("Relay URLs must use wss:// (cleartext ws:// is allowed only for localhost).")
            return
        }

        lastError = nil
        isSavingRelays = true
        defer { isSavingRelays = false }

        do {
            let lists: AccountRelayListsFfi
            let bootstrapRelays = relaySettings.networkBootstrapRelays
            switch selectedRelaySection {
            case .nip65:
                lists = try await client.setAccountNip65Relays(
                    accountRef: activeAccount.accountRef,
                    relays: relays,
                    bootstrapRelays: bootstrapRelays
                )
            case .inbox:
                lists = try await client.setAccountInboxRelays(
                    accountRef: activeAccount.accountRef,
                    relays: relays,
                    bootstrapRelays: bootstrapRelays
                )
            }
            relaySettings = RelaySettingsSnapshot(lists: lists)
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProfile() async {
        guard let client, let activeAccount, !isSavingProfile else { return }
        lastError = nil
        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            let published = try await client.publishUserProfile(
                accountRef: activeAccount.accountRef,
                profile: profileDraft.metadata,
                defaultRelays: relaySettings.publishRelays,
                bootstrapRelays: relaySettings.networkBootstrapRelays
            )
            profileDraft = ProfileDraft(profile: published, fallbackName: activeAccount.displayName)
            let displayName = profileDraft.primaryDisplayName(fallback: activeAccount.displayName)
            updateActiveAccountProfile(displayName: displayName, pictureURL: profileDraft.picture)
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func resolveNewChatQuery() async -> NewChatRecipient? {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client else { return nil }
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            lastError = L10n.string("Enter an npub, profile link, or public key.")
            return nil
        }

        lastError = nil
        let lookupGeneration = beginNewChatLookup()
        isResolvingNewChat = true
        defer {
            if isCurrentNewChatLookup(generation: lookupGeneration, query: query) {
                isResolvingNewChat = false
            }
        }

        do {
            let member = try client.normalizeMemberRef(memberRef: query)
            try? await client.refreshProfile(accountIdHex: member.accountIdHex, relays: MarmotClient.seedRelays)
            peerProfileFFICache[member.accountIdHex] = nil
            let profile = try? client.userProfile(accountIdHex: member.accountIdHex)
            let displayName = firstNonBlank([
                profile?.displayName,
                profile?.name,
                client.displayName(accountIdHex: member.accountIdHex)
            ])
            let recipient = NewChatRecipient(
                sourceQuery: query,
                memberRef: member.memberRef,
                accountIdHex: member.accountIdHex,
                npub: member.npub,
                displayName: displayName,
                pictureURL: profile?.picture
            )
            guard isCurrentNewChatLookup(generation: lookupGeneration, query: query) else {
                return nil
            }
            newChatRecipient = recipient
            return recipient
        } catch {
            guard isCurrentNewChatLookup(generation: lookupGeneration, query: query) else {
                return nil
            }
            newChatRecipient = nil
            lastError = L10n.string("Enter a valid npub, profile link, or hex public key.")
            return nil
        }
    }

    func resolveNewChatQueryIfReady() async {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            lastError = nil
            return
        }
        guard looksLikeMemberRef(query) else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            return
        }
        guard resolvedNewChatRecipient == nil else { return }

        await resolveNewChatQuery()
    }

    func createNewChat() async {
        guard let client, let activeAccount, !isCreatingChat else { return }
        let recipient: NewChatRecipient?
        if let resolvedNewChatRecipient {
            recipient = resolvedNewChatRecipient
        } else {
            recipient = await resolveNewChatQuery()
        }
        guard let recipient else { return }

        lastError = nil
        isCreatingChat = true
        defer { isCreatingChat = false }

        do {
            let trimmedName = newChatName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = newChatDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let groupIdHex = try await client.createGroup(
                accountRef: activeAccount.accountRef,
                name: trimmedName.isEmpty ? recipient.title : trimmedName,
                memberRefs: [recipient.memberRef],
                description: trimmedDescription.isEmpty ? nil : trimmedDescription
            )
            await reloadChats()
            insertCreatedChatIfNeeded(
                groupIdHex: groupIdHex,
                title: trimmedName.isEmpty ? recipient.title : trimmedName,
                avatarSeed: recipient.accountIdHex,
                pictureURL: recipient.pictureURL
            )
            selection = .chat(groupIdHex)
            closeNewChatComposer()
            beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
            await loadMessages(groupIdHex: groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reloadChats() async {
        guard let client, let activeAccount else { return }
        stopChatListListener()
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let subscription = try await client.subscribeChatList(
                accountRef: activeAccount.accountRef,
                includeArchived: false
            )
            guard activeAccountId == activeAccount.id else { return }

            await applyChatRows(subscription.snapshot(), account: activeAccount)
            startChatListListener(account: activeAccount, subscription: subscription)

            await selectMostRecentChatIfNeeded()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMessages(groupIdHex: String) async {
        guard let client, let activeAccount else {
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        if timelineTaskGroupId == groupIdHex, messagesByChat[groupIdHex] != nil {
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        stopTimelineListener()
        guard selectedChat?.id == groupIdHex else {
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
        defer { finishTimelineInitialLoad(groupIdHex: groupIdHex) }
        do {
            let accountRef = activeAccount.accountRef
            if let row = try await runOffMain({
                try client.initializeChatReadState(accountRef: accountRef, groupIdHex: groupIdHex)
            }) {
                await applyChatRow(row, account: activeAccount)
            }

            let subscription = try await client.subscribeTimelineMessages(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                limit: Self.timelinePageLimit
            )
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }

            let page = subscription.snapshot() ?? TimelinePageFfi(
                messages: [],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: activeAccount, client: client)
            // Start the listener first (it tears down any prior listener, which would clear
            // these), then record the subscription so scroll-back pagination can reach it.
            startTimelineListener(groupIdHex: groupIdHex, account: activeAccount, subscription: subscription)
            activeTimelineSubscription = subscription
            activeTimelineGroupId = groupIdHex
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadOlderMessages(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        guard selectedChat?.id == groupIdHex, activeTimelineGroupId == groupIdHex else { return }
        guard let subscription = activeTimelineSubscription else { return }
        guard var paging = timelinePagingByChat[groupIdHex],
              paging.hasMoreBefore,
              !paging.isLoadingBefore
        else { return }

        paging.isLoadingBefore = true
        timelinePagingByChat[groupIdHex] = paging
        defer {
            if var currentPaging = timelinePagingByChat[groupIdHex] {
                currentPaging.isLoadingBefore = false
                timelinePagingByChat[groupIdHex] = currentPaging
            }
        }

        do {
            // The subscription owns the materialized window; `paginateBackwards` extends it
            // toward older history off the main thread and returns the new authoritative
            // window (already sorted, deduped, capped, with correct has-more flags).
            let page = try await subscription.paginateBackwards(count: Self.timelinePageLimit)
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: activeAccount, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadNewerMessages(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        guard selectedChat?.id == groupIdHex, activeTimelineGroupId == groupIdHex else { return }
        guard let subscription = activeTimelineSubscription else { return }
        guard var paging = timelinePagingByChat[groupIdHex],
              paging.hasMoreAfter,
              !paging.isLoadingAfter
        else { return }

        paging.isLoadingAfter = true
        timelinePagingByChat[groupIdHex] = paging
        defer {
            if var currentPaging = timelinePagingByChat[groupIdHex] {
                currentPaging.isLoadingAfter = false
                timelinePagingByChat[groupIdHex] = currentPaging
            }
        }

        do {
            let page = try await subscription.paginateForwards(count: Self.timelinePageLimit)
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: activeAccount, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Render an authoritative timeline window from the subscription (initial snapshot,
    /// pagination result, or live update). The window is already ordered/deduped/capped by
    /// the runtime, so we map + resolve senders and replace the transcript wholesale.
    private func applyTimelineWindow(
        _ page: TimelinePageFfi,
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        let senderProfiles = await messageSenderProfiles(
            from: page.messages,
            groupIdHex: groupIdHex,
            activeAccount: account,
            client: client
        )
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }

        let currentPaging = timelinePagingByChat[groupIdHex]
        replaceMessages(
            MessageItem.timeline(
                from: page,
                activeAccountIdHex: account.accountIdHex,
                senderProfiles: senderProfiles
            ),
            groupIdHex: groupIdHex,
            paging: TimelinePagingState(
                hasMoreBefore: page.hasMoreBefore,
                hasMoreAfter: page.hasMoreAfter,
                isLoadingBefore: currentPaging?.isLoadingBefore ?? false,
                isLoadingAfter: currentPaging?.isLoadingAfter ?? false
            )
        )
        await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: account, client: client)
    }

    func startReply(to message: MessageItem) {
        guard message.supportsChatActions else { return }
        replyDraftContext = MessageReplyContext(
            targetMessageId: message.id,
            senderName: message.senderName,
            body: message.body
        )
    }

    func cancelReply() {
        replyDraftContext = nil
    }

    func copyText(of message: MessageItem) {
        guard message.canCopyText else { return }
        copyText(message.body)
    }

    func copyText(_ text: String) {
        copyTextHandler(text)
    }

    /// The bech32 `npub` form of a hex public key — the canonical, user-facing way to show
    /// a Nostr public key. Falls back to the hex if conversion is unavailable. The
    /// conversion is a pure in-memory bech32 encode, so it's cheap to call from view bodies.
    func npub(forAccountIdHex accountIdHex: String) -> String {
        let trimmed = accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return client?.npub(accountIdHex: trimmed) ?? trimmed
    }

    func react(to message: MessageItem, emoji: String) async {
        guard message.supportsChatActions else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        do {
            _ = try await client.reactToMessage(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                targetMessageId: message.id,
                emoji: emoji
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeReaction(_ reaction: MessageReaction, from message: MessageItem) async {
        guard message.supportsChatActions else { return }
        guard reaction.canRemoveOwnReaction, let reactionMessageId = reaction.ownReactionMessageId else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        do {
            _ = try await client.deleteMessage(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                targetMessageId: reactionMessageId
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteMessage(_ message: MessageItem) async {
        guard message.canDelete else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        do {
            _ = try await client.deleteMessage(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                targetMessageId: message.id
            )
            if replyDraftContext?.targetMessageId == message.id {
                replyDraftContext = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showGroupDetails(for chat: ChatItem) async {
        guard !chat.isDirect else { return }
        lastError = nil
        groupDetailsSnapshot = nil
        groupInviteMemberQuery = ""
        groupTranscriptExportStatus = nil
        isGroupDetailsPresented = true
        await loadGroupDetails(groupIdHex: chat.id)
    }

    func closeGroupDetails() {
        isGroupDetailsPresented = false
        groupDetailsSnapshot = nil
        groupProfileDraftName = ""
        groupProfileDraftDescription = ""
        groupInviteMemberQuery = ""
        isLoadingGroupDetails = false
        isSavingGroupProfile = false
        isInvitingGroupMember = false
        isArchivingGroup = false
        isLeavingGroup = false
        isExportingGroupTranscript = false
        groupTranscriptExportStatus = nil
        mutatingGroupMemberId = nil
    }

    func copySelectedGroupTranscriptJSON() async {
        guard !isExportingGroupTranscript,
              let client,
              let activeAccount,
              let snapshot = groupDetailsSnapshot
        else { return }

        lastError = nil
        groupTranscriptExportStatus = nil
        isExportingGroupTranscript = true
        defer { isExportingGroupTranscript = false }

        do {
            let accountRef = activeAccount.accountRef
            let groupIdHex = snapshot.groupIdHex
            let groupName = snapshot.name
            // Paginates the whole transcript via blocking FFI and JSON-encodes it; keep it
            // off the main thread so a large export does not freeze the UI.
            let export = try await runOffMain { () -> (json: String, eventCount: Int) in
                let messages = try ConversationTranscriptExport.fetchAllMessages(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
                let document = ConversationTranscriptExport.makeDocument(
                    groupIdHex: groupIdHex,
                    groupName: groupName,
                    messages: messages
                )
                return (try ConversationTranscriptExport.encodeJSONString(document), document.eventCount)
            }
            copyText(export.json)
            groupTranscriptExportStatus = String(
                format: L10n.string("Copied transcript JSON for %d events."),
                export.eventCount
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reloadSelectedGroupDetails() async {
        guard let selectedChat, !selectedChat.isDirect else { return }
        await loadGroupDetails(groupIdHex: selectedChat.id)
    }

    func saveGroupProfile() async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        let trimmedName = groupProfileDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = groupProfileDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastError = L10n.string("Group name cannot be empty.")
            return
        }

        lastError = nil
        isSavingGroupProfile = true
        defer { isSavingGroupProfile = false }

        do {
            _ = try await client.updateGroupProfile(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex,
                name: trimmedName,
                description: trimmedDescription
            )
            await reloadChats()
            await loadGroupDetails(groupIdHex: snapshot.groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func inviteMemberToSelectedGroup() async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        let query = groupInviteMemberQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeMemberRef(query) else {
            lastError = L10n.string("Enter a valid npub, profile link, or hex public key.")
            return
        }

        lastError = nil
        isInvitingGroupMember = true
        defer { isInvitingGroupMember = false }

        do {
            let normalized = try client.normalizeMemberRef(memberRef: query)
            let result = try await client.inviteMembersDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex,
                memberRefs: [normalized.npub]
            )
            groupInviteMemberQuery = ""
            applyGroupMutationResult(result)
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func promoteGroupMember(_ member: GroupMemberItem) async {
        await mutateGroupMember(member, action: .promote)
    }

    func demoteGroupMember(_ member: GroupMemberItem) async {
        await mutateGroupMember(member, action: .demote)
    }

    func removeGroupMember(_ member: GroupMemberItem) async {
        await mutateGroupMember(member, action: .remove)
    }

    func selfDemoteSelectedGroupAdmin() async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        guard snapshot.isSelfAdmin, !snapshot.isLastAdmin else {
            lastError = L10n.string("Make another member an admin before stepping down.")
            return
        }

        lastError = nil
        mutatingGroupMemberId = snapshot.members.first(where: \.isSelf)?.id
        defer { mutatingGroupMemberId = nil }

        do {
            let result = try await client.selfDemoteAdminDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex
            )
            applyGroupMutationResult(result)
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setSelectedGroupArchived(_ archived: Bool) async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        lastError = nil
        isArchivingGroup = true
        defer { isArchivingGroup = false }

        do {
            _ = try await client.setGroupArchived(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex,
                archived: archived
            )
            if archived {
                closeGroupDetails()
            }
            await reloadChats()
            if !archived {
                await loadGroupDetails(groupIdHex: snapshot.groupIdHex)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func leaveSelectedGroup() async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        guard snapshot.canLeave, !snapshot.requiresSelfDemoteBeforeLeave else {
            lastError = L10n.string("Demote yourself from admin before leaving this group.")
            return
        }

        lastError = nil
        isLeavingGroup = true
        defer { isLeavingGroup = false }

        do {
            _ = try await client.leaveGroup(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex
            )
            closeGroupDetails()
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showGroupImagePicker(for chat: ChatItem) {
        guard !chat.isDirect else { return }
        lastError = nil
        closeGroupDetails()
        groupImageSearchQuery = ""
        groupImageResults = []
        isGroupImagePickerPresented = true
    }

    func closeGroupImagePicker() {
        isGroupImagePickerPresented = false
        groupImageResults = []
        isSearchingGroupImages = false
        isSavingGroupImage = false
    }

    private func dismissGroupImagePickerIfSelectedChatUnavailable() {
        guard isGroupImagePickerPresented, selectedChat == nil else { return }
        closeGroupImagePicker()
    }

    func searchGroupImages() async {
        let query = groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            groupImageResults = []
            return
        }

        lastError = nil
        isSearchingGroupImages = true
        defer { isSearchingGroupImages = false }

        do {
            groupImageResults = try await groupImageSearchClient.searchImages(query: query)
        } catch {
            groupImageResults = []
            lastError = error.localizedDescription
        }
    }

    func setGroupImage(_ result: GroupImageSearchResult) async {
        await updateSelectedGroupImage(url: result.imageURL, dim: result.dimension)
    }

    func clearGroupImage() async {
        await updateSelectedGroupImage(url: nil, dim: nil)
    }

    private func updateSelectedGroupImage(url: String?, dim: String?) async {
        guard let client, let activeAccount, let selectedChat, !selectedChat.isDirect else { return }
        isSavingGroupImage = true
        defer { isSavingGroupImage = false }

        do {
            _ = try await client.updateGroupAvatarUrl(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                url: url,
                dim: dim,
                thumbhash: nil
            )
            await reloadChats()
            closeGroupImagePicker()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadGroupDetails(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        guard selectedChat?.id == groupIdHex else { return }

        isLoadingGroupDetails = true
        defer { isLoadingGroupDetails = false }

        do {
            let details = try await client.groupDetails(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            let managementState = try await client.groupManagementState(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            guard selectedChat?.id == groupIdHex else { return }
            applyGroupDetails(details, managementState: managementState)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func mutateGroupMember(_ member: GroupMemberItem, action: GroupMemberMutationAction) async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        lastError = nil
        mutatingGroupMemberId = member.id
        defer { mutatingGroupMemberId = nil }

        do {
            let result: GroupMutationResultFfi
            switch action {
            case .promote:
                result = try await client.promoteAdminDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: snapshot.groupIdHex,
                    memberRef: member.npub
                )
            case .demote:
                if member.isSelf {
                    result = try await client.selfDemoteAdminDetailed(
                        accountRef: activeAccount.accountRef,
                        groupIdHex: snapshot.groupIdHex
                    )
                } else {
                    result = try await client.demoteAdminDetailed(
                        accountRef: activeAccount.accountRef,
                        groupIdHex: snapshot.groupIdHex,
                        memberRef: member.npub
                    )
                }
            case .remove:
                result = try await client.removeMembersDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: snapshot.groupIdHex,
                    memberRefs: [member.npub]
                )
            }
            applyGroupMutationResult(result)
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func applyGroupMutationResult(_ result: GroupMutationResultFfi) {
        applyGroupDetails(result.details, managementState: result.managementState)
    }

    private func applyGroupDetails(
        _ details: GroupDetailsFfi,
        managementState: GroupManagementStateFfi
    ) {
        let snapshot = groupDetailsSnapshot(from: details, managementState: managementState)
        groupDetailsSnapshot = snapshot
        groupProfileDraftName = snapshot.name
        groupProfileDraftDescription = snapshot.description
    }

    private func groupDetailsSnapshot(
        from details: GroupDetailsFfi,
        managementState: GroupManagementStateFfi
    ) -> GroupDetailsSnapshot {
        let actionByMemberId = Dictionary(
            uniqueKeysWithValues: managementState.memberActions.map { ($0.memberIdHex, $0) }
        )
        let members = details.members
            .map { member in
                let action = actionByMemberId[member.memberIdHex]
                return GroupMemberItem(
                    id: member.memberIdHex,
                    displayName: firstNonBlank([member.displayName, member.account])
                        ?? DisplayText.short(member.npub, head: 12, tail: 8),
                    npub: member.npub,
                    accountLabel: member.account,
                    isLocal: member.local,
                    isAdmin: member.isAdmin,
                    isSelf: member.isSelf,
                    canRemove: action?.canRemove ?? false,
                    canPromote: action?.canPromote ?? false,
                    canDemote: action?.canDemote ?? false
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                if lhs.isAdmin != rhs.isAdmin { return lhs.isAdmin }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        return GroupDetailsSnapshot(
            groupIdHex: details.group.groupIdHex,
            endpoint: details.group.endpoint,
            name: firstNonBlank([details.group.name]) ?? L10n.string("Unnamed group"),
            description: details.group.description,
            avatarURL: firstNonBlank([details.group.avatarUrl]),
            avatarDimension: firstNonBlank([details.group.avatarDim]),
            nostrGroupIdHex: details.group.nostrGroupIdHex,
            relays: details.group.relays,
            adminIds: details.group.admins,
            archived: details.group.archived,
            pendingConfirmation: details.group.pendingConfirmation,
            members: members,
            isSelfAdmin: managementState.isSelfAdmin,
            isLastAdmin: managementState.isLastAdmin,
            canInvite: managementState.canInvite,
            canLeave: managementState.canLeave,
            requiresSelfDemoteBeforeLeave: managementState.requiresSelfDemoteBeforeLeave
        )
    }

    func sendDraft() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, let activeAccount, let selectedChat, !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        do {
            if let replyDraftContext {
                _ = try await client.replyToMessage(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: selectedChat.id,
                    targetMessageId: replyDraftContext.targetMessageId,
                    text: text
                )
            } else {
                _ = try await client.sendText(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: selectedChat.id,
                    text: text
                )
            }
            draftText = ""
            replyDraftContext = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleNotificationUpdate(_ update: NotificationUpdateFfi) async {
        guard !update.isFromSelf else { return }
        guard !deliveredNotificationKeys.contains(update.notificationKey) else { return }
        guard localNotificationsEnabled(for: update) else { return }

        if selectedChat?.id == update.groupIdHex, selectedConversationIsVisible() {
            return
        }

        if !notificationAuthorizationStatus.canPostNotifications {
            await refreshNotificationAuthorizationStatus()
        }
        guard notificationAuthorizationStatus.canPostNotifications else { return }

        do {
            let request = localNotificationRequest(for: update)
            try await localNotificationCenter.post(request)
            rememberDeliveredNotificationKey(update.notificationKey)
        } catch {
            setBackgroundStatus(error.localizedDescription)
        }
    }

    func handleNotificationResponse(_ userInfo: [String: String]) {
        guard let groupIdHex = userInfo["groupIdHex"] else { return }

        if let account = notificationAccount(from: userInfo) {
            activeAccountId = account.id
            UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        }

        selection = .chat(groupIdHex)
        isChatListVisible = true
        closeNewChatComposer()
        pruneMessageCache(keeping: groupIdHex)
        NSApplication.shared.activate(ignoringOtherApps: true)
        beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)

        Task {
            await reloadChats()
            await loadMessages(groupIdHex: groupIdHex)
        }
    }

    private func restoreOrSelectFirstAccount() {
        if let activeAccountId, accounts.contains(where: { $0.id == activeAccountId }) {
            return
        }
        activeAccountId = accounts.first?.id
        if let activeAccountId {
            UserDefaults.standard.set(activeAccountId, forKey: Self.activeAccountKey)
        }
    }

    private func refreshAccounts(preferred summary: AccountSummaryFfi) throws {
        guard let client else { return }
        let preferredAccount = accountItem(from: summary)
        var refreshed = try client.listAccounts().map { accountItem(from: $0) }
        if !refreshed.contains(where: { $0.id == preferredAccount.id }) {
            refreshed.append(preferredAccount)
        }

        accounts = refreshed
        activeAccountId = preferredAccount.id
        UserDefaults.standard.set(preferredAccount.id, forKey: Self.activeAccountKey)
        searchText = ""
        clearAllComposerDrafts()
        selection = nil
    }

    private func startRuntimeIfNeeded(_ runtime: any MarmotRuntime) async throws {
        guard !hasStartedRuntime else { return }
        try await runtime.start()
        hasStartedRuntime = true
    }

    private func resetToNewInstallState(storageRootPath: String) {
        accounts = []
        chatsByAccount = [:]
        messagesByChat = [:]
        messageLookupByChat = [:]
        messageIDsByChat = [:]
        activeAccountId = nil
        selection = nil
        searchText = ""
        isChatListVisible = true
        clearAllComposerDrafts()
        isRefreshing = false
        isSending = false
        authenticationMode = .landing
        loginIdentity = ""
        isAuthenticating = false
        profileDraft = ProfileDraft()
        relaySettings = .defaults
        selectedRelaySection = .nip65
        relayDraft = MarmotClient.seedRelays
        newRelayURL = ""
        keyPackages = []
        notificationSettings = .defaults
        notificationAuthorizationStatus = .notDetermined
        privacySecuritySettings = .defaults
        auditLogFiles = []
        auditLogUploadStatus = nil
        isLoadingSettings = false
        isSavingProfile = false
        isRemovingAccount = false
        isSavingRelays = false
        isPublishingKeyPackage = false
        isRepublishingKeyPackage = false
        isSavingNotifications = false
        isSavingPrivacySecurity = false
        isLoadingAuditLogFiles = false
        isDeletingAuditLogFiles = false
        isUploadingAuditLogFiles = false
        deletingKeyPackageId = nil
        isNewChatComposerVisible = false
        resetNewChatComposer()
        isResolvingNewChat = false
        isCreatingChat = false
        isGroupImagePickerPresented = false
        groupImageSearchQuery = ""
        groupImageResults = []
        isSearchingGroupImages = false
        isSavingGroupImage = false
        isGroupDetailsPresented = false
        groupDetailsSnapshot = nil
        groupProfileDraftName = ""
        groupProfileDraftDescription = ""
        groupInviteMemberQuery = ""
        isLoadingGroupDetails = false
        isSavingGroupProfile = false
        isInvitingGroupMember = false
        isArchivingGroup = false
        isLeavingGroup = false
        isExportingGroupTranscript = false
        groupTranscriptExportStatus = nil
        mutatingGroupMemberId = nil
        self.storageRootPath = storageRootPath
        timelinePagingByChat = [:]
        timelineInitialLoadGroupId = nil
        lastMarkedReadMarkers = [:]
        deliveredNotificationKeys = []
        deliveredNotificationKeyOrder = []
        UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
        phase = .onboarding
    }

    private static func copyToGeneralPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var telemetryBuildConfig: TelemetryBuildConfig {
        telemetryBuildConfigProvider()
    }

    private func refreshObservabilityRuntime() {
        Task { [weak self] in
            do {
                try await self?.configureObservabilityRuntime()
            } catch {
                self?.setBackgroundStatus(error.localizedDescription)
            }
        }
    }

    /// Record a background-task failure on the non-modal global status surface.
    /// Background failures must never write `lastError`, which is reserved for the
    /// user-initiated action on the current screen.
    private func setBackgroundStatus(_ message: String?) {
        backgroundStatus = message
    }

    /// Dismiss the background status banner (e.g. user tapped the close control, or a
    /// later background operation succeeded).
    func clearBackgroundStatus() {
        backgroundStatus = nil
    }

    private func configureObservabilityRuntime() async throws {
        guard let client else { return }
        let config = telemetryBuildConfig
        try await client.setRelayTelemetryRuntimeConfig(
            config: config.runtimeConfig(installId: try client.telemetryInstallId())
        )
        _ = try client.setAuditLogTrackerConfig(
            config: config.auditTrackerConfig(accountLabel: activeAccount?.displayName)
        )
        privacySecuritySettings.telemetryCredentialsAvailable = config.telemetryCredentialsAvailable
        privacySecuritySettings.auditLogCredentialsAvailable = config.auditLogCredentialsAvailable
    }

    private func loadNotificationSettings() {
        guard let client, let activeAccount else {
            notificationSettings = .defaults
            return
        }

        do {
            let settings = try client.notificationSettings(accountRef: activeAccount.accountRef)
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        } catch {
            notificationSettings = .defaults
            lastError = error.localizedDescription
        }
    }

    private func loadPrivacySecuritySettings() async {
        guard let client else {
            privacySecuritySettings = .defaults
            return
        }

        do {
            try await configureObservabilityRuntime()
            let telemetry = try client.relayTelemetrySettings()
            let auditLog = try client.auditLogSettings()
            let config = telemetryBuildConfig
            privacySecuritySettings = PrivacySecuritySettingsSnapshot(
                relayTelemetryEnabled: telemetry.exportEnabled,
                relayTelemetryIntervalSeconds: telemetry.exportIntervalSeconds,
                auditLoggingEnabled: auditLog.enabled,
                telemetryCredentialsAvailable: config.telemetryCredentialsAvailable,
                auditLogCredentialsAvailable: config.auditLogCredentialsAvailable
            )
            await loadAuditLogFiles()
        } catch {
            privacySecuritySettings = .defaults
            auditLogFiles = []
            lastError = error.localizedDescription
        }
    }

    func setRelayTelemetryEnabled(_ enabled: Bool) async {
        guard let client, !isSavingPrivacySecurity else { return }
        let config = telemetryBuildConfig
        guard enabled == false || config.telemetryCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.telemetryNotConfigured.localizedDescription
            return
        }

        lastError = nil
        isSavingPrivacySecurity = true
        defer { isSavingPrivacySecurity = false }

        do {
            try await configureObservabilityRuntime()
            let current = try client.relayTelemetrySettings()
            let settings = RelayTelemetrySettingsFfi(
                exportEnabled: enabled,
                exportIntervalSeconds: current.exportIntervalSeconds
            )
            let stored = try await client.setRelayTelemetrySettings(settings: settings)
            privacySecuritySettings.relayTelemetryEnabled = stored.exportEnabled
            privacySecuritySettings.relayTelemetryIntervalSeconds = stored.exportIntervalSeconds
            privacySecuritySettings.telemetryCredentialsAvailable = telemetryBuildConfig.telemetryCredentialsAvailable
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setAuditLoggingEnabled(_ enabled: Bool) async {
        guard let client, !isSavingPrivacySecurity else { return }
        let config = telemetryBuildConfig
        guard enabled == false || config.auditLogCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.auditLogNotConfigured.localizedDescription
            return
        }

        lastError = nil
        isSavingPrivacySecurity = true
        defer { isSavingPrivacySecurity = false }

        do {
            try await configureObservabilityRuntime()
            let stored = try await client.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: enabled))
            privacySecuritySettings.auditLoggingEnabled = stored.enabled
            privacySecuritySettings.auditLogCredentialsAvailable = telemetryBuildConfig.auditLogCredentialsAvailable
            await loadAuditLogFiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadAuditLogFiles() async {
        guard let client else {
            auditLogFiles = []
            return
        }

        isLoadingAuditLogFiles = true
        defer { isLoadingAuditLogFiles = false }

        do {
            auditLogFiles = try client.auditLogFiles()
        } catch {
            auditLogFiles = []
            lastError = error.localizedDescription
        }
    }

    func deleteAllAuditLogFiles() async {
        guard let client, !isDeletingAuditLogFiles else { return }

        isDeletingAuditLogFiles = true
        lastError = nil
        auditLogUploadStatus = nil
        defer { isDeletingAuditLogFiles = false }

        do {
            for file in auditLogFiles {
                _ = try await client.deleteAuditLogFile(path: file.path)
            }
            await loadAuditLogFiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uploadAuditLogFiles() async {
        guard let client, !isUploadingAuditLogFiles else { return }
        let config = telemetryBuildConfig
        guard config.auditLogCredentialsAvailable else {
            lastError = TelemetrySettingsActionError.auditLogNotConfigured.localizedDescription
            return
        }

        isUploadingAuditLogFiles = true
        lastError = nil
        auditLogUploadStatus = nil
        defer { isUploadingAuditLogFiles = false }

        do {
            try await configureObservabilityRuntime()
            let result = try await client.postAuditLogTrackerUpdate()
            auditLogUploadStatus = Self.auditLogUploadStatusMessage(result)
            await loadAuditLogFiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func auditLogUploadStatusMessage(_ result: AuditLogTrackerUpdateResultFfi) -> String {
        if let skippedReason = result.skippedReason, !skippedReason.isEmpty {
            return String(format: L10n.string("Audit upload skipped: %@"), skippedReason)
        }
        guard !result.uploaded.isEmpty else {
            return L10n.string("No audit logs uploaded.")
        }
        let totalBytes = result.uploaded.reduce(UInt64(0)) { $0 + $1.bytesSent }
        return String(
            format: L10n.string("Uploaded %d audit log files (%@)."),
            result.uploaded.count,
            ByteCountFormatter.string(fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
        )
    }

    private func startNotificationListener() {
        guard notificationTask == nil, client != nil else { return }
        notificationTask = Task { [weak self] in
            await self?.runNotificationListener()
        }
    }

    private func stopNotificationListener() {
        notificationTask?.cancel()
        notificationTask = nil
    }

    private func runNotificationListener() async {
        guard let client else { return }

        do {
            let subscription = try await client.subscribeNotifications()
            while !Task.isCancelled {
                guard let update = await subscription.next() else { break }
                await handleNotificationUpdate(update)
            }
        } catch is CancellationError {
            return
        } catch {
            setBackgroundStatus(error.localizedDescription)
        }

        notificationTask = nil
    }

    private func startChatListListener(
        account: AccountItem,
        subscription: ChatListSubscription? = nil
    ) {
        guard client != nil else { return }
        stopChatListListener()
        guard activeAccountId == account.id else { return }
        chatListTaskAccountId = account.id
        chatListTask = Task { [weak self] in
            await self?.runChatListListener(
                account: account,
                existingSubscription: subscription
            )
        }
    }

    private func stopChatListListener() {
        chatListTask?.cancel()
        chatListTask = nil
        chatListTaskAccountId = nil
        chatListEnrichmentTask?.cancel()
        chatListEnrichmentTask = nil
        chatListRowEnrichment.cancelAll()
    }

    private func runChatListListener(
        account: AccountItem,
        existingSubscription: ChatListSubscription? = nil
    ) async {
        guard let client else { return }

        do {
            let subscription: ChatListSubscription
            if let existingSubscription {
                subscription = existingSubscription
            } else {
                subscription = try await client.subscribeChatList(
                    accountRef: account.accountRef,
                    includeArchived: false
                )
                await applyChatRows(subscription.snapshot(), account: account)
            }

            while !Task.isCancelled {
                guard let update = await subscription.nextUpdate() else { break }
                guard !Task.isCancelled else { break }
                await applyChatListSubscriptionUpdate(update, account: account)
            }
        } catch is CancellationError {
            return
        } catch {
            if activeAccountId == account.id {
                setBackgroundStatus(error.localizedDescription)
            }
        }

        if chatListTaskAccountId == account.id && !Task.isCancelled {
            chatListTask = nil
            chatListTaskAccountId = nil
        }
    }

    private func startTimelineListener(
        groupIdHex: String,
        account: AccountItem,
        subscription: TimelineMessagesSubscription? = nil
    ) {
        guard client != nil else { return }
        stopTimelineListener()
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        timelineTaskGroupId = groupIdHex
        timelineTask = Task { [weak self] in
            await self?.runTimelineListener(
                groupIdHex: groupIdHex,
                account: account,
                existingSubscription: subscription
            )
        }
    }

    private func stopTimelineListener() {
        timelineTask?.cancel()
        timelineTask = nil
        timelineTaskGroupId = nil
        activeTimelineSubscription = nil
        activeTimelineGroupId = nil
    }

    private func runTimelineListener(
        groupIdHex: String,
        account: AccountItem,
        existingSubscription: TimelineMessagesSubscription? = nil
    ) async {
        guard let client else { return }

        do {
            let subscription: TimelineMessagesSubscription
            if let existingSubscription {
                subscription = existingSubscription
            } else {
                subscription = try await client.subscribeTimelineMessages(
                    accountRef: account.accountRef,
                    groupIdHex: groupIdHex,
                    limit: Self.timelinePageLimit
                )
            }
            // `next()` blocks for the next live change and returns the resulting
            // authoritative window (ordering, dedup, head-anchoring while scrolled back,
            // and the cap are all owned by the runtime), so we render it directly.
            while !Task.isCancelled {
                guard let page = await subscription.next() else { break }
                guard !Task.isCancelled else { break }
                await applyTimelineWindow(
                    page,
                    groupIdHex: groupIdHex,
                    account: account,
                    client: client
                )
            }
        } catch is CancellationError {
            return
        } catch {
            if activeAccountId == account.id, selectedChat?.id == groupIdHex {
                setBackgroundStatus(error.localizedDescription)
            }
        }

        if timelineTaskGroupId == groupIdHex && !Task.isCancelled {
            timelineTask = nil
            timelineTaskGroupId = nil
        }
    }

    private func applyChatRows(_ rows: [ChatListRowFfi], account: AccountItem) async {
        guard activeAccountId == account.id else { return }

        let chatItems = rows.map { baseChatItem(from: $0, account: account) }
        let previousChatIds = Set((chatsByAccount[account.id] ?? []).map(\.id))
        let nextChatIds = Set(chatItems.map(\.id))
        clearComposerDrafts(for: Array(previousChatIds.subtracting(nextChatIds)), accountId: account.id)
        chatsByAccount[account.id] = sortedChatItems(chatItems)
        dismissGroupImagePickerIfSelectedChatUnavailable()
        startChatListEnrichment(rows: rows, account: account)
    }

    private func applyChatListSubscriptionUpdate(
        _ update: ChatListSubscriptionUpdateFfi,
        account: AccountItem
    ) async {
        switch update {
        case .row(trigger: _, row: let row):
            await applyChatRow(row, account: account)
        case .removeRow(trigger: _, groupIdHex: let groupIdHex):
            removeChat(groupIdHex: groupIdHex, account: account)
        }
    }

    private func applyChatRow(_ row: ChatListRowFfi, account: AccountItem) async {
        guard activeAccountId == account.id else { return }

        var chats = chatsByAccount[account.id] ?? []
        if row.archived {
            removeChat(groupIdHex: row.groupIdHex, account: account)
            return
        }

        let chat = baseChatItem(from: row, account: account)
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.append(chat)
        }
        chatsByAccount[account.id] = sortedChatItems(chats)
        startChatListEnrichment(rows: [row], account: account, replacingCurrent: false)
    }

    private func removeChat(groupIdHex: String, account: AccountItem) {
        guard activeAccountId == account.id else { return }

        var chats = chatsByAccount[account.id] ?? []
        chats.removeAll { $0.id == groupIdHex }
        chatsByAccount[account.id] = chats
        messagesByChat[groupIdHex] = nil
        messageLookupByChat[groupIdHex] = nil
        messageIDsByChat[groupIdHex] = nil
        timelinePagingByChat[groupIdHex] = nil
        clearComposerDrafts(for: [groupIdHex], accountId: account.id)
        if timelineInitialLoadGroupId == groupIdHex {
            timelineInitialLoadGroupId = nil
        }
        lastMarkedReadMarkers[groupIdHex] = nil

        guard case .chat(let selectedGroupId) = selection,
              selectedGroupId == groupIdHex
        else { return }

        closeGroupImagePicker()
        let nextChat = mostRecentChat(in: chats)
        selection = nextChat.map { .chat($0.id) }
        pruneMessageCache(keeping: nextChat?.id)
        if let nextChat {
            beginTimelineInitialLoadIfNeeded(groupIdHex: nextChat.id)
            Task { await loadMessages(groupIdHex: nextChat.id) }
        }
    }

    private func replaceMessages(
        _ messages: [MessageItem],
        groupIdHex: String,
        paging: TimelinePagingState? = nil
    ) {
        // The window is already ordered, deduped, and capped by the runtime subscription,
        // so render it as-is.
        let nextPaging = paging ?? timelinePagingByChat[groupIdHex] ?? .empty
        let messageLookup = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let messageIDs = messages.map(\.id)

        if messagesByChat.count == 1, messagesByChat[groupIdHex] != nil {
            messagesByChat[groupIdHex] = messages
            messageLookupByChat[groupIdHex] = messageLookup
            messageIDsByChat[groupIdHex] = messageIDs
        } else {
            messagesByChat = [groupIdHex: messages]
            messageLookupByChat = [groupIdHex: messageLookup]
            messageIDsByChat = [groupIdHex: messageIDs]
        }
        if timelinePagingByChat.count == 1, timelinePagingByChat[groupIdHex] != nil {
            timelinePagingByChat[groupIdHex] = nextPaging
        } else {
            timelinePagingByChat = [groupIdHex: nextPaging]
        }
        finishTimelineInitialLoad(groupIdHex: groupIdHex)
    }

    private func pruneMessageCache(keeping groupIdHex: String?) {
        guard let groupIdHex else {
            messagesByChat = [:]
            messageLookupByChat = [:]
            messageIDsByChat = [:]
            timelinePagingByChat = [:]
            timelineInitialLoadGroupId = nil
            return
        }

        if let messages = messagesByChat[groupIdHex] {
            messagesByChat = [groupIdHex: messages]
            messageLookupByChat = [groupIdHex: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })]
            messageIDsByChat = [groupIdHex: messages.map(\.id)]
        } else {
            messagesByChat = [:]
            messageLookupByChat = [:]
            messageIDsByChat = [:]
        }
        if let paging = timelinePagingByChat[groupIdHex] {
            timelinePagingByChat = [groupIdHex: paging]
        } else {
            timelinePagingByChat = [:]
        }
        if timelineInitialLoadGroupId != groupIdHex {
            timelineInitialLoadGroupId = nil
        } else if messagesByChat[groupIdHex] != nil {
            timelineInitialLoadGroupId = nil
        }
    }

    private func beginTimelineInitialLoadIfNeeded(groupIdHex: String) {
        if messagesByChat[groupIdHex] == nil {
            timelineInitialLoadGroupId = groupIdHex
        } else if timelineInitialLoadGroupId == groupIdHex {
            timelineInitialLoadGroupId = nil
        }
    }

    private func finishTimelineInitialLoad(groupIdHex: String) {
        if timelineInitialLoadGroupId == groupIdHex {
            timelineInitialLoadGroupId = nil
        }
    }

    private func baseChatItem(from row: ChatListRowFfi, account: AccountItem) -> ChatItem {
        ChatItem(
            row: row,
            activeAccountIdHex: account.accountIdHex,
            groupAvatarURL: firstNonBlank([row.avatarUrl])
        )
    }

    private func startChatListEnrichment(
        rows: [ChatListRowFfi],
        account: AccountItem,
        replacingCurrent: Bool = true
    ) {
        guard !rows.isEmpty, client != nil else { return }

        if replacingCurrent {
            // Full-snapshot enrichment (bootstrap / reload): a fresh pass re-enriches every
            // row, so it supersedes any in-flight incremental per-row work.
            chatListEnrichmentTask?.cancel()
            chatListRowEnrichment.cancelAll()

            chatListEnrichmentTask = Task { [weak self] in
                guard let self else { return }
                await self.enrichChatRows(rows, account: account)
            }
            return
        }

        // Incremental, per-row path (chat-list subscription deltas). Track every spawned task
        // and coalesce per group so only one enrichment runs per group at a time, and so they
        // can be cancelled on listener teardown / account switch (issue #40).
        for row in rows {
            let groupId = row.groupIdHex
            // Allocate a globally unique ownership token and cancel any prior task for this
            // group. The token is never reused (even across `cancelAll()` on reload / account
            // switch), so a stale canceled task can never match a future task's token and drop
            // its tracking slot.
            let token = chatListRowEnrichment.beginTask(forGroup: groupId)

            let task = Task { [weak self] in
                guard let self else { return }
                await self.enrichChatRows([row], account: account)
                // Release this group's slot only if a newer update hasn't superseded us;
                // otherwise the newer task owns the slot and must not be dropped.
                self.chatListRowEnrichment.finishTask(forGroup: groupId, token: token)
            }
            chatListRowEnrichment.register(task: task, forGroup: groupId, token: token)
        }
    }

    private func enrichChatRows(_ rows: [ChatListRowFfi], account: AccountItem) async {
        guard let client else { return }

        var enrichedItems: [ChatItem] = []
        for row in rows {
            guard !Task.isCancelled else { return }
            enrichedItems.append(await enrichedChatItem(from: row, account: account, client: client))
        }

        guard !Task.isCancelled, activeAccountId == account.id else { return }
        applyChatMetadataEnrichment(enrichedItems, account: account)
    }

    private func applyChatMetadataEnrichment(_ enrichedItems: [ChatItem], account: AccountItem) {
        guard activeAccountId == account.id, !enrichedItems.isEmpty else { return }

        var chats = chatsByAccount[account.id] ?? []
        var didUpdate = false
        for enrichedItem in enrichedItems {
            guard let index = chats.firstIndex(where: { $0.id == enrichedItem.id }) else { continue }
            let current = chats[index]
            let next = ChatItem(
                id: current.id,
                title: enrichedItem.title,
                subtitle: enrichedItem.subtitle,
                preview: current.preview,
                updatedAt: current.updatedAt,
                avatarSeed: enrichedItem.avatarSeed,
                pictureURL: enrichedItem.pictureURL ?? current.pictureURL,
                unreadCount: current.unreadCount,
                isDirect: enrichedItem.isDirect
            )
            guard next != current else { continue }
            chats[index] = next
            didUpdate = true
        }

        if didUpdate {
            chatsByAccount[account.id] = sortedChatItems(chats)
        }
    }

    private func enrichedChatItem(
        from row: ChatListRowFfi,
        account: AccountItem,
        client: any MarmotRuntime
    ) async -> ChatItem {
        var directPeer: ChatPeerProfile?
        var groupAvatarURL = firstNonBlank([row.avatarUrl])
        if let details = try? await client.groupDetails(
            accountRef: account.accountRef,
            groupIdHex: row.groupIdHex
        ) {
            // Bail before the second FFI hop (userProfile lookup) if this enrichment has been
            // cancelled — e.g. the listener was torn down or a newer row update for this group
            // superseded us. Avoids running the rest of the wasted FFI work to completion (#40).
            guard !Task.isCancelled else {
                return ChatItem(row: row, activeAccountIdHex: account.accountIdHex)
            }
            groupAvatarURL = firstNonBlank([details.group.avatarUrl, groupAvatarURL])
            directPeer = await directPeerProfile(
                from: details,
                activeAccountIdHex: account.accountIdHex,
                client: client
            )
        }

        return ChatItem(
            row: row,
            activeAccountIdHex: account.accountIdHex,
            directPeer: directPeer,
            groupAvatarURL: groupAvatarURL
        )
    }

    private func selectMostRecentChatIfNeeded() async {
        guard selectedChat == nil,
              !isShowingSettings,
              let chat = mostRecentChat(in: activeChats)
        else { return }

        selection = .chat(chat.id)
        closeNewChatComposer()
        pruneMessageCache(keeping: chat.id)
        beginTimelineInitialLoadIfNeeded(groupIdHex: chat.id)
        await loadMessages(groupIdHex: chat.id)
    }

    private func mostRecentChat(in chatItems: [ChatItem]) -> ChatItem? {
        sortedChatItems(chatItems).first
    }

    private func sortedChatItems(_ chatItems: [ChatItem]) -> [ChatItem] {
        chatItems.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func markLatestVisibleMessageRead(
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        // A selected chat is necessary but not sufficient: only advance the read marker
        // when the app is active and the conversation window is actually visible. If the
        // user has switched away or the window is hidden/minimized, incoming live deltas
        // must not silently clear unread state for messages they have not seen — this
        // mirrors the focus gate the notification path already applies in
        // handleNotificationUpdate(_:). Marking is deferred until the conversation becomes
        // visible again (see handleConversationVisibilityChange()).
        guard selectedConversationIsVisible() else { return }
        guard let latest = (messagesByChat[groupIdHex] ?? []).last(where: { message in
            message.timelineKind == 9 && !message.isDeleted
        }) else {
            return
        }
        let marker = ReadMarker(sentAt: latest.sentAt, messageId: latest.id)
        let previousMarker = lastMarkedReadMarkers[groupIdHex]
        guard previousMarker != marker else { return }
        guard previousMarker.map({ $0 < marker }) ?? true else { return }
        lastMarkedReadMarkers[groupIdHex] = marker

        do {
            let accountRef = account.accountRef
            let messageId = latest.id
            if let row = try await runOffMain({
                try client.markTimelineMessageRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    messageIdHex: messageId
                )
            }) {
                await applyChatRow(row, account: account)
            }
        } catch {
            lastMarkedReadMarkers[groupIdHex] = previousMarker
            setBackgroundStatus(error.localizedDescription)
        }
    }

    /// Flush any read-marking that was deferred while the conversation was not visible.
    ///
    /// `markLatestVisibleMessageRead(_:)` refuses to advance the read marker while the app
    /// is inactive or its conversation window has no visible key window, so messages that
    /// arrive while the user is away stay unread. When the conversation becomes visible
    /// again it is safe to advance the marker to the latest visible message. Call this from
    /// app/window activation hooks (see ContentView).
    func handleConversationVisibilityChange() async {
        guard selectedConversationIsVisible() else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        await markLatestVisibleMessageRead(
            groupIdHex: selectedChat.id,
            account: activeAccount,
            client: client
        )
    }

    private func rememberDeliveredNotificationKey(_ key: String) {
        guard deliveredNotificationKeys.insert(key).inserted else { return }
        deliveredNotificationKeyOrder.append(key)

        while deliveredNotificationKeyOrder.count > Self.deliveredNotificationKeyLimit {
            let expiredKey = deliveredNotificationKeyOrder.removeFirst()
            deliveredNotificationKeys.remove(expiredKey)
        }
    }

    private func localNotificationsEnabled(for update: NotificationUpdateFfi) -> Bool {
        guard let client else { return false }
        guard let settings = try? client.notificationSettings(accountRef: update.accountRef) else {
            return false
        }

        if activeAccount?.accountIdHex == update.accountIdHex {
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        }

        return settings.localNotificationsEnabled
    }

    private func handleNotificationPermissionError(_ error: Error) async {
        if isNotificationsNotAllowedError(error) {
            await refreshNotificationAuthorizationStatus()
            if !notificationAuthorizationStatus.canPostNotifications {
                notificationAuthorizationStatus = .denied
            }
            lastError = Self.notificationPermissionGuidance
            return
        }

        lastError = error.localizedDescription
        await refreshNotificationAuthorizationStatus()
    }

    private func isNotificationsNotAllowedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == UNErrorDomain,
           nsError.code == UNError.Code.notificationsNotAllowed.rawValue {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("notification")
            && message.contains("not allowed")
    }

    private func localNotificationRequest(for update: NotificationUpdateFfi) -> LocalNotificationRequest {
        let senderName = firstNonBlank([
            update.sender.displayName,
            update.sender.accountIdHex
        ]) ?? L10n.string("Someone")
        let previewText = firstNonBlank([update.previewText]) ?? L10n.string("New message")

        // For an E2EE messenger, notification content is rendered as banners,
        // persisted in Notification Center, and shown on the lock screen — i.e.
        // it leaves the app's control. Honor the user's preview-privacy choice:
        // `.hidden` reveals nothing, `.senderOnly` keeps who-it's-from but never
        // the decrypted message text, `.full` is the legacy behavior. See #30.
        let previewMode = notificationPreviewMode
        let genericBody = L10n.string("New message")

        let title: String
        let body: String
        switch update.trigger {
        case .groupInvite:
            if previewMode == .hidden {
                title = L10n.string("White Noise")
                body = L10n.string("New group invite")
            } else {
                title = L10n.string("Group invite")
                body = firstNonBlank([update.groupName, senderName]) ?? L10n.string("New group invite")
            }
        case .newMessage:
            switch previewMode {
            case .full:
                if update.isDm {
                    title = senderName
                    body = previewText
                } else {
                    title = firstNonBlank([update.groupName]) ?? L10n.string("New message")
                    body = "\(senderName): \(previewText)"
                }
            case .senderOnly:
                if update.isDm {
                    title = senderName
                    body = genericBody
                } else {
                    title = firstNonBlank([update.groupName]) ?? L10n.string("New message")
                    body = senderName
                }
            case .hidden:
                title = L10n.string("White Noise")
                body = genericBody
            }
        }

        return LocalNotificationRequest(
            identifier: update.notificationKey,
            title: title,
            body: body,
            threadIdentifier: update.groupIdHex,
            userInfo: localNotificationUserInfo(for: update)
        )
    }

    private func localNotificationUserInfo(for update: NotificationUpdateFfi) -> [String: String] {
        var userInfo = [
            "accountRef": update.accountRef,
            "accountIdHex": update.accountIdHex,
            "groupIdHex": update.groupIdHex,
            "conversationKey": update.conversationKey,
            "notificationKey": update.notificationKey
        ]
        if let messageIdHex = update.messageIdHex {
            userInfo["messageIdHex"] = messageIdHex
        }
        return userInfo
    }

    private func notificationAccount(from userInfo: [String: String]) -> AccountItem? {
        let accountIdHex = userInfo["accountIdHex"]
        let accountRef = userInfo["accountRef"]
        return accounts.first { account in
            account.accountIdHex == accountIdHex
                || account.accountRef == accountRef
                || account.id == accountRef
        }
    }

    private func resetNewChatComposer() {
        invalidateNewChatLookup()
        newChatQuery = ""
        newChatName = ""
        newChatDescription = ""
        newChatRecipient = nil
    }

    private func beginNewChatLookup() -> Int {
        newChatLookupGeneration += 1
        return newChatLookupGeneration
    }

    private func invalidateNewChatLookup() {
        newChatLookupGeneration += 1
        isResolvingNewChat = false
    }

    private func isCurrentNewChatLookup(generation: Int, query: String) -> Bool {
        newChatLookupGeneration == generation
            && newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    private func insertCreatedChatIfNeeded(groupIdHex: String, title: String, avatarSeed: String, pictureURL: String?) {
        guard let activeAccountId else { return }
        var chats = chatsByAccount[activeAccountId] ?? []
        guard !chats.contains(where: { $0.id == groupIdHex }) else { return }

        chats.insert(
            ChatItem(
                id: groupIdHex,
                title: title,
                subtitle: L10n.string("Direct message"),
                preview: L10n.string("No messages yet"),
                updatedAt: nil,
                avatarSeed: avatarSeed,
                pictureURL: pictureURL,
                unreadCount: 0,
                isDirect: true
            ),
            at: 0
        )
        chatsByAccount[activeAccountId] = chats
    }

    private func directPeerProfile(
        from details: GroupDetailsFfi,
        activeAccountIdHex: String,
        client: any MarmotRuntime
    ) async -> ChatPeerProfile? {
        let otherMembers = details.members.filter { member in
            !member.isSelf && member.memberIdHex != activeAccountIdHex
        }
        guard otherMembers.count == 1,
              let otherMember = otherMembers.first
        else { return nil }

        let memberId = otherMember.memberIdHex
        let resolved = try? await runOffMain { () -> ResolvedPeerFFI in
            let profile = try? client.userProfile(accountIdHex: memberId)
            return ResolvedPeerFFI(
                profileDisplayName: profile?.displayName,
                profileName: profile?.name,
                profilePicture: profile?.picture,
                directoryDisplayName: client.displayName(accountIdHex: memberId)
            )
        }
        let displayName = firstNonBlank([
            resolved?.profileDisplayName,
            resolved?.profileName,
            otherMember.displayName,
            resolved?.directoryDisplayName
        ])

        return ChatPeerProfile(
            accountIdHex: memberId,
            displayName: displayName,
            pictureURL: resolved?.profilePicture
        )
    }

    private func messageSenderProfiles(
        from records: [TimelineMessageRecordFfi],
        groupIdHex: String,
        activeAccount: AccountItem,
        client: any MarmotRuntime
    ) async -> [String: ChatPeerProfile] {
        var groupMemberNames: [String: String] = [:]
        if let details = try? await client.groupDetails(
            accountRef: activeAccount.accountRef,
            groupIdHex: groupIdHex
        ) {
            groupMemberNames = details.members.reduce(into: [:]) { result, member in
                if let displayName = firstNonBlank([member.displayName]) {
                    result[member.memberIdHex] = displayName
                }
            }
        }

        let senderIds = Set(
            records.flatMap { record in
                [record.sender, record.replyPreview?.sender]
            }
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        )

        // Resolve any senders we have not seen before in a single off-main FFI batch,
        // then cache the raw lookups so repeated scroll-up pages skip Rust entirely.
        let unresolvedIds = senderIds.filter {
            $0 != activeAccount.accountIdHex && peerProfileFFICache[$0] == nil
        }
        if !unresolvedIds.isEmpty {
            let resolved = (try? await runOffMain { () -> [String: ResolvedPeerFFI] in
                var output: [String: ResolvedPeerFFI] = [:]
                for senderId in unresolvedIds {
                    let profile = try? client.userProfile(accountIdHex: senderId)
                    output[senderId] = ResolvedPeerFFI(
                        profileDisplayName: profile?.displayName,
                        profileName: profile?.name,
                        profilePicture: profile?.picture,
                        directoryDisplayName: client.displayName(accountIdHex: senderId)
                    )
                }
                return output
            }) ?? [:]
            for (senderId, value) in resolved {
                peerProfileFFICache[senderId] = value
            }
        }

        var profiles: [String: ChatPeerProfile] = [:]
        for senderId in senderIds {
            if senderId == activeAccount.accountIdHex {
                profiles[senderId] = ChatPeerProfile(
                    accountIdHex: senderId,
                    displayName: activeAccount.displayName,
                    pictureURL: activeAccount.pictureURL
                )
                continue
            }

            let resolved = peerProfileFFICache[senderId]
            profiles[senderId] = ChatPeerProfile(
                accountIdHex: senderId,
                displayName: firstNonBlank([
                    resolved?.profileDisplayName,
                    resolved?.profileName,
                    groupMemberNames[senderId],
                    resolved?.directoryDisplayName
                ]),
                pictureURL: resolved?.profilePicture?.nilIfBlank
            )
        }

        return profiles
    }

    private func accountItem(from summary: AccountSummaryFfi) -> AccountItem {
        let base = AccountItem(summary: summary)
        guard let client else { return base }

        let profile = try? client.userProfile(accountIdHex: summary.accountIdHex)
        let displayName = firstNonBlank([
            profile?.displayName,
            profile?.name,
            client.displayName(accountIdHex: summary.accountIdHex)
        ]) ?? base.displayName

        return AccountItem(
            id: base.id,
            accountRef: base.accountRef,
            displayName: displayName,
            accountIdHex: base.accountIdHex,
            npub: client.npub(accountIdHex: base.accountIdHex),
            pictureURL: profile?.picture,
            localSigning: base.localSigning,
            isRunning: base.isRunning
        )
    }

    private func updateActiveAccountProfile(displayName: String, pictureURL: String?) {
        guard let activeAccountId,
              let index = accounts.firstIndex(where: { $0.id == activeAccountId })
        else { return }

        let account = accounts[index]
        accounts[index] = AccountItem(
            id: account.id,
            accountRef: account.accountRef,
            displayName: displayName,
            accountIdHex: account.accountIdHex,
            npub: account.npub,
            pictureURL: pictureURL,
            localSigning: account.localSigning,
            isRunning: account.isRunning
        )
    }

    private func normalizedRelays(_ relays: [String]) -> [String] {
        var seen = Set<String>()
        return relays
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func isRelayURL(_ value: String) -> Bool {
        RelayURLValidator.isAcceptable(value)
    }

    /// Whether a saved relay uses cleartext `ws://` transport (loopback dev
    /// relay, or a pre-existing public `ws://` relay that loaded from a saved
    /// relay list) and should be surfaced as insecure in the UI.
    func isInsecureRelay(_ value: String) -> Bool {
        RelayURLValidator.isCleartext(value)
    }

    private func looksLikeMemberRef(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("npub") || lowercased.hasPrefix("nostr:npub") {
            return true
        }
        if lowercased.hasPrefix("darkmatter://profile/") {
            return true
        }
        return trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit)
    }

    private func firstNonBlank(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private var isShowingSettings: Bool {
        if case .settings = selection { return true }
        return false
    }
}

private enum GroupMemberMutationAction {
    case promote
    case demote
    case remove
}

private struct ReadMarker: Equatable, Comparable {
    let sentAt: Date
    let messageId: String

    static func < (lhs: ReadMarker, rhs: ReadMarker) -> Bool {
        if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
        return lhs.messageId < rhs.messageId
    }
}

private extension NotificationSettingsSnapshot {
    init(settings: NotificationSettingsFfi) {
        self.init(
            localNotificationsEnabled: settings.localNotificationsEnabled
        )
    }
}

struct LocalNotificationRequest: Equatable {
    let identifier: String
    let title: String
    let body: String
    let threadIdentifier: String
    let userInfo: [String: String]
}

@MainActor
protocol LocalNotificationCenter: AnyObject {
    func authorizationStatus() async -> LocalNotificationAuthorizationStatus
    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus
    func post(_ notification: LocalNotificationRequest) async throws
    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void)
}

@MainActor
final class MacLocalNotificationCenter: NSObject, LocalNotificationCenter, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var responseHandler: (@MainActor ([String: String]) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        await currentSettings().authorizationStatus.localNotificationStatus
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
        return await authorizationStatus()
    }

    func post(_ notification: LocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.threadIdentifier
        content.userInfo = notification.userInfo

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void) {
        responseHandler = handler
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) { result, element in
            guard let key = element.key as? String else { return }
            if let value = element.value as? String {
                result[key] = value
            }
        }

        Task { @MainActor [weak self] in
            self?.responseHandler?(userInfo)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func currentSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }
}

private extension UNAuthorizationStatus {
    var localNotificationStatus: LocalNotificationAuthorizationStatus {
        switch self {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .denied
        }
    }
}

struct GroupImageSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let imageURL: String
    let thumbnailURL: String?
    let creator: String?
    let license: String?
    let attribution: String?
    let sourceURL: String?
    let width: Int?
    let height: Int?

    var dimension: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)x\(height)"
    }

    var creditLine: String {
        let creatorText = creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let licenseText = license?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (creatorText?.isEmpty == false ? creatorText : nil, licenseText?.isEmpty == false ? licenseText : nil) {
        case let (creator?, license?):
            return "\(creator) · \(license.uppercased())"
        case let (creator?, nil):
            return creator
        case let (nil, license?):
            return license.uppercased()
        default:
            return L10n.string("Openverse")
        }
    }
}

protocol GroupImageSearchClient {
    func searchImages(query: String) async throws -> [GroupImageSearchResult]
}

struct OpenverseGroupImageSearchClient: GroupImageSearchClient, Sendable {
    private let endpoint = URL(string: "https://api.openverse.org/v1/images/")!

    func searchImages(query: String) async throws -> [GroupImageSearchResult] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page_size", value: "24"),
            URLQueryItem(name: "mature", value: "false")
        ]

        guard let url = components?.url else { throw GroupImageSearchError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("WhiteNoiseMac/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroupImageSearchError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GroupImageSearchError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(OpenverseImageSearchResponse.self, from: data)
        return decoded.results.compactMap(\.groupImageSearchResult)
    }
}

private struct OpenverseImageSearchResponse: Decodable {
    let results: [OpenverseImageRecord]
}

private struct OpenverseImageRecord: Decodable {
    let id: String
    let title: String?
    let url: String?
    let thumbnail: String?
    let creator: String?
    let license: String?
    let attribution: String?
    let foreignLandingURL: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case thumbnail
        case creator
        case license
        case attribution
        case foreignLandingURL = "foreign_landing_url"
        case width
        case height
    }

    var groupImageSearchResult: GroupImageSearchResult? {
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty,
              let parsedURL = URL(string: url),
              ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? "")
        else { return nil }

        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GroupImageSearchResult(
            id: id,
            title: title?.isEmpty == false ? title! : L10n.string("Untitled image"),
            imageURL: url,
            thumbnailURL: thumbnail?.nilIfBlank,
            creator: creator?.nilIfBlank,
            license: license?.nilIfBlank,
            attribution: attribution?.nilIfBlank,
            sourceURL: foreignLandingURL?.nilIfBlank,
            width: width,
            height: height
        )
    }
}

private enum GroupImageSearchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.string("Could not build the image search URL.")
        case .invalidResponse:
            return L10n.string("The image search service returned an invalid response.")
        case .requestFailed(let statusCode):
            return String(format: L10n.string("Image search failed with HTTP status %d."), statusCode)
        }
    }
}

private struct PreviewRuntimeError: Error {}

private extension ProfileDraft {
    init(fallbackName: String) {
        self.init(name: "", displayName: fallbackName, about: "", picture: "", nip05: "", lud16: "")
    }

    init(profile: UserProfileMetadataFfi?, fallbackName: String) {
        self.init(
            name: profile?.name ?? "",
            displayName: profile?.displayName ?? fallbackName,
            about: profile?.about ?? "",
            picture: profile?.picture ?? "",
            nip05: profile?.nip05 ?? "",
            lud16: profile?.lud16 ?? ""
        )
    }

    var metadata: UserProfileMetadataFfi {
        UserProfileMetadataFfi(
            name: name.nilIfBlank,
            displayName: displayName.nilIfBlank,
            about: about.nilIfBlank,
            picture: picture.nilIfBlank,
            nip05: nip05.nilIfBlank,
            lud16: lud16.nilIfBlank
        )
    }

    func primaryDisplayName(fallback: String) -> String {
        for value in [displayName, name, fallback] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }
}

private extension RelaySettingsSnapshot {
    init(lists: AccountRelayListsFfi) {
        self.init(
            nip65: lists.nip65.relays.isEmpty ? lists.defaultRelays : lists.nip65.relays,
            inbox: lists.inbox.relays.isEmpty ? lists.defaultRelays : lists.inbox.relays,
            defaultRelays: lists.defaultRelays,
            bootstrapRelays: lists.bootstrapRelays,
            publishedNip65: lists.nip65.relays,
            publishedInbox: lists.inbox.relays,
            missing: lists.missing,
            isComplete: lists.complete
        )
    }
}

private extension KeyPackageItem {
    init(package: AccountKeyPackageFfi) {
        self.init(
            accountRef: package.accountRef,
            accountIdHex: package.accountIdHex,
            keyPackageId: package.keyPackageId,
            keyPackageRefHex: package.keyPackageRefHex,
            eventIdHex: package.eventIdHex,
            publishedAt: package.publishedAt == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(package.publishedAt)),
            keyPackageBytes: package.keyPackageBytes,
            sourceRelays: package.sourceRelays,
            isLocal: package.local,
            isRelayDiscovered: package.relay
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
