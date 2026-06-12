import AppKit
import Darwin
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

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

    private(set) var phase: Phase = .bootstrapping
    private(set) var accounts: [AccountItem]
    private(set) var chatsByAccount: [String: [ChatItem]]
    private(set) var messagesByChat: [String: [MessageItem]]
    private(set) var lastError: String?

    var activeAccountId: String?
    var selection: WorkspaceSelection?
    var searchText = ""
    var isChatListVisible = true
    var draftText = ""
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
    var developerMode: Bool {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: Self.developerModeKey)
        }
    }
    var appearancePreference: AppearancePreference {
        didSet {
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: Self.appearancePreferenceKey)
        }
    }
    var languagePreference: AppLanguage {
        didSet {
            UserDefaults.standard.set(languagePreference.rawValue, forKey: AppLanguage.storageKey)
        }
    }
    var isLoadingSettings = false
    var isSavingProfile = false
    var isSavingRelays = false
    var isPublishingKeyPackage = false
    var isRepublishingKeyPackage = false
    var isSavingNotifications = false
    var isSavingPrivacySecurity = false
    var deletingKeyPackageId: String?
    var isNewChatComposerVisible = false
    var newChatQuery = ""
    var newChatName = ""
    var newChatDescription = ""
    var newChatRecipient: NewChatRecipient?
    var replyDraftContext: MessageReplyContext?
    var isResolvingNewChat = false
    var isCreatingChat = false
    var isGroupImagePickerPresented = false
    var groupImageSearchQuery = ""
    var groupImageResults: [GroupImageSearchResult] = []
    var isSearchingGroupImages = false
    var isSavingGroupImage = false
    private(set) var storageRootPath = MarmotClient.defaultStorageRootPath()

    private let clientFactory: @MainActor () throws -> any MarmotRuntime
    private let localNotificationCenter: any LocalNotificationCenter
    private let appActivityProvider: @MainActor () -> Bool
    private let copyTextHandler: @MainActor (String) -> Void
    private let observabilityTokenProvider: @MainActor () -> String?
    private let groupImageSearchClient: any GroupImageSearchClient
    private var client: (any MarmotRuntime)?
    private var notificationTask: Task<Void, Never>?
    private var chatListTask: Task<Void, Never>?
    private var chatListTaskAccountId: String?
    private var timelineTask: Task<Void, Never>?
    private var timelineTaskGroupId: String?
    private var lastMarkedReadMarkers: [String: ReadMarker] = [:]
    private var profileRefreshAccountIds = Set<String>()
    private var deliveredNotificationKeys = Set<String>()
    private var deliveredNotificationKeyOrder: [String] = []
    private var newChatLookupGeneration = 0

    private static let activeAccountKey = "whitenoise.mac.activeAccountId"
    private static let developerModeKey = "whitenoise.mac.developerMode"
    private static let appearancePreferenceKey = "whitenoise.mac.appearancePreference"
    private static let observabilityTokenInfoKey = "OTLP_TOKEN_DARKMATTER_MAC"
    private static let deploymentEnvironment = "production"
    private static let telemetryTenant = "whitenoise-mac"
    private static let deliveredNotificationKeyLimit = 256
    private static var notificationPermissionGuidance: String {
        L10n.string("Open System Settings > Notifications and allow White Noise notifications, then try again.")
    }
    private static var missingObservabilityTokenMessage: String {
        L10n.string("Missing OTLP_TOKEN_DARKMATTER_MAC environment variable.")
    }

    init(
        accounts: [AccountItem] = [],
        chatsByAccount: [String: [ChatItem]] = [:],
        messagesByChat: [String: [MessageItem]] = [:],
        localNotificationCenter: (any LocalNotificationCenter)? = nil,
        appActivityProvider: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
        copyTextHandler: @escaping @MainActor (String) -> Void = WorkspaceState.copyToGeneralPasteboard,
        observabilityTokenProvider: @escaping @MainActor () -> String? = WorkspaceState.defaultObservabilityToken,
        groupImageSearchClient: (any GroupImageSearchClient)? = nil,
        clientFactory: @escaping @MainActor () throws -> any MarmotRuntime = { try MarmotClient() }
    ) {
        self.accounts = accounts
        self.chatsByAccount = chatsByAccount
        self.messagesByChat = messagesByChat
        self.localNotificationCenter = localNotificationCenter ?? MacLocalNotificationCenter()
        self.appActivityProvider = appActivityProvider
        self.copyTextHandler = copyTextHandler
        self.observabilityTokenProvider = observabilityTokenProvider
        self.groupImageSearchClient = groupImageSearchClient ?? OpenverseGroupImageSearchClient()
        self.clientFactory = clientFactory
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearancePreferenceKey)
        self.appearancePreference = storedAppearance.flatMap(AppearancePreference.init(rawValue:)) ?? .system
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

    var marmotBuildSummary: String {
        "\(MarmotKitVersion.darkmatterSHA) / \(MarmotKitVersion.builtAt)"
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

            try await runtime.start()
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
        activeAccountId = account.id
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        searchText = ""
        draftText = ""
        replyDraftContext = nil
        closeNewChatComposer()
        pruneMessageCache(keeping: nil)
        refreshObservabilityRuntime()
        selection = activeChats.first.map { .chat($0.id) }
        Task { await reloadChats() }
    }

    func selectAccountFromSettings(_ account: AccountItem) {
        stopTimelineListener()
        activeAccountId = account.id
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        searchText = ""
        draftText = ""
        replyDraftContext = nil
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
        selection = .chat(chat.id)
        draftText = ""
        replyDraftContext = nil
        closeNewChatComposer()
        pruneMessageCache(keeping: chat.id)
        Task { await loadMessages(groupIdHex: chat.id) }
    }

    func showNewChat() {
        isNewChatComposerVisible = true
        draftText = ""
        replyDraftContext = nil
        lastError = nil
        resetNewChatComposer()
    }

    func closeNewChatComposer() {
        isNewChatComposerVisible = false
        resetNewChatComposer()
    }

    func showSettings(_ page: SettingsPage = .profile) {
        stopTimelineListener()
        selection = .settings(page)
        draftText = ""
        replyDraftContext = nil
        closeNewChatComposer()
        pruneMessageCache(keeping: nil)
    }

    func showSettingsPage(_ page: SettingsPage) {
        showSettings(page)
    }

    func showLogin() {
        authenticationMode = .login
        loginIdentity = ""
        lastError = nil
    }

    func cancelLogin() {
        authenticationMode = .landing
        loginIdentity = ""
        lastError = nil
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
        defer { isAuthenticating = false }

        do {
            let summary = try await client.login(
                identity: identity,
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
            )
            try refreshAccounts(preferred: summary)
            loginIdentity = ""
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
                bootstrapRelays: MarmotClient.seedRelays
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
            let relays = package.sourceRelays.isEmpty ? relaySettings.nip65 : package.sourceRelays
            _ = try await client.deleteAccountKeyPackage(
                accountRef: activeAccount.accountRef,
                eventIdHex: package.eventIdHex,
                relays: relays
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
            lastError = L10n.string("Relay URLs must start with ws:// or wss://")
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
            lastError = L10n.string("Relay URLs must start with ws:// or wss://")
            return
        }

        lastError = nil
        isSavingRelays = true
        defer { isSavingRelays = false }

        do {
            let lists: AccountRelayListsFfi
            switch selectedRelaySection {
            case .nip65:
                lists = try await client.setAccountNip65Relays(
                    accountRef: activeAccount.accountRef,
                    relays: relays,
                    bootstrapRelays: MarmotClient.seedRelays
                )
            case .inbox:
                lists = try await client.setAccountInboxRelays(
                    accountRef: activeAccount.accountRef,
                    relays: relays,
                    bootstrapRelays: MarmotClient.seedRelays
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
                defaultRelays: MarmotClient.seedRelays,
                bootstrapRelays: MarmotClient.seedRelays
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

            await applyChatRows(subscription.snapshot(), account: activeAccount, client: client)
            startChatListListener(account: activeAccount, subscription: subscription)

            if selectedChat == nil, !isShowingSettings {
                selection = activeChats.first.map { .chat($0.id) }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMessages(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        stopTimelineListener()
        guard selectedChat?.id == groupIdHex else { return }
        do {
            if let row = try client.initializeChatReadState(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            ) {
                await applyChatRow(row, account: activeAccount, client: client)
            }

            let subscription = try await client.subscribeTimelineMessages(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                limit: 200
            )
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }

            let page = subscription.snapshot() ?? TimelinePageFfi(
                messages: [],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
            let senderProfiles = await messageSenderProfiles(
                from: page.messages,
                groupIdHex: groupIdHex,
                activeAccount: activeAccount,
                client: client
            )
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }

            replaceMessages(
                MessageItem.timeline(
                    from: page,
                    activeAccountIdHex: activeAccount.accountIdHex,
                    senderProfiles: senderProfiles
                ),
                groupIdHex: groupIdHex
            )
            await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: activeAccount, client: client)
            startTimelineListener(groupIdHex: groupIdHex, account: activeAccount, subscription: subscription)
        } catch {
            lastError = error.localizedDescription
        }
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
        copyText(message.body)
    }

    func copyText(_ text: String) {
        copyTextHandler(text)
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

    func deleteMessage(_ message: MessageItem) async {
        guard message.supportsChatActions else { return }
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

    func showGroupImagePicker(for chat: ChatItem) {
        guard !chat.isDirect else { return }
        lastError = nil
        groupImageSearchQuery = chat.title
        groupImageResults = []
        isGroupImagePickerPresented = true
    }

    func closeGroupImagePicker() {
        isGroupImagePickerPresented = false
        groupImageResults = []
        isSearchingGroupImages = false
        isSavingGroupImage = false
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

        if appActivityProvider(), selectedChat?.id == update.groupIdHex {
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
            lastError = error.localizedDescription
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
        draftText = ""
        replyDraftContext = nil
        closeNewChatComposer()
        pruneMessageCache(keeping: groupIdHex)
        NSApplication.shared.activate(ignoringOtherApps: true)

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
        draftText = ""
        replyDraftContext = nil
        selection = nil
    }

    private static func copyToGeneralPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var observabilityToken: String? {
        Self.nonBlank(observabilityTokenProvider())
    }

    private static func defaultObservabilityToken() -> String? {
        nonBlank(ProcessInfo.processInfo.environment[observabilityTokenInfoKey])
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static var appVersion: String {
        let shortVersion = nonBlank(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let buildVersion = nonBlank(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
        return "\(shortVersion)+\(buildVersion)"
    }

    private static var deviceModelIdentifier: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return nonBlank(String(cString: value))
    }

    private func refreshObservabilityRuntime() {
        Task { [weak self] in
            do {
                try await self?.configureObservabilityRuntime()
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func configureObservabilityRuntime() async throws {
        guard let client else { return }
        let token = observabilityToken
        try await client.setRelayTelemetryRuntimeConfig(
            config: RelayTelemetryRuntimeConfigFfi(
                otlpEndpoint: nil,
                authorizationBearerToken: token,
                resource: try telemetryResource(client: client)
            )
        )
        _ = try client.setAuditLogTrackerConfig(
            config: AuditLogTrackerConfigFfi(
                endpoint: nil,
                authorizationBearerToken: token,
                source: auditLogUploadSource(account: activeAccount)
            )
        )
        privacySecuritySettings.hasObservabilityToken = token != nil
    }

    private func telemetryResource(client: any MarmotRuntime) throws -> RelayTelemetryResourceFfi {
        RelayTelemetryResourceFfi(
            serviceVersion: Self.appVersion,
            serviceInstanceId: try client.telemetryInstallId(),
            deploymentEnvironment: Self.deploymentEnvironment,
            tenant: Self.telemetryTenant,
            osType: "darwin",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModelIdentifier: Self.deviceModelIdentifier
        )
    }

    private func auditLogUploadSource(account: AccountItem?) -> AuditLogUploadSourceFfi {
        AuditLogUploadSourceFfi(
            accountLabel: account?.displayName,
            deviceLabel: Host.current().localizedName,
            platform: "macOS",
            appVersion: Self.appVersion
        )
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
            privacySecuritySettings = PrivacySecuritySettingsSnapshot(
                relayTelemetryEnabled: telemetry.exportEnabled,
                relayTelemetryIntervalSeconds: telemetry.exportIntervalSeconds,
                auditLogUploadsEnabled: auditLog.enabled,
                hasObservabilityToken: observabilityToken != nil
            )
        } catch {
            privacySecuritySettings = .defaults
            lastError = error.localizedDescription
        }
    }

    func setRelayTelemetryEnabled(_ enabled: Bool) async {
        guard let client, !isSavingPrivacySecurity else { return }
        guard enabled == false || observabilityToken != nil else {
            lastError = Self.missingObservabilityTokenMessage
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
            privacySecuritySettings.hasObservabilityToken = observabilityToken != nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setAuditLogUploadsEnabled(_ enabled: Bool) async {
        guard let client, !isSavingPrivacySecurity else { return }
        guard enabled == false || observabilityToken != nil else {
            lastError = Self.missingObservabilityTokenMessage
            return
        }

        lastError = nil
        isSavingPrivacySecurity = true
        defer { isSavingPrivacySecurity = false }

        do {
            try await configureObservabilityRuntime()
            let stored = try await client.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: enabled))
            privacySecuritySettings.auditLogUploadsEnabled = stored.enabled
            privacySecuritySettings.hasObservabilityToken = observabilityToken != nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startNotificationListener() {
        guard notificationTask == nil, client != nil else { return }
        notificationTask = Task { [weak self] in
            await self?.runNotificationListener()
        }
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
            lastError = error.localizedDescription
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
                await applyChatRows(subscription.snapshot(), account: account, client: client)
            }

            while !Task.isCancelled {
                guard let update = await subscription.nextUpdate() else { break }
                guard !Task.isCancelled else { break }
                await applyChatListSubscriptionUpdate(update, account: account, client: client)
            }
        } catch is CancellationError {
            return
        } catch {
            if activeAccountId == account.id {
                lastError = error.localizedDescription
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
                    limit: 200
                )
            }

            while !Task.isCancelled {
                guard let update = await subscription.nextUpdate() else { break }
                guard !Task.isCancelled else { break }
                await applyTimelineSubscriptionUpdate(
                    update,
                    groupIdHex: groupIdHex,
                    account: account,
                    client: client
                )
            }
        } catch is CancellationError {
            return
        } catch {
            if activeAccountId == account.id, selectedChat?.id == groupIdHex {
                lastError = error.localizedDescription
            }
        }

        if timelineTaskGroupId == groupIdHex && !Task.isCancelled {
            timelineTask = nil
            timelineTaskGroupId = nil
        }
    }

    private func applyChatRows(
        _ rows: [ChatListRowFfi],
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id else { return }

        var chatItems: [ChatItem] = []
        for row in rows {
            chatItems.append(await chatItem(from: row, account: account, client: client))
        }
        chatsByAccount[account.id] = sortedChatItems(chatItems)
    }

    private func applyChatListSubscriptionUpdate(
        _ update: ChatListSubscriptionUpdateFfi,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        switch update {
        case .row(trigger: _, row: let row):
            await applyChatRow(row, account: account, client: client)
        case .removeRow(trigger: _, groupIdHex: let groupIdHex):
            removeChat(groupIdHex: groupIdHex, account: account)
        }
    }

    private func applyChatRow(
        _ row: ChatListRowFfi,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id else { return }

        var chats = chatsByAccount[account.id] ?? []
        if row.archived {
            removeChat(groupIdHex: row.groupIdHex, account: account)
            return
        }

        let chat = await chatItem(from: row, account: account, client: client)
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.append(chat)
        }
        chatsByAccount[account.id] = sortedChatItems(chats)
    }

    private func removeChat(groupIdHex: String, account: AccountItem) {
        guard activeAccountId == account.id else { return }

        var chats = chatsByAccount[account.id] ?? []
        chats.removeAll { $0.id == groupIdHex }
        chatsByAccount[account.id] = chats
        messagesByChat[groupIdHex] = nil
        lastMarkedReadMarkers[groupIdHex] = nil

        guard case .chat(let selectedGroupId) = selection,
              selectedGroupId == groupIdHex
        else { return }

        let nextChat = chats.first
        selection = nextChat.map { .chat($0.id) }
        pruneMessageCache(keeping: nextChat?.id)
        if let nextChat {
            Task { await loadMessages(groupIdHex: nextChat.id) }
        }
    }

    private func replaceMessages(_ messages: [MessageItem], groupIdHex: String) {
        messagesByChat = [groupIdHex: messages]
    }

    private func pruneMessageCache(keeping groupIdHex: String?) {
        guard let groupIdHex else {
            messagesByChat = [:]
            return
        }

        if let messages = messagesByChat[groupIdHex] {
            messagesByChat = [groupIdHex: messages]
        } else {
            messagesByChat = [:]
        }
    }

    private func applyTimelinePage(
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
        replaceMessages(
            MessageItem.timeline(
                from: page,
                activeAccountIdHex: account.accountIdHex,
                senderProfiles: senderProfiles
            ),
            groupIdHex: groupIdHex
        )
        await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: account, client: client)
    }

    private func applyTimelineSubscriptionUpdate(
        _ update: TimelineSubscriptionUpdateFfi,
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        switch update {
        case .page(page: let page):
            await applyTimelinePage(page, groupIdHex: groupIdHex, account: account, client: client)
        case .projection(update: let runtimeUpdate):
            await applyTimelineProjectionUpdate(
                runtimeUpdate.update,
                groupIdHex: groupIdHex,
                account: account,
                client: client
            )
        }
    }

    private func applyTimelineProjectionUpdate(
        _ update: TimelineProjectionUpdateFfi,
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard update.groupIdHex == groupIdHex else { return }
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }

        var upsertRecords = update.messages
        var removedMessageIds = Set<String>()
        for change in update.changes {
            switch change {
            case .upsert(trigger: _, message: let message):
                upsertRecords.append(message)
            case .remove(messageIdHex: let messageIdHex, reason: _):
                removedMessageIds.insert(messageIdHex)
            }
        }

        if !removedMessageIds.isEmpty {
            removeTimelineMessages(withIds: removedMessageIds, groupIdHex: groupIdHex)
        }
        if !upsertRecords.isEmpty {
            let senderProfiles = await messageSenderProfiles(
                from: upsertRecords,
                groupIdHex: groupIdHex,
                activeAccount: account,
                client: client
            )
            guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }

            let page = TimelinePageFfi(
                messages: upsertRecords,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
            let newMessages = MessageItem.timeline(
                from: page,
                activeAccountIdHex: account.accountIdHex,
                senderProfiles: senderProfiles
            )
            mergeTimelineMessages(newMessages, groupIdHex: groupIdHex)
            await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: account, client: client)
        }

        if let row = update.chatListRow {
            await applyChatRow(row, account: account, client: client)
        }
    }

    private func removeTimelineMessages(withIds messageIds: Set<String>, groupIdHex: String) {
        guard !messageIds.isEmpty else { return }
        var messages = messagesByChat[groupIdHex] ?? []
        messages.removeAll { messageIds.contains($0.id) }
        replaceMessages(messages, groupIdHex: groupIdHex)
        if let targetMessageId = replyDraftContext?.targetMessageId,
           messageIds.contains(targetMessageId) {
            replyDraftContext = nil
        }
    }

    private func mergeTimelineMessages(_ newMessages: [MessageItem], groupIdHex: String) {
        guard !newMessages.isEmpty else { return }

        var messagesById = Dictionary(
            uniqueKeysWithValues: (messagesByChat[groupIdHex] ?? []).map { ($0.id, $0) }
        )
        for message in newMessages {
            messagesById[message.id] = message
        }
        replaceMessages(
            messagesById.values.sorted { lhs, rhs in
                if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
                return lhs.id < rhs.id
            },
            groupIdHex: groupIdHex
        )
    }

    private func chatItem(
        from row: ChatListRowFfi,
        account: AccountItem,
        client: any MarmotRuntime
    ) async -> ChatItem {
        var directPeer: ChatPeerProfile?
        var groupAvatarURL: String?
        if let details = try? await client.groupDetails(
            accountRef: account.accountRef,
            groupIdHex: row.groupIdHex
        ) {
            groupAvatarURL = firstNonBlank([details.group.avatarUrl])
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
            if let row = try client.markTimelineMessageRead(
                accountRef: account.accountRef,
                groupIdHex: groupIdHex,
                messageIdHex: latest.id
            ) {
                await applyChatRow(row, account: account, client: client)
            }
        } catch {
            lastMarkedReadMarkers[groupIdHex] = previousMarker
            lastError = error.localizedDescription
        }
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

        let title: String
        let body: String
        switch update.trigger {
        case .groupInvite:
            title = L10n.string("Group invite")
            body = firstNonBlank([update.groupName, senderName]) ?? L10n.string("New group invite")
        case .newMessage:
            if update.isDm {
                title = senderName
                body = previewText
            } else {
                title = firstNonBlank([update.groupName]) ?? L10n.string("New message")
                body = "\(senderName): \(previewText)"
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

        if !profileRefreshAccountIds.contains(otherMember.memberIdHex) {
            profileRefreshAccountIds.insert(otherMember.memberIdHex)
            let profileRelays = details.group.relays.isEmpty ? MarmotClient.seedRelays : details.group.relays
            try? await client.refreshProfile(accountIdHex: otherMember.memberIdHex, relays: profileRelays)
        }
        let profile = try? client.userProfile(accountIdHex: otherMember.memberIdHex)
        let displayName = firstNonBlank([
            profile?.displayName,
            profile?.name,
            otherMember.displayName,
            client.displayName(accountIdHex: otherMember.memberIdHex)
        ])

        return ChatPeerProfile(
            accountIdHex: otherMember.memberIdHex,
            displayName: displayName,
            pictureURL: profile?.picture
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

            let cachedProfile = try? client.userProfile(accountIdHex: senderId)
            let cachedName = firstNonBlank([
                cachedProfile?.displayName,
                cachedProfile?.name,
                groupMemberNames[senderId],
                client.displayName(accountIdHex: senderId)
            ])
            let cachedPicture = firstNonBlank([cachedProfile?.picture])

            if (cachedName == nil || cachedPicture == nil), !profileRefreshAccountIds.contains(senderId) {
                profileRefreshAccountIds.insert(senderId)
                try? await client.refreshProfile(accountIdHex: senderId, relays: MarmotClient.seedRelays)
            }

            let refreshedProfile = try? client.userProfile(accountIdHex: senderId)
            profiles[senderId] = ChatPeerProfile(
                accountIdHex: senderId,
                displayName: firstNonBlank([
                    refreshedProfile?.displayName,
                    refreshedProfile?.name,
                    cachedName,
                    groupMemberNames[senderId],
                    client.displayName(accountIdHex: senderId)
                ]),
                pictureURL: firstNonBlank([
                    refreshedProfile?.picture,
                    cachedPicture
                ])
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
        value.hasPrefix("wss://") || value.hasPrefix("ws://")
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
            localNotificationsEnabled: settings.localNotificationsEnabled,
            nativePushEnabled: settings.nativePushEnabled
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
            inbox: lists.inbox.relays.isEmpty ? lists.defaultRelays : lists.inbox.relays
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
