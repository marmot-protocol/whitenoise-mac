//
//  TestFixtures.swift
//  whitenoise-macTests
//
//  FFI value fixtures, subscription fakes and URL-protocol stubs shared by the suites
//  split out of `whitenoise_macTests.swift`. Moved verbatim from that file, `private`
//  dropped so every suite can reach them.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

var discoverySearcherAccount: AccountSummaryFfi {
    AccountSummaryFfi(
        label: "Searcher Account",
        accountIdHex: String(repeating: "5", count: 64),
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: false,
        unlinked: false
    )
}

/// Records which account ids `userProfile` was queried for, from whatever thread the runtime's
/// off-main profile batch happens to run on.
final class ProfileLookupLog: @unchecked Sendable {
    private let lock = NSLock()
    private var hexes: [String] = []

    func record(_ accountIdHex: String) {
        lock.withLock { hexes.append(accountIdHex) }
    }

    var recorded: [String] {
        lock.withLock { hexes }
    }
}

/// 64-char hex from a short seed, so the discovery fixtures read as `discoveryHex("b")`. A seed
/// that is already a full hex passes straight through.
func discoveryHex(_ seed: String) -> String {
    String((seed + String(repeating: "0", count: 64)).prefix(64))
}

func searchResult(
    hex seed: String,
    radius: UInt8,
    matchedField: MatchedFieldFfi = .name,
    matchQuality: MatchQualityFfi = .exact,
    providerRank: Double? = nil,
    displayName: String? = nil,
    picture: String? = nil
) -> UserDirectorySearchResultFfi {
    UserDirectorySearchResultFfi(
        accountIdHex: discoveryHex(seed),
        npub: "npub1\(seed.prefix(8))",
        radius: radius,
        isFollowedBySearcher: false,
        matchedField: matchedField,
        matchQuality: matchQuality,
        providerRank: providerRank,
        profile: UserProfileMetadataFfi(
            name: nil,
            displayName: displayName,
            about: nil,
            picture: picture,
            nip05: nil,
            lud16: nil
        )
    )
}

func userSearchUpdate(
    _ trigger: SearchUpdateTriggerFfi,
    _ results: [UserDirectorySearchResultFfi]
) -> UserSearchUpdateFfi {
    UserSearchUpdateFfi(
        trigger: trigger,
        newResults: results,
        updatedResults: [],
        totalResultCount: UInt32(results.count)
    )
}

func sortedDiscoveryHexes(_ people: [DiscoveredPerson]) -> [String] {
    UserDiscoveryRanking.sortedUnique(people).map(\.accountIdHex)
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses. The people search
/// debounces for 300 ms before it even calls the runtime, so every assertion about its outcome has
/// to wait rather than yield.
@MainActor
func pollUserDiscovery(
    timeout: Duration = .seconds(3),
    until condition: @MainActor () -> Bool
) async -> Bool {
    let step = Duration.milliseconds(10)
    var elapsed = Duration.zero
    while elapsed < timeout {
        if condition() { return true }
        try? await Task.sleep(for: step)
        elapsed += step
    }
    return condition()
}

actor FakeGroupImageSearchClient: GroupImageSearchClient {
    private let results: [GroupImageSearchResult]
    private(set) var queries: [String] = []

    init(results: [GroupImageSearchResult]) {
        self.results = results
    }

    func searchImages(query: String) async throws -> [GroupImageSearchResult] {
        queries.append(query)
        return results
    }
}

actor FakeGroupImageSourceLoader: GroupImageSourceLoading {
    private let response: Data?
    private(set) var requestedURLs: [URL] = []

    init(response: Data?) {
        self.response = response
    }

    func data(for url: URL) async -> Data? {
        requestedURLs.append(url)
        return response
    }
}

/// `StubNIP05Resolver` that also records what it was asked about, so a test can pin *which*
/// address a check went out for instead of inferring it from the verdict — the two are the same
/// value in every case but the one that matters.
final class RecordingNIP05Resolver: NIP05Resolving {
    let accountReferences: [String: String]
    private(set) var requestedIdentifiers: [String] = []

    init(accountReferences: [String: String]) {
        self.accountReferences = accountReferences
    }

    func accountReference(for identifier: String) async throws -> String {
        requestedIdentifiers.append(identifier)
        guard let reference = accountReferences[identifier] else {
            throw NIP05ResolutionError.notFound
        }
        return reference
    }
}

struct StubNIP05Resolver: NIP05Resolving {
    let accountReferences: [String: String]

    func accountReference(for identifier: String) async throws -> String {
        guard let reference = accountReferences[identifier] else {
            throw NIP05ResolutionError.notFound
        }
        return reference
    }
}

struct MediaResolutionFixture {
    let message: MessageItem
    let attachment: MessageMediaAttachment
    let plaintext: Data
    let expectedSourceEpoch: UInt64
}

// Models the runtime's authoritative, bounded, materialized timeline window: a sliding
// [lo, hi) window over the full ordered message set, capped at `windowCap`, extended by
// `paginateBackwards`/`paginateForwards` and mutated by live `next()` updates. Mirrors the
// marmot-app windowing contract closely enough for client-level tests; the exact math is
// unit-tested in Rust.

@MainActor
final class FakeLocalNotificationCenter: LocalNotificationCenter {
    private(set) var status: LocalNotificationAuthorizationStatus
    private let requestedStatus: LocalNotificationAuthorizationStatus
    private let requestError: Error?
    private let postError: Error?
    private(set) var didRequestAuthorization = false
    var requestAuthorizationGateEnabled = false
    private(set) var didReachRequestAuthorizationGate = false
    private var requestAuthorizationGateContinuation: CheckedContinuation<Void, Never>?
    private(set) var postedRequests: [LocalNotificationRequest] = []
    private var responseHandler: (@MainActor ([String: String]) -> Void)?

    init(
        status: LocalNotificationAuthorizationStatus = .authorized,
        requestedStatus: LocalNotificationAuthorizationStatus = .authorized,
        requestError: Error? = nil,
        postError: Error? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
        self.requestError = requestError
        self.postError = postError
    }

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus {
        didRequestAuthorization = true
        if requestAuthorizationGateEnabled {
            didReachRequestAuthorizationGate = true
            await withCheckedContinuation { continuation in
                requestAuthorizationGateContinuation = continuation
            }
        }
        if let requestError {
            throw requestError
        }
        status = requestedStatus
        return status
    }

    /// Mimics the user flipping the permission in System Settings while White Noise is in the
    /// background — the app learns about it only on the next `authorizationStatus()` read.
    func simulateSystemAuthorizationChange(_ newStatus: LocalNotificationAuthorizationStatus) {
        status = newStatus
    }

    func releaseRequestAuthorizationGate() {
        requestAuthorizationGateContinuation?.resume()
        requestAuthorizationGateContinuation = nil
    }

    func post(_ notification: LocalNotificationRequest) async throws {
        if let postError {
            throw postError
        }
        postedRequests.append(notification)
    }

    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void) {
        responseHandler = handler
    }

    func simulateResponse(_ userInfo: [String: String]) {
        responseHandler?(userInfo)
    }
}

