import AVFoundation
import AppKit
import Combine
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

nonisolated struct ChatListOrdering {
    struct UpsertResult {
        let chats: [ChatItem]
        let reindexStart: Int?
    }

    static func sorted(_ chatItems: [ChatItem]) -> [ChatItem] {
        chatItems.sorted(by: areInDisplayOrder)
    }

    static func upserting(_ chat: ChatItem, into chats: [ChatItem]) -> [ChatItem] {
        upsertResult(chat, into: chats, existingIndex: chats.firstIndex(where: { $0.id == chat.id })).chats
    }

    static func upserting(_ chat: ChatItem, into chats: [ChatItem], existingIndex: Int?) -> [ChatItem] {
        upsertResult(chat, into: chats, existingIndex: existingIndex).chats
    }

    static func upsertResult(_ chat: ChatItem, into chats: [ChatItem], existingIndex: Int?) -> UpsertResult {
        var result = chats
        if let index = existingIndex {
            if canReplaceInPlace(chat, at: index, in: result) {
                result[index] = chat
                return UpsertResult(chats: result, reindexStart: nil)
            }
            result.remove(at: index)
            let nextIndex = insertionIndex(for: chat, in: result)
            result.insert(chat, at: nextIndex)
            return UpsertResult(chats: result, reindexStart: min(index, nextIndex))
        }

        let nextIndex = insertionIndex(for: chat, in: result)
        result.insert(chat, at: nextIndex)
        return UpsertResult(chats: result, reindexStart: nextIndex)
    }

    static func mostRecent(in chatItems: [ChatItem]) -> ChatItem? {
        chatItems.min { lhs, rhs in
            areInDisplayOrder(lhs, rhs)
        }
    }

    static func preservingResolvedMetadata(in chat: ChatItem, from current: ChatItem) -> ChatItem {
        ChatItem(
            id: chat.id,
            title: current.title,
            subtitle: current.subtitle,
            preview: chat.preview,
            updatedAt: chat.updatedAt,
            avatarSeed: current.avatarSeed,
            pictureURL: current.pictureURL,
            unreadCount: chat.unreadCount,
            unreadMentionCount: chat.unreadMentionCount,
            isDirect: current.isDirect,
            pendingConfirmation: chat.pendingConfirmation
        )
    }

    static func isOlder(_ candidate: ChatItem, than current: ChatItem) -> Bool {
        guard let currentUpdatedAt = current.updatedAt else { return false }
        guard let candidateUpdatedAt = candidate.updatedAt else { return true }
        return candidateUpdatedAt < currentUpdatedAt
    }

    private static func canReplaceInPlace(_ chat: ChatItem, at index: Int, in chats: [ChatItem]) -> Bool {
        let previousStillBefore = index == chats.startIndex || !areInDisplayOrder(chat, chats[index - 1])
        let nextStillAfter: Bool
        if index == chats.index(before: chats.endIndex) {
            nextStillAfter = true
        } else {
            nextStillAfter = !areInDisplayOrder(chats[index + 1], chat)
        }
        return previousStillBefore && nextStillAfter
    }

    private static func insertionIndex(for chat: ChatItem, in chats: [ChatItem]) -> Int {
        var lowerBound = chats.startIndex
        var upperBound = chats.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if areInDisplayOrder(chats[middle], chat) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func areInDisplayOrder(_ lhs: ChatItem, _ rhs: ChatItem) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case (let left?, let right?) where left != right:
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

@MainActor
@Observable
final class MediaDownloadStateStore {
    private(set) var state: MediaDownloadState = .idle

    var shouldStartAutomaticDownload: Bool {
        if case .idle = state {
            return true
        }
        return false
    }

    func update(_ newState: MediaDownloadState) {
        guard state != newState else { return }
        state = newState
    }
}

@MainActor
@Observable
final class MessageTimelineStore {
    struct ProjectionApplyResult: Equatable {
        let didChange: Bool
        let didTrimOlderMessages: Bool
    }

    private(set) var messages: [MessageItem]
    private(set) var messageIDs: [String]
    /// O(1) id → message map for non-UI lookups (`timelineMessage(groupIdHex:messageId:)`).
    /// `@ObservationIgnored`: it is never read from a view body — only `messages`/`messageIDs`
    /// drive rendering — so it must not enlarge a view's observation set. The store owns this
    /// (and `messageIDs`) so callers don't maintain parallel per-chat dictionaries.
    @ObservationIgnored private(set) var lookup: [String: MessageItem]
    @ObservationIgnored private var indexById: [String: Int]
    private(set) var isLoaded: Bool

    init(messages: [MessageItem] = [], isLoaded: Bool = false) {
        self.messages = messages
        self.messageIDs = messages.map(\.id)
        self.lookup = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        self.indexById = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
        self.isLoaded = isLoaded
    }

    static func loaded(with messages: [MessageItem]) -> MessageTimelineStore {
        MessageTimelineStore(messages: messages, isLoaded: true)
    }

    func replace(with messages: [MessageItem]) {
        self.messages = messages
        rebuildIndexes()
        self.isLoaded = true
    }

    func clear() {
        messages = []
        messageIDs = []
        lookup = [:]
        indexById = [:]
        isLoaded = false
    }

    func containsMessage(id: String) -> Bool {
        lookup[id] != nil
    }

    func applyProjection(
        upserts: [MessageItem],
        removals removalIds: Set<String>,
        anchoredToNewest: Bool,
        windowLimit: Int
    ) -> ProjectionApplyResult {
        let newestKey = messages.last.map(TimelineSortKey.init)
        var didChange = false

        if !removalIds.isEmpty {
            let originalCount = messages.count
            messages.removeAll { removalIds.contains($0.id) }
            didChange = messages.count != originalCount
            if didChange {
                rebuildIndexes()
            }
        }

        for item in upserts {
            if let existingIndex = indexById[item.id] {
                guard messages[existingIndex] != item else { continue }
                if TimelineSortKey(messages[existingIndex]) == TimelineSortKey(item) {
                    messages[existingIndex] = item
                    lookup[item.id] = item
                    didChange = true
                    continue
                }
                removeMessage(at: existingIndex)
                insertMessage(item, at: insertionIndex(for: item))
                didChange = true
                continue
            }

            let isInsideDetachedWindow = newestKey.map { TimelineSortKey(item) <= $0 } ?? false
            guard anchoredToNewest || isInsideDetachedWindow else { continue }
            insertMessage(item, at: insertionIndex(for: item))
            didChange = true
        }

        var didTrimOlderMessages = false
        if messages.count > windowLimit {
            messages.removeFirst(messages.count - windowLimit)
            rebuildIndexes()
            didTrimOlderMessages = true
            didChange = true
        }

        if didChange {
            isLoaded = true
        }
        return ProjectionApplyResult(didChange: didChange, didTrimOlderMessages: didTrimOlderMessages)
    }

    private func rebuildIndexes() {
        messageIDs = messages.map(\.id)
        lookup = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        indexById = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func insertMessage(_ item: MessageItem, at index: Int) {
        messages.insert(item, at: index)
        messageIDs.insert(item.id, at: index)
        lookup[item.id] = item
        reindexMessages(startingAt: index)
    }

    private func removeMessage(at index: Int) {
        let removed = messages.remove(at: index)
        messageIDs.remove(at: index)
        lookup[removed.id] = nil
        indexById[removed.id] = nil
        reindexMessages(startingAt: index)
    }

    private func reindexMessages(startingAt startIndex: Int) {
        guard startIndex < messages.endIndex else { return }
        for index in startIndex..<messages.endIndex {
            indexById[messages[index].id] = index
        }
    }

    private func insertionIndex(for item: MessageItem) -> Int {
        let key = TimelineSortKey(item)
        var lowerBound = messages.startIndex
        var upperBound = messages.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if TimelineSortKey(messages[middle]) < key {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private struct TimelineSortKey: Comparable {
        let timelineAt: UInt64
        let id: String

        init(_ message: MessageItem) {
            timelineAt = message.timelineAt
            id = message.id
        }

        static func < (lhs: TimelineSortKey, rhs: TimelineSortKey) -> Bool {
            if lhs.timelineAt != rhs.timelineAt {
                return lhs.timelineAt < rhs.timelineAt
            }
            return lhs.id < rhs.id
        }
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

    struct ComposerDraftKey: Hashable {
        let accountId: String
        let chatId: String
    }

    struct ObservabilityRuntimeConfiguration: Equatable {
        let buildConfig: TelemetryBuildConfig
        let accountLabel: String?
        let relayTelemetryRuntimeConfig: RelayTelemetryRuntimeConfigFfi
        let auditLogTrackerConfig: AuditLogTrackerConfigFfi
    }

    struct FilteredChatsCache {
        let accountId: String
        let generation: Int
        let query: String
        let result: [ChatItem]
    }

    var phase: Phase = .bootstrapping
    var accounts: [AccountItem]
    var chatsByAccount: [String: [ChatItem]]
    @ObservationIgnored var chatLookupByAccount: [String: [String: ChatItem]] = [:]
    @ObservationIgnored var chatIndexByAccount: [String: [String: Int]] = [:]
    @ObservationIgnored var chatListGenerationByAccount: [String: Int] = [:]
    @ObservationIgnored var filteredChatsCache: FilteredChatsCache?
    /// Ids of the chats whose transcript window is currently cached in `messageTimelineStores`.
    /// The message arrays themselves live only on the stores; tracking membership in a small set
    /// (rather than a parallel `[String: [MessageItem]]`) avoids copying the open conversation's
    /// window on every timeline delta while preserving the cached/not-cached distinction the
    /// prune and reseed paths rely on.
    @ObservationIgnored var cachedMessageChatIds: Set<String> = []
    @ObservationIgnored var messageTimelineStores: [String: MessageTimelineStore] = [:]

    /// Backing timeline snapshot for tests and non-UI lookups, derived from the per-chat stores.
    /// Swift Observation tracks an observed dictionary as one property, so UI reads must still go
    /// through `messageTimelineStores` to subscribe only to the selected chat's transcript
    /// (whitenoise-mac#176); this derivation reads only `@ObservationIgnored` storage.
    var messagesByChat: [String: [MessageItem]] {
        var result: [String: [MessageItem]] = [:]
        result.reserveCapacity(cachedMessageChatIds.count)
        for id in cachedMessageChatIds {
            if let store = messageTimelineStores[id] {
                result[id] = store.messages
            }
        }
        return result
    }
    @ObservationIgnored var mediaDownloads: [String: MediaDownloadStateStore] = [:]
    @ObservationIgnored let mediaDiskCache: MessageMediaDiskCache
    @ObservationIgnored var mediaDiskStoreTasks: [String: MediaDiskStoreTask] = [:]
    @ObservationIgnored var isMediaDiskStoreGloballySuppressed = false
    @ObservationIgnored var mediaDiskStoreSuppressedAccountIds = Set<String>()
    @ObservationIgnored var mediaDiskStoreAccountGenerations: [String: UInt64] = [:]
    @ObservationIgnored var mediaDiskStoreGlobalGeneration: UInt64 = 0
    @ObservationIgnored var nextMediaDiskStoreTaskToken: UInt64 = 0
    /// Error for the user-initiated action on the *current* screen. Rendered by form
    /// surfaces (login, settings, new-chat composer). Must never be written by
    /// background tasks — see `backgroundStatus`.
    var lastError: String?
    /// Status for failures originating in background tasks (subscription listeners,
    /// observability refresh, read-marking). These are not tied to anything the user
    /// just did, so they are surfaced on a non-modal global banner instead of the
    /// per-screen error view, preventing misattribution and clobbering of `lastError`.
    var backgroundStatus: String?

    var activeAccountId: String?
    var selection: WorkspaceSelection? {
        didSet {
            dismissGroupImagePickerIfSelectedChatUnavailable()
            ensureSelectedMessageTimelineStore()
        }
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
    var pendingMediaAttachments: [PendingMediaAttachment] {
        guard let selectedComposerDraftKey else { return [] }
        return pendingMediaAttachmentsByConversation[selectedComposerDraftKey] ?? []
    }
    var isRefreshing = false
    var isSending = false
    var isRecordingVoiceMessage = false
    var voiceRecordingSamples: [CGFloat] = []
    var voiceRecordingDurationSeconds: Double = 0
    /// Per-target reentrancy guards for message actions. `react`/`deleteMessage`
    /// operate on arbitrary messages, so a single in-flight bool (like `isSending`)
    /// would wrongly block acting on a *different* message. We key on the action's
    /// target instead so only a duplicate of the *same* in-flight action is dropped.
    var inFlightReactionKeys = Set<String>()
    var inFlightDeleteMessageIds = Set<String>()
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
    /// When false (the default), profile/avatar pictures from untrusted peer metadata are NOT
    /// fetched from their remote URLs; a generated avatar is shown instead. This prevents an
    /// arbitrary sender from learning the viewer's IP address / online status simply by putting
    /// a `picture` URL in front of them (a tracking-pixel vector). The user opts in explicitly
    /// in Privacy & Security settings.
    var loadRemoteImages: Bool {
        didSet {
            UserDefaults.standard.set(loadRemoteImages, forKey: Self.loadRemoteImagesKey)
        }
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
            if languagePreference == .system {
                observedSystemLocaleIdentifier = AppLanguage.currentSystemLocaleIdentifier()
            }
            AppLanguage.refreshCachedLocale()
        }
    }
    var observedSystemLocaleIdentifier = AppLanguage.currentSystemLocaleIdentifier()
    var systemLocaleRefreshRevision = 0
    var isLoadingSettings = false
    var isSavingProfile = false
    var isRemovingAccount = false
    var isSigningOutAccount = false
    /// Per-account unread totals keyed by `accountIdHex`, for switcher avatar badges.
    var accountUnreadByIdHex: [String: Int] = [:]
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
    var newChatRecipients: [NewChatRecipient] = []
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
    var isAcceptingGroupInvite = false
    var isDecliningGroupInvite = false
    var isArchivingGroup = false
    var isLeavingGroup = false
    var isUpdatingDisappearingMessages = false
    var isSecureDeletingExpired = false
    var isDeletingGroupLocally = false
    var isExportingGroupTranscript = false
    var groupTranscriptExportStatus: String?
    var mutatingGroupMemberId: String?
    var storageRootPath = MarmotClient.defaultStorageRootPath()
    var timelinePagingByChat: [String: TimelinePagingState] = [:]
    var timelineInitialLoadGroupId: String?
    var draftTextByConversation: [ComposerDraftKey: String] = [:]
    var replyDraftContextByConversation: [ComposerDraftKey: MessageReplyContext] = [:]
    var pendingMediaAttachmentsByConversation: [ComposerDraftKey: [PendingMediaAttachment]] = [:]
    var voiceRecorder: AVAudioRecorder?
    var voiceRecordingURL: URL?
    var voiceRecordingMeterTask: Task<Void, Never>?

    var selectedComposerDraftKey: ComposerDraftKey? {
        guard let activeAccountId, case .chat(let chatId) = selection else { return nil }
        return ComposerDraftKey(accountId: activeAccountId, chatId: chatId)
    }

    let clientFactory: @MainActor () throws -> any MarmotRuntime
    let localNotificationCenter: any LocalNotificationCenter
    let appActivityProvider: @MainActor () -> Bool
    let conversationWindowVisibilityProvider: @MainActor () -> Bool
    let copyTextHandler: @MainActor (String, Bool) -> Void
    let telemetryBuildConfigProvider: @MainActor () -> TelemetryBuildConfig
    let groupImageSearchClient: any GroupImageSearchClient
    /// Injectable clock for peer-profile cache TTL decisions, so tests can drive cache
    /// expiry deterministically (whitenoise-mac#8). Defaults to the system clock.
    let nowProvider: @MainActor () -> Date
    var client: (any MarmotRuntime)?
    var observabilityRuntimeConfiguration: ObservabilityRuntimeConfiguration?
    var notificationTask: Task<Void, Never>?
    var chatListTask: Task<Void, Never>?
    var chatListTaskAccountId: String?
    /// Single-owner coalescing for full chat-list reloads (issue #210). `reloadChats()` is
    /// reachable from independently-spawned tasks (account switch, notification taps, group
    /// mutations), so two same-account calls should usually share the in-flight
    /// subscription/snapshot work instead of duplicating FFI fan-out and racing listener teardown.
    /// Post-mutation call sites can force a fresh snapshot to preserve immediate-refresh semantics.
    /// Requests for a different account cancel the stale reload; the generation token prevents the
    /// stale task from applying rows, starting a listener, or clearing the newer reload's spinner if
    /// it resumes later.
    var reloadChatsTask: Task<Void, Never>?
    var reloadChatsTaskAccountId: String?
    var reloadChatsGeneration: UInt64 = 0
    var chatListEnrichmentTask: Task<Void, Never>?
    /// Incremental, per-row chat-list enrichment task ownership (issue #40). Single-row updates
    /// (the chat-list subscription delta path) spawn one enrichment task per group; this tracker
    /// lets `stopChatListListener` cancel them on listener teardown / account switch and lets a
    /// newer update for the same group supersede (coalesce) an in-flight one. Ownership tokens
    /// are process-monotonic and never reused, so a stale canceled task can never match a future
    /// task's token and drop its tracking slot. See `ChatListRowEnrichmentTracker`.
    var chatListRowEnrichment = ChatListRowEnrichmentTracker()
    /// Single-owner coalescing for the aggregate settings load (issue #4). `loadSettingsData()`
    /// is invoked from more than one entry point — the settings view's `.task(id: activeAccountId)`
    /// and explicit reloads (e.g. after removing the active account) — which can otherwise issue
    /// overlapping profile / relay / notification / privacy fetches for the same account. The
    /// in-flight task is tracked here keyed by `settingsLoadAccountId`: a concurrent request for the
    /// same account awaits the existing task (coalesces) instead of starting a duplicate, and a
    /// request for a different account cancels the now-stale load so it cannot clobber fresher state.
    var settingsLoadTask: Task<Void, Never>?
    var settingsLoadAccountId: String?
    /// Monotonic token identifying the most recently started settings load. `performSettingsLoad`
    /// captures the value at launch and only clears `isLoadingSettings` in its `defer` if it is
    /// still the current generation — i.e. no newer load has superseded it. This distinguishes
    /// "superseded by a newer load" (must NOT dismiss the spinner the newer load owns) from
    /// "cancelled with no replacement" (the active account was cleared, so the spinner MUST be
    /// dismissed instead of left stuck). The token wraps with `&+=`: equality ownership tolerates
    /// wraparound, and wrapping avoids overflow traps (issue #182). See `loadSettingsData` /
    /// issue #4.
    var settingsLoadGeneration: UInt64 = 0
    /// Monotonic token for notification-settings reads/writes. Unlike `activeAccountId`, this
    /// bumps on every active-account transition, so an older A request cannot commit after a rapid
    /// A→B→A re-entry or after a newer notification load/toggle for the same account.
    var notificationSettingsGeneration: UInt64 = 0
    var timelineTask: Task<Void, Never>?
    var timelineTaskGroupId: String?
    /// The live timeline subscription for the open conversation. It owns the
    /// authoritative, bounded, materialized window; scroll-back/forward pagination and
    /// live updates all flow through it (`paginateBackwards` / `paginateForwards` / `next`).
    /// Kept alive for pagination independent of the listener task. The listener replaces
    /// it after a recoverable stream end/reconnect, and it is cleared only when the
    /// conversation is torn down.
    var activeTimelineSubscription: TimelineMessagesSubscription?
    var activeTimelineGroupId: String?
    var lastMarkedReadMarkers: [String: ReadMarker] = [:]
    var lastConfirmedReadMarkers: [String: ReadMarker] = [:]
    var deliveredNotificationKeys = Set<String>()
    var deliveredNotificationKeyOrder: [String] = []
    /// Wrapping owner token for new-chat lookup. Stale-result guards only compare equality, so
    /// wraparound preserves ownership semantics while avoiding overflow traps (issues #2, #182).
    var newChatLookupGeneration: UInt64 = 0
    /// Monotonic token identifying the most recently started group-image (Openverse) search.
    /// `searchGroupImages` captures the value before its `await` and only commits results /
    /// clears `isSearchingGroupImages` while it is still current — i.e. no newer search has
    /// superseded it and the picker is still on screen for the same query. This makes the
    /// search last-request-wins (a slow earlier search cannot overwrite a newer one) and
    /// prevents a search resolving after the picker is dismissed/reopened from repopulating
    /// `groupImageResults`. Mirrors the new-chat lookup / settings-load generation guards
    /// (issues #2, #4) and uses the same wrapping-token overflow hardening (issue #182).
    /// See `searchGroupImages` / issue #110.
    var groupImageSearchGeneration: UInt64 = 0
    /// Monotonic token identifying the most recently started group-details load. `loadGroupDetails`
    /// captures the value on entry and only applies the fetched snapshot, clears
    /// `isLoadingGroupDetails`, or reports errors while it is still current — i.e. no newer load or
    /// `closeGroupDetails` has bumped the generation. This makes the load last-request-wins (a slow
    /// earlier load cannot clobber a newer snapshot or prematurely drop the shared spinner) and
    /// prevents a load resolving after group details are closed from repopulating closed UI state.
    /// `loadGroupDetails` is reachable concurrently for the same group from `showGroupDetails`,
    /// `reloadSelectedGroupDetails`, `saveGroupProfile`, member-mutation paths, and
    /// `acceptGroupInvite`, and `applyGroupDetails` is completion-ordered, not request-ordered.
    /// Mirrors the settings-load / group-image-search generation guards (issues #2, #4, #110)
    /// and uses the same wrapping-token overflow hardening (issue #182).
    /// See `loadGroupDetails` / issue #135.
    var groupDetailsLoadGeneration: UInt64 = 0
    /// Raw per-sender FFI lookups (userProfile + directory displayName), cached so that
    /// scrolling back through history does not re-resolve the same senders from Rust on
    /// every page. Keyed by sender accountIdHex.
    ///
    /// Entries carry the resolution timestamp and whether the lookup produced a usable
    /// profile (display name or picture). This prevents the cache from acting as a
    /// permanent "seen" flag (whitenoise-mac#8): complete entries expire after
    /// `peerProfileCacheTTL` so a contact's later name/avatar change is eventually
    /// picked up within a session, and incomplete entries (relay not yet propagated, or
    /// a failed/empty lookup) are always re-resolved so a contact is never pinned to a
    /// fallback name/avatar for the life of the process. The cache is also account-scoped
    /// and cleared on account switch.
    var peerProfileFFICache: [String: CachedPeerProfile] = [:]

    /// Per-group membership cache used by chat-list enrichment and timeline sender-name
    /// projection. Group rows already carry the latest group metadata; these call sites only
    /// need members to identify direct chats and provide member-name fallbacks, so cache just
    /// that membership slice and invalidate it on membership-changing subscription events.
    var groupMemberDetailsCache: [String: [GroupMemberDetailsFfi]] = [:]
    var groupMemberDetailsLookups: [String: GroupMemberDetailsLookup] = [:]
    var readStateMetadataEnrichmentAttempts = Set<String>()
    var nextGroupMemberDetailsLookupToken: UInt64 = 0

    #if DEBUG
        /// Test-only instrumentation: the number of times `messageSenderProfiles` had to fetch the
        /// group member list to build the sender-name fallback map. In the all-resolved steady
        /// state this must stay flat across timeline windows (whitenoise-mac#171). Not read by
        /// production code.
        var timelineSenderMemberFallbackFetchCount = 0

        /// Test hook for stale-result generation counter overflow hardening (issue #182).
        /// Production code only compares owner tokens for equality, so wraparound is valid.
        func seedStaleResultGenerationsForTesting(_ generation: UInt64) {
            newChatLookupGeneration = generation
            groupImageSearchGeneration = generation
            groupDetailsLoadGeneration = generation
        }

        /// Bumps the same counters through their production `begin*` paths so tests exercise `&+=`.
        func bumpStaleResultGenerationsForTesting() -> (
            newChatLookup: UInt64,
            groupImageSearch: UInt64,
            groupDetailsLoad: UInt64
        ) {
            return (
                beginNewChatLookup(),
                beginGroupImageSearch(),
                beginGroupDetailsLoad()
            )
        }

        /// Evaluates the production generation-ownership guards for a captured token.
        func ownsStaleResultGenerationsForTesting(generation: UInt64) -> (
            newChatLookup: Bool,
            groupImageSearch: Bool,
            groupDetailsLoad: Bool
        ) {
            return (
                ownsNewChatLookup(generation: generation),
                ownsGroupImageSearch(generation: generation),
                ownsGroupDetailsLoad(generation: generation)
            )
        }
    #endif

    /// How long a *complete* peer-profile lookup is trusted before it is re-resolved
    /// from the Rust store. Incomplete lookups ignore the TTL and re-resolve every pass.
    static let peerProfileCacheTTL: TimeInterval = 300

    static let activeAccountKey = "whitenoise.mac.activeAccountId"
    static let developerModeKey = "whitenoise.mac.developerMode"
    static let streamingDebugModeKey = "whitenoise.mac.streamingDebugMode"
    static let appearancePreferenceKey = "whitenoise.mac.appearancePreference"
    static let notificationPreviewModeKey = "whitenoise.mac.notificationPreviewMode"
    static let loadRemoteImagesKey = "whitenoise.mac.loadRemoteImages"
    static let deliveredNotificationKeyLimit = 256
    static let timelinePageLimit: UInt32 = 100
    /// Upper bound on the materialized live window, matching the runtime's
    /// `TIMELINE_WINDOW_LIMIT`. Live projection deltas grow the window up to this cap
    /// before the oldest rows are trimmed (and `hasMoreBefore` is re-flagged), mirroring
    /// `apply_projection_to_window` in the core so client-side delta application stays in
    /// lockstep with the runtime's windowing.
    static let timelineWindowLimit = 200
    /// Reconnect immediately once when a subscription stream ends, then use a capped
    /// backoff if a broken stream keeps ending during startup. This avoids silent
    /// listener death without tight-looping on an already-closed runtime channel.
    static let listenerReconnectDelaysNanoseconds: [UInt64] = [
        0,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000,
        10_000_000_000,
    ]

    static func listenerReconnectDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let index = min(max(attempt, 0), listenerReconnectDelaysNanoseconds.count - 1)
        return listenerReconnectDelaysNanoseconds[index]
    }

    /// Dedicated queue for blocking MarmotRuntime FFI calls. The Rust core runs
    /// synchronously (DB reads, MLS decryption); WorkspaceState is `@MainActor`, so
    /// calling these directly freezes the UI. We hop them onto this queue and await the
    /// result on the main actor. UniFFI objects are internally thread-safe.
    nonisolated static let ffiQueue = DispatchQueue(
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

        /// A lookup is "complete" once it yields a usable display name or picture. An
        /// incomplete lookup means the relay has not propagated the profile yet (or the
        /// lookup failed), and must not be trusted as a terminal answer.
        var isComplete: Bool {
            firstNonBlank([profileDisplayName, profileName, directoryDisplayName]) != nil
                || profilePicture?.nilIfBlank != nil
        }
    }

    /// A `ResolvedPeerFFI` plus the time it was resolved, so the cache can apply a TTL to
    /// complete lookups and always re-resolve incomplete ones (whitenoise-mac#8).
    struct CachedPeerProfile: Sendable {
        var resolved: ResolvedPeerFFI
        var resolvedAt: Date

        /// Whether this entry may be reused without re-resolving from the Rust store.
        /// Incomplete lookups are never reused; complete lookups are reused until the TTL
        /// elapses so later name/avatar changes are eventually picked up within a session.
        func isFresh(now: Date, ttl: TimeInterval) -> Bool {
            resolved.isComplete && now.timeIntervalSince(resolvedAt) < ttl
        }
    }

    struct GroupMemberDetailsLookup {
        var token: UInt64
        var task: Task<[GroupMemberDetailsFfi]?, Never>
    }

    struct MediaDiskStoreGuard: Equatable {
        var globalGeneration: UInt64
        var accountGeneration: UInt64
    }

    struct MediaDiskStoreTask {
        var accountId: String
        var token: UInt64
        var task: Task<Void, Never>
    }

    /// Raw output of the per-account bootstrap/settings FFI lookups.
    struct ResolvedAccountFFI: Sendable {
        var profileDisplayName: String?
        var profileName: String?
        var profilePicture: String?
        var directoryDisplayName: String?
        var npub: String?
    }

    /// Runs a blocking FFI closure off the main thread and resumes on the caller's actor.
    nonisolated func runOffMain<T>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Self.ffiQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
    static var notificationPermissionGuidance: String {
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
        copyTextHandler: @escaping @MainActor (String, Bool) -> Void = WorkspaceState.copyToGeneralPasteboard,
        telemetryBuildConfigProvider: @escaping @MainActor () -> TelemetryBuildConfig = {
            TelemetryBuildConfig.current()
        },
        groupImageSearchClient: (any GroupImageSearchClient)? = nil,
        nowProvider: @escaping @MainActor () -> Date = { Date() },
        mediaDiskCache: MessageMediaDiskCache = .shared,
        clientFactory: @escaping @MainActor () throws -> any MarmotRuntime = { try MarmotClient() }
    ) {
        self.accounts = accounts
        self.chatsByAccount = chatsByAccount
        self.messageTimelineStores = messagesByChat.mapValues { MessageTimelineStore.loaded(with: $0) }
        self.cachedMessageChatIds = Set(messagesByChat.keys)
        self.localNotificationCenter = localNotificationCenter ?? MacLocalNotificationCenter()
        self.appActivityProvider = appActivityProvider
        self.conversationWindowVisibilityProvider = conversationWindowVisibilityProvider
        self.copyTextHandler = copyTextHandler
        self.telemetryBuildConfigProvider = telemetryBuildConfigProvider
        self.groupImageSearchClient = groupImageSearchClient ?? OpenverseGroupImageSearchClient()
        self.nowProvider = nowProvider
        self.mediaDiskCache = mediaDiskCache
        self.clientFactory = clientFactory
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.streamingDebugMode = UserDefaults.standard.bool(forKey: Self.streamingDebugModeKey)
        // Defaults to false: bool(forKey:) returns false when the key is absent, which is the
        // privacy-preserving default (remote peer images are not fetched until the user opts in).
        self.loadRemoteImages = UserDefaults.standard.bool(forKey: Self.loadRemoteImagesKey)
        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearancePreferenceKey)
        self.appearancePreference = storedAppearance.flatMap(AppearancePreference.init(rawValue:)) ?? .system
        let storedPreviewMode = UserDefaults.standard.string(forKey: Self.notificationPreviewModeKey)
        self.notificationPreviewMode = storedPreviewMode.flatMap(NotificationPreviewMode.init(rawValue:)) ?? .full
        let storedLanguage = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        self.languagePreference = AppLanguage.resolved(rawValue: storedLanguage)
        rebuildChatIndexes()
        self.activeAccountId =
            UserDefaults.standard.string(forKey: Self.activeAccountKey)
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
        ensureSelectedMessageTimelineStore()
    }

    static func defaultConversationWindowVisibilityProvider() -> Bool {
        guard let keyWindow = NSApplication.shared.keyWindow else { return false }
        return keyWindow.isVisible && !keyWindow.isMiniaturized
    }

    func selectedConversationIsVisible() -> Bool {
        appActivityProvider() && conversationWindowVisibilityProvider()
    }

    static func preview() -> WorkspaceState {
        let state = WorkspaceState(
            accounts: AccountItem.samples,
            chatsByAccount: [
                AccountItem.samples[0].id: ChatItem.samples,
                AccountItem.samples[1].id: Array(ChatItem.samples.dropFirst()),
                AccountItem.samples[2].id: [ChatItem.samples[2]],
            ],
            messagesByChat: MessageItem.samples,
            clientFactory: { throw PreviewRuntimeError() }
        )
        state.activeAccountId = AccountItem.samples[0].id
        state.selection = .chat(ChatItem.samples[0].id)
        return state
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
        guard let activeAccountId else { return [] }
        let generation = chatListGenerationByAccount[activeAccountId] ?? 0
        let query = searchText
        if let cache = filteredChatsCache,
            cache.accountId == activeAccountId,
            cache.generation == generation,
            cache.query == query
        {
            return cache.result
        }

        let result = ChatFilter.filtered(chatsByAccount[activeAccountId] ?? [], query: query)
        filteredChatsCache = FilteredChatsCache(
            accountId: activeAccountId,
            generation: generation,
            query: query,
            result: result
        )
        return result
    }

    var selectedChat: ChatItem? {
        guard case .chat(let chatId) = selection else { return nil }
        return activeAccountId.flatMap { chatLookupByAccount[$0]?[chatId] }
    }

    var resolvedNewChatRecipient: NewChatRecipient? {
        guard let newChatRecipient,
            newChatRecipient.matches(query: newChatQuery)
        else { return nil }

        return newChatRecipient
    }

    func setChats(_ chats: [ChatItem], forAccountId accountId: String) {
        chatsByAccount[accountId] = chats
        rebuildChatIndexes(forAccountId: accountId)
    }

    func upsertChat(_ chat: ChatItem, forAccountId accountId: String) {
        let chats = chatsByAccount[accountId] ?? []
        let result = ChatListOrdering.upsertResult(
            chat,
            into: chats,
            existingIndex: chatIndex(accountId: accountId, chatId: chat.id)
        )
        chatsByAccount[accountId] = result.chats

        if let reindexStart = result.reindexStart {
            reindexChats(forAccountId: accountId, startingAt: reindexStart)
        } else {
            var lookup = chatLookupByAccount[accountId] ?? [:]
            lookup[chat.id] = chat
            chatLookupByAccount[accountId] = lookup
        }
        bumpChatListGeneration(forAccountId: accountId)
    }

    func removeChatFromList(chatId: String, forAccountId accountId: String) -> [ChatItem] {
        var chats = chatsByAccount[accountId] ?? []
        if let index = chatIndex(accountId: accountId, chatId: chatId) {
            chats.remove(at: index)
            chatsByAccount[accountId] = chats

            var lookup = chatLookupByAccount[accountId] ?? [:]
            lookup[chatId] = nil
            chatLookupByAccount[accountId] = lookup

            var indexes = chatIndexByAccount[accountId] ?? [:]
            indexes[chatId] = nil
            chatIndexByAccount[accountId] = indexes

            reindexChats(forAccountId: accountId, startingAt: index)
            bumpChatListGeneration(forAccountId: accountId)
            return chats
        }

        let originalCount = chats.count
        chats.removeAll { $0.id == chatId }
        guard chats.count != originalCount else { return chats }
        setChats(chats, forAccountId: accountId)
        return chats
    }

    func removeChats(forAccountId accountId: String) {
        chatsByAccount[accountId] = nil
        chatLookupByAccount[accountId] = nil
        chatIndexByAccount[accountId] = nil
        bumpChatListGeneration(forAccountId: accountId)
    }

    func resetChats() {
        chatsByAccount = [:]
        chatLookupByAccount = [:]
        chatIndexByAccount = [:]
        chatListGenerationByAccount = [:]
        filteredChatsCache = nil
    }

    func rebuildChatIndexes() {
        chatLookupByAccount = [:]
        chatIndexByAccount = [:]
        for accountId in chatsByAccount.keys {
            rebuildChatIndexes(forAccountId: accountId)
        }
    }

    func rebuildChatIndexes(forAccountId accountId: String) {
        let chats = chatsByAccount[accountId] ?? []
        chatLookupByAccount[accountId] = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        chatIndexByAccount[accountId] = Dictionary(
            uniqueKeysWithValues: chats.enumerated().map {
                ($0.element.id, $0.offset)
            })
        bumpChatListGeneration(forAccountId: accountId)
    }

    func reindexChats(forAccountId accountId: String, startingAt startIndex: Int) {
        let chats = chatsByAccount[accountId] ?? []
        guard startIndex < chats.endIndex else { return }

        var lookup = chatLookupByAccount[accountId] ?? [:]
        var indexes = chatIndexByAccount[accountId] ?? [:]
        for index in max(0, startIndex)..<chats.endIndex {
            let chat = chats[index]
            lookup[chat.id] = chat
            indexes[chat.id] = index
        }
        chatLookupByAccount[accountId] = lookup
        chatIndexByAccount[accountId] = indexes
    }

    func chatItem(accountId: String, chatId: String) -> ChatItem? {
        chatLookupByAccount[accountId]?[chatId]
    }

    func chatIndex(accountId: String, chatId: String) -> Int? {
        chatIndexByAccount[accountId]?[chatId]
    }

    private func bumpChatListGeneration(forAccountId accountId: String) {
        chatListGenerationByAccount[accountId, default: 0] += 1
        if filteredChatsCache?.accountId == accountId {
            filteredChatsCache = nil
        }
    }

    @discardableResult
    func ensureMessageTimelineStore(for groupIdHex: String) -> MessageTimelineStore {
        if let store = messageTimelineStores[groupIdHex] {
            return store
        }
        // A chat is only ever cached while its store exists (`cachedMessageChatIds` is kept a
        // subset of `messageTimelineStores`), so a missing store means there is nothing to seed.
        let store = MessageTimelineStore()
        messageTimelineStores[groupIdHex] = store
        return store
    }

    func ensureSelectedMessageTimelineStore() {
        guard let selectedChat else { return }
        ensureMessageTimelineStore(for: selectedChat.id)
    }

    var selectedMessages: [MessageItem] {
        guard let selectedChat else { return [] }
        return messageTimelineStores[selectedChat.id]?.messages ?? []
    }

    var selectedMessageIDs: [String] {
        guard let selectedChat else { return [] }
        return messageTimelineStores[selectedChat.id]?.messageIDs ?? []
    }

    var selectedTimelinePaging: TimelinePagingState {
        guard let selectedChat else { return .empty }
        return timelinePagingByChat[selectedChat.id] ?? .empty
    }

    var selectedTimelineIsLoadingInitialPage: Bool {
        guard let selectedChat else { return false }
        return timelineInitialLoadGroupId == selectedChat.id
            && !(messageTimelineStores[selectedChat.id]?.isLoaded ?? false)
    }

    func timelineMessage(groupIdHex: String, messageId: String) -> MessageItem? {
        messageTimelineStores[groupIdHex]?.lookup[messageId]
    }

    func selectedTimelineContainsMessage(_ messageId: String) -> Bool {
        guard let selectedChat else { return false }
        return messageTimelineStores[selectedChat.id]?.containsMessage(id: messageId) ?? false
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
            DiagnosticsInfoItem(
                title: L10n.string("Device model"), value: config.deviceModelIdentifier ?? L10n.string("Unknown")),
            DiagnosticsInfoItem(title: L10n.string("Marmot"), value: marmotBuildSummary),
        ]
    }

    var canSend: Bool {
        client != nil
            && selectedChat != nil
            && (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingMediaAttachments.isEmpty)
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
        if let locale = languagePreference.locale {
            return locale
        }
        _ = systemLocaleRefreshRevision
        return AppLanguage.currentLocale
    }

    func refreshSystemLanguageIfNeeded() {
        guard languagePreference == .system else { return }
        let systemLocaleIdentifier = AppLanguage.currentSystemLocaleIdentifier()
        guard systemLocaleIdentifier != observedSystemLocaleIdentifier else { return }

        observedSystemLocaleIdentifier = systemLocaleIdentifier
        AppLanguage.refreshCachedLocale()
        // `preferredLocale` reads this revision so SwiftUI has a concrete
        // observable mutation to re-render against after the system language
        // changes without rewriting the stored in-app language preference.
        systemLocaleRefreshRevision += 1
    }

    func groupDetailsSnapshot(
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
        let avatarURL = firstNonBlank([details.group.avatarUrl])

        return GroupDetailsSnapshot(
            groupIdHex: details.group.groupIdHex,
            endpoint: details.group.endpoint,
            name: firstNonBlank([details.group.name]) ?? L10n.string("Unnamed group"),
            description: details.group.description,
            avatarURL: avatarURL,
            sanitizedAvatarURL: RemoteImageURLPolicy.sanitizedURL(from: avatarURL),
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
            requiresSelfDemoteBeforeLeave: managementState.requiresSelfDemoteBeforeLeave,
            disappearingMessageSecs: details.group.disappearingMessageSecs
        )
    }

    var remainingMediaAttachmentSlots: Int {
        max(0, OutgoingMediaDraftProcessor.maxAttachmentCount - pendingMediaAttachments.count)
    }

    enum VoiceRecordingFailure: Error {
        case startFailed
    }

    /// The community-convention pasteboard type (https://nspasteboard.org) that privacy-aware
    /// clipboard managers check for to treat an item as transient: they skip persisting it to
    /// clipboard history, and it also discourages Universal Clipboard / Handoff from broadcasting
    /// the item to the user's other Apple devices.
    static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copyToGeneralPasteboard(_ text: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            // Non-destructive: apps that don't recognise the concealed type still read `.string`.
            pasteboard.setString(text, forType: Self.concealedPasteboardType)
        }
    }

    var telemetryBuildConfig: TelemetryBuildConfig {
        telemetryBuildConfigProvider()
    }

    func refreshObservabilityRuntime() {
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
    func setBackgroundStatus(_ message: String?) {
        backgroundStatus = message
    }

    /// Dismiss the background status banner (e.g. user tapped the close control, or a
    /// later background operation succeeded).
    func clearBackgroundStatus() {
        backgroundStatus = nil
    }

    func reportUserActionError(_ message: String) {
        lastError = message
    }

    func waitBeforeListenerReconnect(attempt: Int) async throws {
        let delay = Self.listenerReconnectDelayNanoseconds(forAttempt: attempt)
        guard delay > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(nanoseconds: delay)
    }

    func configureObservabilityRuntime() async throws {
        guard let client else {
            observabilityRuntimeConfiguration = nil
            return
        }

        let config = telemetryBuildConfig
        let accountLabel = activeAccount?.displayName
        if let cached = observabilityRuntimeConfiguration,
            cached.buildConfig == config,
            cached.accountLabel == accountLabel
        {
            privacySecuritySettings.telemetryCredentialsAvailable = config.telemetryCredentialsAvailable
            privacySecuritySettings.auditLogCredentialsAvailable = config.auditLogCredentialsAvailable
            return
        }

        let relayRuntimeConfig: RelayTelemetryRuntimeConfigFfi
        if let cached = observabilityRuntimeConfiguration,
            cached.buildConfig == config
        {
            relayRuntimeConfig = cached.relayTelemetryRuntimeConfig
        } else {
            let installId = try await runOffMain {
                try client.telemetryInstallId()
            }
            relayRuntimeConfig = config.runtimeConfig(installId: installId)
        }
        let auditTrackerConfig = config.auditTrackerConfig()

        if observabilityRuntimeConfiguration?.relayTelemetryRuntimeConfig != relayRuntimeConfig {
            try await client.setRelayTelemetryRuntimeConfig(config: relayRuntimeConfig)
        }
        if observabilityRuntimeConfiguration?.auditLogTrackerConfig != auditTrackerConfig {
            _ = try await runOffMain {
                try client.setAuditLogTrackerConfig(config: auditTrackerConfig)
            }
        }

        observabilityRuntimeConfiguration = ObservabilityRuntimeConfiguration(
            buildConfig: config,
            accountLabel: accountLabel,
            relayTelemetryRuntimeConfig: relayRuntimeConfig,
            auditLogTrackerConfig: auditTrackerConfig
        )
        privacySecuritySettings.telemetryCredentialsAvailable = config.telemetryCredentialsAvailable
        privacySecuritySettings.auditLogCredentialsAvailable = config.auditLogCredentialsAvailable
    }

    var isShowingSettings: Bool {
        if case .settings = selection { return true }
        return false
    }
}

enum GroupMemberMutationAction {
    case promote
    case demote
    case remove
}

nonisolated struct ReadMarker: Equatable, Comparable {
    let sentAt: Date
    let messageId: String

    static func < (lhs: ReadMarker, rhs: ReadMarker) -> Bool {
        if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
        return lhs.messageId < rhs.messageId
    }

    /// Returns the read marker to keep after a failed optimistic advance.
    ///
    /// `confirmed` is the last marker known to have committed through FFI. A
    /// caller's optimistic snapshot is not enough for rollback because another
    /// overlapping call may have advanced the slot without committing.
    static func afterFailedOptimisticAdvance(
        current: ReadMarker?,
        attempted: ReadMarker,
        confirmed: ReadMarker?
    ) -> ReadMarker? {
        current == attempted ? confirmed : current
    }

    /// Returns the marker slots to keep after FFI confirms `attempted`.
    ///
    /// If a newer optimistic marker is currently in flight, keep it as the read
    /// gate while recording `attempted` as the latest confirmed value. If a
    /// newer failed call already rolled the gate back, restore it to the marker
    /// that just committed. The returned `current` value is written back to
    /// `lastMarkedReadMarkers`; `confirmed` is written to `lastConfirmedReadMarkers`.
    static func afterSuccessfulCommit(
        current: ReadMarker?,
        confirmed: ReadMarker?,
        attempted: ReadMarker
    ) -> (current: ReadMarker, confirmed: ReadMarker) {
        (
            current: latest(current, attempted),
            confirmed: latest(confirmed, attempted)
        )
    }

    private static func latest(_ marker: ReadMarker?, _ candidate: ReadMarker) -> ReadMarker {
        guard let marker, marker > candidate else { return candidate }
        return marker
    }
}

extension NotificationSettingsSnapshot {
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
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) {
            result, element in
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

extension UNAuthorizationStatus {
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
        case (let creator?, let license?):
            return "\(creator) · \(license.uppercased())"
        case (let creator?, nil):
            return creator
        case (nil, let license?):
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
            // Openverse caps anonymous (unauthenticated) requests at page_size 20 and
            // rejects anything larger with HTTP 401, so stay at the anonymous ceiling.
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "mature", value: "false"),
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

struct OpenverseImageSearchResponse: Decodable {
    let results: [OpenverseImageRecord]
}

struct OpenverseImageRecord: Decodable {
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

enum GroupImageSearchError: LocalizedError {
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

struct PreviewRuntimeError: Error {}

extension ProfileDraft {
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
        firstNonBlank([displayName, name, fallback]) ?? fallback
    }
}

extension RelaySettingsSnapshot {
    init(lists: AccountRelayListsFfi) {
        self.init(
            nip65: lists.nip65.relays.isEmpty ? lists.defaultRelays : lists.nip65.relays,
            inbox: lists.inbox.relays.isEmpty ? lists.defaultRelays : lists.inbox.relays,
            defaultRelays: lists.defaultRelays,
            bootstrapRelays: lists.bootstrapRelays,
            publishedNip65: lists.nip65.relays,
            publishedInbox: lists.inbox.relays,
            missing: lists.missing.map(\.displayLabel),
            isComplete: lists.complete
        )
    }
}

extension MissingRelayListKindFfi {
    /// User-facing name for a relay list the account hasn't published yet.
    var displayLabel: String {
        switch self {
        case .nip65: return "NIP-65"
        case .inbox: return "Inbox"
        @unknown default: return "Unknown"
        }
    }
}

extension KeyPackageItem {
    init(package: AccountKeyPackageFfi) {
        self.init(
            accountRef: package.accountRef,
            accountIdHex: package.accountIdHex,
            keyPackageId: package.keyPackageId,
            keyPackageRefHex: package.keyPackageRefHex,
            eventIdHex: package.eventIdHex,
            publishedAt: package.publishedAt == 0
                ? nil : Date(timeIntervalSince1970: TimeInterval(package.publishedAt)),
            keyPackageBytes: package.keyPackageBytes,
            sourceRelays: package.sourceRelays,
            isLocal: package.local,
            isRelayDiscovered: package.relay
        )
    }
}
