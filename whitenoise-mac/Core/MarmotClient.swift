import Foundation
import MarmotKit

protocol MarmotRuntime {
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
    func publishUserProfile(accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]) async throws -> UserProfileMetadataFfi
    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi
    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi]
    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi
    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi
    func publishNewKeyPackage(accountRef: String) async throws -> UInt64
    func republishKeyPackage(accountRef: String) async throws -> UInt64
    func deleteAccountKeyPackage(accountRef: String, eventIdHex: String, relays: [String]) async throws -> UInt64
    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi
    func setAccountKeyPackageRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi
    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi
    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws -> String
    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi
    func chatList(accountRef: String, includeArchived: Bool) throws -> [ChatListRowFfi]
    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription
    func subscribeChats(accountRef: String, includeArchived: Bool) async throws -> ChatsSubscription
    func subscribeNotifications() async throws -> NotificationsSubscription
    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi
    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws -> TimelineMessagesSubscription
    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi?
    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi?
    func messages(accountRef: String, groupIdHex: String?, limit: UInt32?) throws -> [AppMessageRecordFfi]
    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi
    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws -> SendSummaryFfi
    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws -> SendSummaryFfi
    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi
}

final class MarmotClient: MarmotRuntime {
    static let seedRelays: [String] = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net"
    ]

    let marmot: Marmot
    let rootPath: String
    var storageRootPath: String { rootPath }

    convenience init() throws {
        try self.init(rootPath: Self.applicationSupportRoot(), relayUrls: Self.seedRelays)
    }

    static func defaultStorageRootPath() -> String {
        applicationSupportRoot()
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

    func publishUserProfile(accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]) async throws -> UserProfileMetadataFfi {
        try await marmot.publishUserProfile(
            accountRef: accountRef,
            profile: profile,
            defaultRelays: defaultRelays,
            bootstrapRelays: bootstrapRelays
        )
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        try marmot.accountRelayLists(accountRef: accountRef)
    }

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        try await marmot.accountKeyPackages(accountRef: accountRef, bootstrapRelays: bootstrapRelays)
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        try marmot.notificationSettings(accountRef: accountRef)
    }

    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi {
        try marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: enabled)
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

    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        try await marmot.setAccountInboxRelays(
            accountRef: accountRef,
            relays: relays,
            bootstrapRelays: bootstrapRelays
        )
    }

    func setAccountKeyPackageRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        try await marmot.setAccountKeyPackageRelays(
            accountRef: accountRef,
            relays: relays,
            bootstrapRelays: bootstrapRelays
        )
    }

    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws -> AccountRelayListsFfi {
        try await marmot.setAccountNip65Relays(
            accountRef: accountRef,
            relays: relays,
            bootstrapRelays: bootstrapRelays
        )
    }

    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws -> String {
        try await marmot.createGroup(
            accountRef: accountRef,
            name: name,
            memberRefs: memberRefs,
            description: description
        )
    }

    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi {
        try await marmot.groupDetails(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func chatList(accountRef: String, includeArchived: Bool) throws -> [ChatListRowFfi] {
        try marmot.chatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription {
        try await marmot.subscribeChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func subscribeChats(accountRef: String, includeArchived: Bool) async throws -> ChatsSubscription {
        try await marmot.subscribeChats(accountRef: accountRef, includeArchived: includeArchived)
    }

    func subscribeNotifications() async throws -> NotificationsSubscription {
        try await marmot.subscribeNotifications()
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        try marmot.timelineMessages(accountRef: accountRef, query: query)
    }

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws -> TimelineMessagesSubscription {
        try await marmot.subscribeTimelineMessages(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            limit: limit
        )
    }

    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi? {
        try marmot.initializeChatReadState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi? {
        try marmot.markTimelineMessageRead(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            messageIdHex: messageIdHex
        )
    }

    func messages(accountRef: String, groupIdHex: String?, limit: UInt32?) throws -> [AppMessageRecordFfi] {
        try marmot.messages(accountRef: accountRef, groupIdHex: groupIdHex, limit: limit)
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        try await marmot.sendText(accountRef: accountRef, groupIdHex: groupIdHex, text: text)
    }

    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws -> SendSummaryFfi {
        try await marmot.replyToMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageId,
            text: text
        )
    }

    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws -> SendSummaryFfi {
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

    private static func applicationSupportRoot() -> String {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let root = base
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Marmot", isDirectory: true)

        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        return root.path
    }
}