/// A notification center whose `authorizationStatus()` can be suspended on demand, used to hold a
/// settings load at its `await refreshNotificationAuthorizationStatus()` point so a test can mutate
/// state (e.g. clear the active account) before the load resumes. Issue #4 regression support.
@MainActor
final class GatedLocalNotificationCenter: LocalNotificationCenter {
    /// When false, `authorizationStatus()` returns immediately (e.g. during `bootstrap()`); when
    /// true, it suspends on the first call until `releaseGate()` is invoked.
    var gateEnabled = false
    private(set) var didReachGate = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var responseHandler: (@MainActor ([String: String]) -> Void)?

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        if gateEnabled {
            didReachGate = true
            await withCheckedContinuation { continuation in
                gateContinuation = continuation
            }
        }
        return .authorized
    }

    func releaseGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus {
        .authorized
    }

    func post(_ notification: LocalNotificationRequest) async throws {}

    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void) {
        responseHandler = handler
    }
}

struct TranscriptExportTestFiles: Sendable {
    let root: URL
    let scratch: URL
    let destination: URL
}

func transcriptExportTestFiles() throws -> TranscriptExportTestFiles {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("whitenoise-transcript-export-tests-\(UUID().uuidString)", isDirectory: true)
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    return TranscriptExportTestFiles(
        root: root,
        scratch: scratch,
        destination: root.appendingPathComponent("transcript.json")
    )
}

func isolated(_ text: String) -> String {
    "\u{2068}\(text)\u{2069}"
}

func groupSystemEvent(
    systemType: String,
    text: String,
    actorAccountIdHex: String? = nil,
    subjectAccountIdHex: String? = nil,
    name: String? = nil,
    oldName: String? = nil,
    oldRetentionSeconds: UInt64? = nil,
    newRetentionSeconds: UInt64? = nil
) -> GroupSystemEventFfi {
    GroupSystemEventFfi(
        provenance: .authenticatedGroupState,
        actorDisplayName: nil,
        subjectDisplayName: nil,
        systemType: systemType,
        text: text,
        actorAccountIdHex: actorAccountIdHex,
        subjectAccountIdHex: subjectAccountIdHex,
        name: name,
        oldName: oldName,
        oldRetentionSeconds: oldRetentionSeconds,
        newRetentionSeconds: newRetentionSeconds
    )
}

func chatListRow(
    groupIdHex: String,
    title: String,
    preview: String,
    sender: String,
    timelineAt: UInt64,
    kind: UInt64 = 9,
    selfMembership: SelfMembershipFfi = .member,
    attachmentKind: ChatListAttachmentKindFfi? = nil,
    attachmentCount: UInt32 = 0,
    deleted: Bool = false,
    unreadCount: UInt64 = 0,
    hasUnread: Bool = false,
    archived: Bool = false,
    pendingConfirmation: Bool = false,
    pinned: Bool = false,
    pinnedPosition: UInt32? = nil,
    lifecycleState: GroupLifecycleStateFfi = .stable,
    disbanding: Bool = false
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: groupIdHex,
        archived: archived,
        pendingConfirmation: pendingConfirmation,
        title: title,
        groupName: "",
        avatarUrl: nil,
        avatar: nil,
        lastMessage: ChatListMessagePreviewFfi(
            messageIdHex: "preview",
            sender: sender,
            senderDisplayName: nil,
            plaintext: preview,
            contentTokens: emptyMarkdownDocument(),
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted,
            attachmentKind: attachmentKind,
            attachmentCount: attachmentCount,
            deliveryState: .notApplicable
        ),
        unreadCount: unreadCount,
        hasUnread: hasUnread,
        unreadMentionCount: 0,
        unreadMention: false,
        firstUnreadMessageIdHex: nil,
        lastReadMessageIdHex: nil,
        lastReadTimelineAt: nil,
        updatedAt: timelineAt,
        selfMembership: selfMembership,
        pinned: pinned,
        pinnedPosition: pinnedPosition,
        lifecycleState: lifecycleState,
        disbanding: disbanding
    )
}

func chatListOrderingTestItem(
    id: String,
    title: String,
    preview: String = "preview",
    updatedAt: UInt64,
    unreadCount: Int = 1,
    pendingConfirmation: Bool = false,
    selfMembership: ChatSelfMembership = .member
) -> ChatItem {
    chatListOrderingTestItem(
        id: id,
        title: title,
        preview: preview,
        date: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
        unreadCount: unreadCount,
        pendingConfirmation: pendingConfirmation,
        selfMembership: selfMembership
    )
}

func chatListOrderingTestItem(
    id: String,
    title: String,
    preview: String = "preview",
    date: Date?,
    unreadCount: Int = 1,
    pendingConfirmation: Bool = false,
    selfMembership: ChatSelfMembership = .member
) -> ChatItem {
    ChatItem(
        id: id,
        title: title,
        subtitle: "Group message",
        preview: preview,
        updatedAt: date,
        avatarSeed: id,
        pictureURL: nil,
        unreadCount: unreadCount,
        isDirect: false,
        pendingConfirmation: pendingConfirmation,
        selfMembership: selfMembership
    )
}

/// An unanswered invitation as the chat list holds it: no last message, no unread count, and — by
/// default — a membership that has not ended, which is what makes it worth a badge.
func pendingInviteChatItem(
    id: String,
    selfMembership: ChatSelfMembership = .member
) -> ChatItem {
    chatListOrderingTestItem(
        id: id,
        title: "Invite \(id)",
        preview: "",
        updatedAt: 1_700_000_000,
        unreadCount: 0,
        pendingConfirmation: true,
        selfMembership: selfMembership
    )
}

func performanceChatItems(count: Int) -> [ChatItem] {
    (0..<count).map { index in
        let id = "perf-chat-\(index)"
        let preview = index.isMultiple(of: 100) ? "launch planning \(index)" : "ordinary preview \(index)"
        let updatedAt = Date(timeIntervalSince1970: Double(2_000_000_000 - index))
        let unreadCount = index % 5
        let unreadMentionCount = index % 2
        return ChatItem(
            id: id,
            title: "Performance Chat \(index)",
            subtitle: "npub\(index)",
            preview: preview,
            updatedAt: updatedAt,
            avatarSeed: id,
            pictureURL: nil,
            unreadCount: unreadCount,
            unreadMentionCount: unreadMentionCount,
            isDirect: index.isMultiple(of: 3),
            pendingConfirmation: false
        )
    }
}

@MainActor
func waitFor(attempts: Int = 100, _ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}

func notificationSettings(
    for account: AccountSummaryFfi,
    localEnabled: Bool,
    nativePushEnabled: Bool = false
) -> NotificationSettingsFfi {
    NotificationSettingsFfi(
        accountRef: account.label,
        accountIdHex: account.accountIdHex,
        localNotificationsEnabled: localEnabled,
        nativePushEnabled: nativePushEnabled
    )
}

/// Serves a fixed body for NIP-05 well-known lookups, optionally advertising Content-Length so
/// tests can drive either the cheap pre-check or the streaming byte cap.
final class NIP05URLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var sendContentLength = true

    static func configure(body: Data, sendContentLength: Bool) {
        lock.lock()
        self.body = body
        self.sendContentLength = sendContentLength
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.body
        let withLength = Self.sendContentLength
        Self.lock.unlock()

        let headers = withLength ? ["Content-Length": "\(data.count)"] : [:]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func telemetryBuildConfig(
    telemetryToken: String? = "otlp-token",
    auditToken: String? = "audit-token",
    environment: String = "production",
    serviceVersion: String = expectedTelemetryServiceVersion(),
    osVersion: String = TelemetryBuildConfig.marketingOSVersion(),
    deviceModelIdentifier: String? = expectedDeviceModelIdentifier()
) -> TelemetryBuildConfig {
    TelemetryBuildConfig(
        otlpEndpoint: TelemetryBuildConfig.defaultOtlpEndpoint,
        bearerToken: telemetryToken,
        auditLogBearerToken: auditToken,
        deploymentEnvironment: environment,
        serviceVersion: serviceVersion,
        osVersion: osVersion,
        deviceModelIdentifier: deviceModelIdentifier
    )
}

func expectedTelemetryServiceVersion(bundle: Bundle = .main) -> String {
    let shortVersion = nonBlank(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    let buildVersion = nonBlank(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    return "\(shortVersion)+\(buildVersion)"
}

func expectedDeviceModelIdentifier() -> String? {
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

func nonBlank(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

func notificationUpdate(
    account: AccountSummaryFfi,
    notificationKey: String,
    groupIdHex: String = "direct-group",
    senderName: String,
    previewText: String? = nil,
    isDm: Bool = true,
    groupName: String? = nil,
    isFromSelf: Bool = false,
    messageIdHex: String? = nil,
    trigger: NotificationTriggerFfi = .newMessage
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: notificationKey,
        conversationKey: groupIdHex,
        trigger: trigger,
        trafficClass: .standard,
        accountRef: account.label,
        accountIdHex: account.accountIdHex,
        groupIdHex: groupIdHex,
        groupName: groupName,
        isDm: isDm,
        isMention: false,
        messageIdHex: messageIdHex ?? "\(notificationKey)-message",
        sender: NotificationUserFfi(
            accountIdHex: isFromSelf
                ? account.accountIdHex : "alice1234567890alice1234567890alice1234567890alice1234567890",
            displayName: senderName,
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: account.accountIdHex,
            displayName: account.label,
            pictureUrl: nil
        ),
        previewText: previewText,
        sticker: nil,
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: 1_700_000_000_000,
        isFromSelf: isFromSelf
    )
}

/// A deactivated identity — still on this Mac, not driving anything. Sign-out retains local
/// data and drops the account's relay key packages, so this is what `listAccounts` reports for an
/// account the user signed out of and has not signed back into.
func signedOutBackupAccount() -> AccountSummaryFfi {
    AccountSummaryFfi(
        label: "Backup Account",
        accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
        localSigning: true,
        externalSigning: false,
        signedOut: true,
        running: false,
        unlinked: false
    )
}

/// The roster a conversation is left with once every other participant has gone.
func soleRemainingSelfMember(accountIdHex: String) -> GroupMemberDetailsFfi {
    GroupMemberDetailsFfi(
        memberIdHex: accountIdHex,
        account: "Desktop Account",
        local: true,
        isAdmin: true,
        isSelf: true,
        npub: "npub1self",
        displayName: "Desktop Account"
    )
}

func groupDetailsFixture(
    selfAccountIdHex: String,
    selfIsAdmin: Bool = true,
    otherIsAdmin: Bool = false,
    /// Drops Alice and Bob, leaving this account alone in the group — the last member of a group
    /// everyone else left, or the remaining half of a DM whose peer is gone.
    soleMember: Bool = false
) -> GroupDetailsFfi {
    var group = messageGroup()
    group.description = "Original room"
    let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
    group.admins = [
        selfIsAdmin ? selfAccountIdHex : nil,
        otherIsAdmin ? aliceIdHex : nil,
    ].compactMap(\.self)
    let selfMember = GroupMemberDetailsFfi(
        memberIdHex: selfAccountIdHex,
        account: "Desktop Account",
        local: true,
        isAdmin: selfIsAdmin,
        isSelf: true,
        npub: "npub1self",
        displayName: "Desktop Account"
    )
    if soleMember {
        return GroupDetailsFfi(group: group, members: [selfMember])
    }
    return GroupDetailsFfi(
        group: group,
        members: [
            selfMember,
            GroupMemberDetailsFfi(
                memberIdHex: aliceIdHex,
                account: nil,
                local: false,
                isAdmin: otherIsAdmin,
                isSelf: false,
                npub: "npub1alyce",
                displayName: "Alice"
            ),
            GroupMemberDetailsFfi(
                memberIdHex: "bob1234567890bob1234567890bob1234567890bob1234567890bob1",
                account: nil,
                local: false,
                isAdmin: false,
                isSelf: false,
                npub: "npub1p0p",
                displayName: "Bob"
            ),
        ]
    )
}

/// A trivial mutable clock for driving time-dependent cache behaviour deterministically
/// in tests (whitenoise-mac#8). `@MainActor` so it matches `WorkspaceState`'s isolation
/// when injected via `nowProvider`.
@MainActor
final class MutableClock {
    var now: Date
    init(now: Date) { self.now = now }
}

/// A thread-safe mutable clock for tests that need to advance the wall clock from an
/// off-main FFI batch (e.g. modelling a slow profile-resolution batch) while reading it
/// from the main-actor `nowProvider` (whitenoise-mac#181).
final class ConcurrentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(now: Date) { self.current = now }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

func directGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: "direct-group",
        endpoint: "",
        name: "",
        description: "",
        admins: [],
        relays: ["wss://relay.example"],
        nostrGroupIdHex: "",
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        imageHashHex: nil,
        encryptedMedia: encryptedMediaComponent(),
        disappearingMessageSecs: 0,
        archived: false,
        pendingConfirmation: false,
        selfMembership: .member,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

func messageGroup(
    selfMembership: SelfMembershipFfi = .member
) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: "group",
        endpoint: "",
        name: "Test Group",
        description: "",
        admins: [],
        relays: MarmotClient.seedRelays,
        nostrGroupIdHex: "",
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        imageHashHex: nil,
        encryptedMedia: encryptedMediaComponent(),
        disappearingMessageSecs: 0,
        archived: false,
        pendingConfirmation: false,
        selfMembership: selfMembership,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

func mediaAttachmentReference(
    sourceEpoch: UInt64 = 0,
    mediaType: String,
    fileName: String,
    ciphertextSha256: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    plaintextSha256: String = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    nonceHex: String = "cccccccccccccccccccccccc"
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [
            MediaLocatorFfi(kind: "blossom", value: "https://blob.example/\(fileName)")
        ],
        ciphertextSha256: ciphertextSha256,
        plaintextSha256: plaintextSha256,
        nonceHex: nonceHex,
        fileName: fileName,
        mediaType: mediaType,
        version: .v1,
        sourceEpoch: sourceEpoch,
        dim: mediaType.hasPrefix("image/") ? "120x80" : nil,
        thumbhash: nil
    )
}

func mediaJson(for reference: MediaAttachmentReferenceFfi) -> String {
    let tag = mediaIMetaTag(for: reference).values
    return mediaJSONString(fromJSONObject: ["imeta": [tag]])
}

func mediaJson(for reference: MediaAttachmentReferenceFfi, appendingIMetaField field: String) -> String {
    var tag = mediaIMetaTag(for: reference).values
    tag.append(field)
    return mediaJSONString(fromJSONObject: ["imeta": [tag]])
}

func mediaJson(for reference: MediaAttachmentReferenceFfi, sourceEpochKey key: String) -> String {
    let tag = mediaIMetaTag(for: reference).values
    return mediaJSONString(fromJSONObject: ["imeta": [tag], key: NSNumber(value: reference.sourceEpoch)])
}

func mediaJson(
    for reference: MediaAttachmentReferenceFfi,
    sourceEpochKey key: String,
    rawSourceEpoch: NSNumber
) -> String {
    let tag = mediaIMetaTag(for: reference).values
    return mediaJSONString(fromJSONObject: ["imeta": [tag], key: rawSourceEpoch])
}

func mediaJson(for reference: MediaAttachmentReferenceFfi, mediaObjectDepth depth: Int) -> String {
    var object: [String: Any] = ["imeta": [mediaIMetaTag(for: reference).values]]
    for _ in 0..<depth {
        object = ["media": object]
    }
    return mediaJSONString(fromJSONObject: object)
}

func mediaJson(for reference: MediaAttachmentReferenceFfi, arrayDepth depth: Int) -> String {
    var object: Any = ["imeta": [mediaIMetaTag(for: reference).values]]
    for _ in 0..<depth {
        object = [object]
    }
    return mediaJSONString(fromJSONObject: object)
}

func timelinePayloadJSONWithNesting(inner: [String: Any], objectDepth depth: Int) -> String {
    var object: Any = inner
    for _ in 0..<depth {
        object = ["wrapper": object]
    }
    return mediaJSONString(fromJSONObject: object)
}

func mediaJsonWithIMetaAndFlatKeys(for reference: MediaAttachmentReferenceFfi) -> String {
    let object: [String: Any] = [
        "imeta": [mediaIMetaTag(for: reference).values],
        "ciphertext_sha256": reference.ciphertextSha256,
        "plaintext_sha256": reference.plaintextSha256,
        "nonce": reference.nonceHex,
        "file_name": reference.fileName,
        "media_type": reference.mediaType,
        "version": mediaVersionJSONString(reference.version),
    ]
    return mediaJSONString(fromJSONObject: object)
}

func mediaJSONString(fromJSONObject object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func mediaVersionJSONString(_ version: EncryptedMediaVersionFfi) -> String {
    switch version {
    case .v1:
        "v1"
    case .v2:
        "v2"
    }
}

func mediaIMetaTag(for reference: MediaAttachmentReferenceFfi) -> MessageTagFfi {
    var values = ["imeta"]
    values.append(contentsOf: reference.locators.map { "locator \($0.kind) \($0.value)" })
    values.append("ciphertext_sha256 \(reference.ciphertextSha256)")
    values.append("plaintext_sha256 \(reference.plaintextSha256)")
    values.append("nonce \(reference.nonceHex)")
    values.append("filename \(reference.fileName)")
    values.append("m \(reference.mediaType)")
    values.append("v \(mediaVersionJSONString(reference.version))")
    if let dim = reference.dim {
        values.append("dim \(dim)")
    }
    if let thumbhash = reference.thumbhash {
        values.append("thumbhash \(thumbhash)")
    }
    return MessageTagFfi(values: values)
}

func performanceMessageItems(count: Int, groupIdHex: String = "perf-group") -> [MessageItem] {
    let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    let richMarkdown = richMarkdownDocumentForPerformance()
    let compactMarkdown = MarkdownDocumentFfi(
        blocks: [
            .paragraph(inlines: [
                .text(content: "Compact update with "),
                .strong(children: [.text(content: "status")]),
                .text(content: " and "),
                .code(content: "trace_id"),
                .text(content: "."),
            ])
        ],
        truncated: false
    )

    return (0..<count).map { index in
        let isOutgoing = index.isMultiple(of: 2)
        let markdown: MarkdownDocumentFfi?
        if index.isMultiple(of: 5) {
            markdown = richMarkdown
        } else if index.isMultiple(of: 3) {
            markdown = compactMarkdown
        } else {
            markdown = nil
        }

        return MessageItem(
            id: "perf-\(index)",
            groupIdHex: groupIdHex,
            senderAccountIdHex: isOutgoing ? "self" : "alice",
            senderName: isOutgoing ? "Jeff" : "Alice",
            body: """
                Performance transcript fixture \(index). This row is intentionally long \
                enough to wrap across multiple lines and exercise bubble layout while \
                remaining deterministic.
                """,
            contentMarkdown: markdown,
            sentAt: baseDate.addingTimeInterval(TimeInterval(index)),
            timelineAt: UInt64(1_800_000_000 + index),
            isOutgoing: isOutgoing
        )
    }
}

func richMarkdownDocumentForPerformance() -> MarkdownDocumentFfi {
    MarkdownDocumentFfi(
        blocks: [
            .heading(
                level: 3,
                inlines: [
                    .text(content: "Release checklist")
                ]),
            .paragraph(inlines: [
                .text(content: "Review "),
                .strong(children: [.text(content: "rendering")]),
                .text(content: ", validate "),
                .emph(children: [.text(content: "scroll position")]),
                .text(content: ", and open "),
                .link(
                    dest: "https://example.com/perf",
                    title: nil,
                    children: [.text(content: "perf notes")],
                    classification: .web
                ),
                .text(content: "."),
            ]),
            .listBlock(
                kind: .bullet(marker: "-"),
                tight: true,
                items: [
                    MarkdownListItemFfi(
                        blocks: [
                            .paragraph(inlines: [.text(content: "No jump when older history prepends")])
                        ],
                        checked: nil
                    ),
                    MarkdownListItemFfi(
                        blocks: [
                            .paragraph(inlines: [.text(content: "No full transcript diff for one update")])
                        ],
                        checked: true
                    ),
                ]
            ),
            .table(
                alignments: [.left, .right],
                header: [
                    MarkdownTableCellFfi(inlines: [.text(content: "Path")]),
                    MarkdownTableCellFfi(inlines: [.text(content: "Target")]),
                ],
                rows: [
                    [
                        MarkdownTableCellFfi(inlines: [.code(content: "body")]),
                        MarkdownTableCellFfi(inlines: [.text(content: "< 16ms")]),
                    ],
                    [
                        MarkdownTableCellFfi(inlines: [.code(content: "diff")]),
                        MarkdownTableCellFfi(inlines: [.text(content: "bounded")]),
                    ],
                ]
            ),
            .codeBlock(kind: .fenced, info: "swift", content: "let row = ConversationMessageRow(message: item)"),
        ],
        truncated: false
    )
}

/// Absolute wall-clock performance guards apply a fixed slack multiplier so they stay
/// reliable across wildly different hardware — fast local dev machines vs. loaded, shared
/// CI runners (a hosted macos-26 runner clocked the indexed-upsert guard at ~870ms against a
/// 500ms base). They exist to catch order-of-magnitude regressions, not runner variance.
/// NB: Xcode does not propagate the shell `CI` env var into the xctest host process, so
/// detecting CI from here is unreliable; a uniform margin is simpler and dependable.
let performanceSlack: Double = 5

func measuredMilliseconds(_ work: () -> Void) -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    work()
    return (CFAbsoluteTimeGetCurrent() - start) * 1_000
}

func measuredMillisecondsAsync(_ work: () async -> Void) async -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    await work()
    return (CFAbsoluteTimeGetCurrent() - start) * 1_000
}

func formatMilliseconds(_ milliseconds: Double) -> String {
    String(format: "%.2f", milliseconds)
}

func messageMediaDiskCache(
    root: URL,
    keyData: Data = Data(repeating: 0x42, count: 32),
    evictionPolicy: MessageMediaDiskCache.EvictionPolicy = .standard,
    timestampProvider: @escaping MessageMediaDiskCache.TimestampProvider = { Date().timeIntervalSince1970 },
    sessionStartedAtUnixSeconds: TimeInterval = Date().timeIntervalSince1970,
    keyDeleter: @escaping @Sendable () -> Void = {}
) -> MessageMediaDiskCache {
    MessageMediaDiskCache(
        directoryResolver: { root },
        keyProvider: { SymmetricKey(data: keyData) },
        keyDeleter: keyDeleter,
        timestampProvider: timestampProvider,
        evictionPolicy: evictionPolicy,
        sessionStartedAtUnixSeconds: sessionStartedAtUnixSeconds
    )
}

func mediaDiskCacheReference(
    plaintext: Data,
    ciphertextByte: UInt8 = 0xcc,
    ciphertextSha256: String? = nil
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [],
        ciphertextSha256: ciphertextSha256
            ?? String(repeating: String(format: "%02x", ciphertextByte), count: 32),
        plaintextSha256: hexSHA256(plaintext),
        nonceHex: String(repeating: "00", count: 12),
        fileName: "cached.bin",
        mediaType: "application/octet-stream",
        version: .v1,
        sourceEpoch: 7,
        dim: nil,
        thumbhash: nil
    )
}

func dataContains(_ haystack: Data, _ needle: Data) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for offset in 0...(haystack.count - needle.count) {
        if haystack[offset..<(offset + needle.count)].elementsEqual(needle) {
            return true
        }
    }
    return false
}

func nestedBlockQuote(depth: Int, leaf: MarkdownBlockFfi) -> MarkdownBlockFfi {
    var block = leaf
    for _ in 0..<depth {
        block = .blockQuote(blocks: [block], blankLinesBefore: Data([0]))
    }
    return block
}

func nestedStrong(depth: Int, leaf: MarkdownInlineFfi) -> MarkdownInlineFfi {
    var inline = leaf
    for _ in 0..<depth {
        inline = .strong(children: [inline])
    }
    return inline
}

func blockQuoteNestingDepth(_ blocks: [MarkdownDisplayBlockNode]) -> Int {
    var depth = 0
    var current = blocks
    while case .blockQuote(let inner)? = current.first?.block {
        depth += 1
        current = inner
    }
    return depth
}

func firstParagraph(in blocks: [MarkdownDisplayBlockNode]) -> AttributedString? {
    for node in blocks {
        switch node.block {
        case .paragraph(let text):
            return text
        case .blockQuote(let inner):
            if let found = firstParagraph(in: inner) {
                return found
            }
        case .list(let items):
            for item in items {
                if let found = firstParagraph(in: item.blocks) {
                    return found
                }
            }
        default:
            continue
        }
    }
    return nil
}

/// A nickname store rooted in a directory of this test's own.
///
/// `bootstrap()` creates a real `ContactNicknameFileStore` under the Marmot storage root when none
/// is injected, and the fake runtime's root is a fixed path shared by every test — so a test that
/// writes a nickname and does not inject a store persists it for whatever runs next, which then
/// reads it back through `loadContactNicknames()`. That is invisible until the suite happens to
/// order a nickname-writing test ahead of one asserting a published name (it broke
/// `steadyStatePeerProfileRefreshMakesNoRequestsAcrossWindowsAndDeltas`, which expected
/// "Alice Cooper" and got "Mum"). Injecting a per-test directory makes the test hermetic in both
/// directions rather than relying on it to clear up after itself.
func isolatedContactNicknameStore() -> (store: ContactNicknameFileStore, directoryURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("whitenoise-nicknames-\(UUID().uuidString)", isDirectory: true)
    return (ContactNicknameFileStore(directoryURL: directory), directory)
}

/// A directory of this test's own for attachment downloads, so nothing is written into the
/// running user's Downloads folder and no two tests can collide over a file name.
/// Every name in `directory`, hidden ones included — a staging file left behind is hidden, and a
/// check that skipped hidden files would not see the thing it is looking for.
func folderContents(of directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
}

func uniqueTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("whitenoise-media-downloads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Stands in for both halves of the download destination — the folder panel and the remembered
/// grant — so tests neither show a modal nor touch the real `UserDefaults` bookmark.
///
/// `pickCallCount` is the point of the "pick once" design: the second download must not ask again.
@MainActor
/// A `FileManager` that loses the caller a race: the first name it is asked about is reported free
/// and then created, so the answer is stale by the time it is acted on. Stands in for any other
/// process writing into the same folder — the download folder is usually one of those.
final class RacingFileManager: FileManager, @unchecked Sendable {
    /// What the racing writer puts on disk, so the test can assert it survived.
    nonisolated static let intruder = Data("written by something else".utf8)
    /// Written and read on one thread inside a single write call, never concurrently.
    nonisolated(unsafe) private(set) var plantedPath: String?

    nonisolated override func fileExists(atPath path: String) -> Bool {
        let existed = super.fileExists(atPath: path)
        if !existed, plantedPath == nil {
            plantedPath = path
            try? Self.intruder.write(to: URL(filePath: path))
        }
        // What was true a moment ago, which is all a check-then-write ever has.
        return existed
    }
}

final class FakeMediaDownloadDestination: MediaDownloadDestinationStoring {
    /// What the folder panel returns. `nil` means the user closed it without choosing.
    var pickedURL: URL?
    private(set) var pickCallCount = 0
    /// What the Save As panel returns, and the names it was offered, in order.
    var pickedFileURL: URL?
    private(set) var suggestedFileNames: [String] = []
    var alwaysAsksWhereToSave: Bool
    private(set) var storedURL: URL?
    private(set) var storeCallCount = 0
    private(set) var clearCallCount = 0
    /// Simulates a grant that no longer resolves — folder deleted, volume ejected.
    var failsToResolve = false

    /// `alwaysAsks` defaults to the remembered folder, which most download tests exercise; the
    /// production store defaults to asking.
    init(storedURL: URL? = nil, pickedURL: URL? = nil, alwaysAsks: Bool = false) {
        self.storedURL = storedURL
        self.pickedURL = pickedURL
        self.alwaysAsksWhereToSave = alwaysAsks
    }

    /// Passed to `WorkspaceState(mediaDownloadPanels:)`.
    var panels: MediaDownloadPanels {
        MediaDownloadPanels(
            chooseFolder: { [unowned self] in pick() },
            chooseFile: { [unowned self] name in
                suggestedFileNames.append(name)
                return pickedFileURL
            }
        )
    }

    func pick() -> URL? {
        pickCallCount += 1
        return pickedURL
    }

    func resolveDestination() -> MediaDownloadDestinationAccess? {
        guard let storedURL, !failsToResolve else { return nil }
        return MediaDownloadDestinationAccess(url: storedURL, isSecurityScoped: false)
    }

    func store(_ url: URL) {
        storeCallCount += 1
        storedURL = url
        failsToResolve = false
    }

    func clear() {
        clearCallCount += 1
        storedURL = nil
    }

    var storedDestinationURL: URL? {
        storedURL
    }
}

/// A bootstrapped workspace whose timeline holds one message carrying `attachments`.
///
/// Attachments marked `isAvailable: false` have no media record installed, which is how the fake
/// core reports an attachment the account can no longer fetch.
@MainActor
func mediaDownloadFixture(
    attachments: [(fileName: String, mediaType: String, data: Data, isAvailable: Bool)],
    body: String = "",
    destination: FakeMediaDownloadDestination
) async -> (state: WorkspaceState, message: MessageItem, runtime: FakeMarmotRuntime) {
    let account = AccountSummaryFfi(
        label: "Desktop Account",
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: false,
        unlinked: false
    )
    let runtime = FakeMarmotRuntime(accounts: [account])
    runtime.installGroup(messageGroup())

    var messageAttachments: [MessageMediaAttachment] = []
    for (index, attachment) in attachments.enumerated() {
        let ciphertextSha256 = String(repeating: "a", count: 63) + "\(index)"
        let plaintextSha256 = String(repeating: "b", count: 63) + "\(index)"
        let timelineReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: attachment.mediaType,
            fileName: attachment.fileName,
            ciphertextSha256: ciphertextSha256,
            plaintextSha256: plaintextSha256
        )
        let fullReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: attachment.mediaType,
            fileName: attachment.fileName,
            ciphertextSha256: ciphertextSha256,
            plaintextSha256: plaintextSha256
        )
        if attachment.isAvailable {
            runtime.installMediaRecord(
                MediaRecordFfi(
                    messageIdHex: "media-message",
                    attachmentIndex: UInt32(index),
                    direction: "inbound",
                    groupIdHex: "group",
                    sender: "alice",
                    reference: fullReference,
                    caption: nil,
                    recordedAt: 1_700_000_000,
                    receivedAt: 1_700_000_000
                ),
                download: MediaDownloadResultFfi(
                    plaintext: attachment.data,
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    sizeBytes: UInt64(attachment.data.count)
                )
            )
        }
        messageAttachments.append(
            MessageMediaAttachment(
                id: "media-message#\(index)#\(plaintextSha256)",
                reference: timelineReference
            )
        )
    }

    let state = WorkspaceState(
        mediaDownloadPanels: destination.panels,
        mediaDownloadDestinationStore: destination,
        clientFactory: { runtime }
    )
    await state.bootstrap()
    state.selection = .chat("group")
    let message = MessageItem(
        id: "media-message",
        groupIdHex: "group",
        senderName: "Alice",
        body: body,
        sentAt: Date(timeIntervalSince1970: 1_700_000_000),
        isOutgoing: false,
        mediaAttachments: messageAttachments
    )
    state.replaceMessages([message], groupIdHex: "group")
    return (state, message, runtime)
}

func restoreDefault(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
    // Tests mutate `UserDefaults` directly (bypassing `WorkspaceState`), so the
    // in-memory locale cache must be invalidated when the language key is
    // restored — otherwise a stale cached locale leaks into later tests.
    if key == AppLanguage.storageKey {
        AppLanguage.refreshCachedLocale()
    }
}
