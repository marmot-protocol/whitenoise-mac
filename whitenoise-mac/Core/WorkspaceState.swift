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

struct ChatListOrdering {
    static func sorted(_ chatItems: [ChatItem]) -> [ChatItem] {
        chatItems.sorted(by: areInDisplayOrder)
    }

    static func upserting(_ chat: ChatItem, into chats: [ChatItem]) -> [ChatItem] {
        var result = chats
        if let index = result.firstIndex(where: { $0.id == chat.id }) {
            if canReplaceInPlace(chat, at: index, in: result) {
                result[index] = chat
                return result
            }
            result.remove(at: index)
        }

        result.insert(chat, at: insertionIndex(for: chat, in: result))
        return result
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
final class MediaDownloadStateStore: ObservableObject {
    @Published private(set) var state: MediaDownloadState = .idle

    func update(_ newState: MediaDownloadState) {
        guard state != newState else { return }
        state = newState
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

    private struct ObservabilityRuntimeConfiguration: Equatable {
        let buildConfig: TelemetryBuildConfig
        let accountLabel: String?
        let relayTelemetryRuntimeConfig: RelayTelemetryRuntimeConfigFfi
        let auditLogTrackerConfig: AuditLogTrackerConfigFfi
    }

    private(set) var phase: Phase = .bootstrapping
    private(set) var accounts: [AccountItem]
    private(set) var chatsByAccount: [String: [ChatItem]]
    private(set) var messagesByChat: [String: [MessageItem]]
    @ObservationIgnored private var mediaDownloads: [String: MediaDownloadStateStore] = [:]
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
    var pendingMediaAttachments: [PendingMediaAttachment] {
        guard let selectedComposerDraftKey else { return [] }
        return pendingMediaAttachmentsByConversation[selectedComposerDraftKey] ?? []
    }
    var isRefreshing = false
    var isSending = false
    private(set) var isRecordingVoiceMessage = false
    private(set) var voiceRecordingSamples: [CGFloat] = []
    private(set) var voiceRecordingDurationSeconds: Double = 0
    /// Per-target reentrancy guards for message actions. `react`/`deleteMessage`
    /// operate on arbitrary messages, so a single in-flight bool (like `isSending`)
    /// would wrongly block acting on a *different* message. We key on the action's
    /// target instead so only a duplicate of the *same* in-flight action is dropped.
    private var inFlightReactionKeys = Set<String>()
    private var inFlightDeleteMessageIds = Set<String>()
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
    private var observedSystemLocaleIdentifier = AppLanguage.currentSystemLocaleIdentifier()
    private(set) var systemLocaleRefreshRevision = 0
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
    var isAcceptingGroupInvite = false
    var isDecliningGroupInvite = false
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
    private var pendingMediaAttachmentsByConversation: [ComposerDraftKey: [PendingMediaAttachment]] = [:]
    private var voiceRecorder: AVAudioRecorder?
    private var voiceRecordingURL: URL?
    private var voiceRecordingMeterTask: Task<Void, Never>?

    private var selectedComposerDraftKey: ComposerDraftKey? {
        guard let activeAccountId, case .chat(let chatId) = selection else { return nil }
        return ComposerDraftKey(accountId: activeAccountId, chatId: chatId)
    }

    private func clearAllComposerDrafts() {
        draftTextByConversation.removeAll()
        replyDraftContextByConversation.removeAll()
        pendingMediaAttachmentsByConversation.removeAll()
    }

    private func clearComposerDrafts(for chatIds: [String], accountId: String) {
        for chatId in chatIds {
            let key = ComposerDraftKey(accountId: accountId, chatId: chatId)
            draftTextByConversation[key] = nil
            replyDraftContextByConversation[key] = nil
            pendingMediaAttachmentsByConversation[key] = nil
        }
    }

    private func clearComposerDrafts(forAccountId accountId: String) {
        for key in draftTextByConversation.keys.filter({ $0.accountId == accountId }) {
            draftTextByConversation[key] = nil
        }
        for key in replyDraftContextByConversation.keys.filter({ $0.accountId == accountId }) {
            replyDraftContextByConversation[key] = nil
        }
        for key in pendingMediaAttachmentsByConversation.keys.filter({ $0.accountId == accountId }) {
            pendingMediaAttachmentsByConversation[key] = nil
        }
    }

    private let clientFactory: @MainActor () throws -> any MarmotRuntime
    private let localNotificationCenter: any LocalNotificationCenter
    private let appActivityProvider: @MainActor () -> Bool
    private let conversationWindowVisibilityProvider: @MainActor () -> Bool
    private let copyTextHandler: @MainActor (String, Bool) -> Void
    private let telemetryBuildConfigProvider: @MainActor () -> TelemetryBuildConfig
    private let groupImageSearchClient: any GroupImageSearchClient
    /// Injectable clock for peer-profile cache TTL decisions, so tests can drive cache
    /// expiry deterministically (whitenoise-mac#8). Defaults to the system clock.
    private let nowProvider: @MainActor () -> Date
    private var client: (any MarmotRuntime)?
    private var observabilityRuntimeConfiguration: ObservabilityRuntimeConfiguration?
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
    /// Single-owner coalescing for the aggregate settings load (issue #4). `loadSettingsData()`
    /// is invoked from more than one entry point — the settings view's `.task(id: activeAccountId)`
    /// and explicit reloads (e.g. after removing the active account) — which can otherwise issue
    /// overlapping profile / relay / notification / privacy fetches for the same account. The
    /// in-flight task is tracked here keyed by `settingsLoadAccountId`: a concurrent request for the
    /// same account awaits the existing task (coalesces) instead of starting a duplicate, and a
    /// request for a different account cancels the now-stale load so it cannot clobber fresher state.
    private var settingsLoadTask: Task<Void, Never>?
    private var settingsLoadAccountId: String?
    /// Monotonic token identifying the most recently started settings load. `performSettingsLoad`
    /// captures the value at launch and only clears `isLoadingSettings` in its `defer` if it is
    /// still the current generation — i.e. no newer load has superseded it. This distinguishes
    /// "superseded by a newer load" (must NOT dismiss the spinner the newer load owns) from
    /// "cancelled with no replacement" (the active account was cleared, so the spinner MUST be
    /// dismissed instead of left stuck). See `loadSettingsData` / issue #4.
    private var settingsLoadGeneration: UInt64 = 0
    private var timelineTask: Task<Void, Never>?
    private var timelineTaskGroupId: String?
    /// The live timeline subscription for the open conversation. It owns the
    /// authoritative, bounded, materialized window; scroll-back/forward pagination and
    /// live updates all flow through it (`paginateBackwards` / `paginateForwards` / `next`).
    /// Kept alive for pagination independent of the listener task. The listener replaces
    /// it after a recoverable stream end/reconnect, and it is cleared only when the
    /// conversation is torn down.
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
    private var lastConfirmedReadMarkers: [String: ReadMarker] = [:]
    private var deliveredNotificationKeys = Set<String>()
    private var deliveredNotificationKeyOrder: [String] = []
    private var newChatLookupGeneration = 0
    /// Monotonic token identifying the most recently started group-image (Openverse) search.
    /// `searchGroupImages` captures the value before its `await` and only commits results /
    /// clears `isSearchingGroupImages` while it is still current — i.e. no newer search has
    /// superseded it and the picker is still on screen for the same query. This makes the
    /// search last-request-wins (a slow earlier search cannot overwrite a newer one) and
    /// prevents a search resolving after the picker is dismissed/reopened from repopulating
    /// `groupImageResults`. Mirrors the new-chat lookup / settings-load generation guards
    /// (issues #2, #4). See `searchGroupImages` / issue #110.
    private var groupImageSearchGeneration = 0
    /// Monotonic token identifying the most recently started group-details load. `loadGroupDetails`
    /// captures the value on entry and only applies the fetched snapshot, clears
    /// `isLoadingGroupDetails`, or reports errors while it is still current — i.e. no newer load or
    /// `closeGroupDetails` has bumped the generation. This makes the load last-request-wins (a slow
    /// earlier load cannot clobber a newer snapshot or prematurely drop the shared spinner) and
    /// prevents a load resolving after group details are closed from repopulating closed UI state.
    /// `loadGroupDetails` is reachable concurrently for the same group from `showGroupDetails`,
    /// `reloadSelectedGroupDetails`, `saveGroupProfile`, member-mutation paths, and
    /// `acceptGroupInvite`, and `applyGroupDetails` is completion-ordered, not request-ordered.
    /// Mirrors the settings-load / group-image-search generation guards (issues #2, #4, #110).
    /// See `loadGroupDetails` / issue #135.
    private var groupDetailsLoadGeneration = 0
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
    private var peerProfileFFICache: [String: CachedPeerProfile] = [:]

    /// Per-group membership cache used by chat-list enrichment and timeline sender-name
    /// projection. Group rows already carry the latest group metadata; these call sites only
    /// need members to identify direct chats and provide member-name fallbacks, so cache just
    /// that membership slice and invalidate it on membership-changing subscription events.
    private var groupMemberDetailsCache: [String: [GroupMemberDetailsFfi]] = [:]
    private var groupMemberDetailsLookups: [String: GroupMemberDetailsLookup] = [:]
    private var readStateMetadataEnrichmentAttempts = Set<String>()
    private var nextGroupMemberDetailsLookupToken: UInt64 = 0

    /// How long a *complete* peer-profile lookup is trusted before it is re-resolved
    /// from the Rust store. Incomplete lookups ignore the TTL and re-resolve every pass.
    private static let peerProfileCacheTTL: TimeInterval = 300

    private static let activeAccountKey = "whitenoise.mac.activeAccountId"
    private static let developerModeKey = "whitenoise.mac.developerMode"
    private static let streamingDebugModeKey = "whitenoise.mac.streamingDebugMode"
    private static let appearancePreferenceKey = "whitenoise.mac.appearancePreference"
    private static let notificationPreviewModeKey = "whitenoise.mac.notificationPreviewMode"
    private static let loadRemoteImagesKey = "whitenoise.mac.loadRemoteImages"
    private static let deliveredNotificationKeyLimit = 256
    private static let timelinePageLimit: UInt32 = 100
    /// Reconnect immediately once when a subscription stream ends, then use a capped
    /// backoff if a broken stream keeps ending during startup. This avoids silent
    /// listener death without tight-looping on an already-closed runtime channel.
    private static let listenerReconnectDelaysNanoseconds: [UInt64] = [
        0,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000,
        10_000_000_000,
    ]

    private static func listenerReconnectDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let index = min(max(attempt, 0), listenerReconnectDelaysNanoseconds.count - 1)
        return listenerReconnectDelaysNanoseconds[index]
    }

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

    /// Raw output of the per-account bootstrap/settings FFI lookups.
    struct ResolvedAccountFFI: Sendable {
        var profileDisplayName: String?
        var profileName: String?
        var profilePicture: String?
        var directoryDisplayName: String?
        var npub: String?
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
        copyTextHandler: @escaping @MainActor (String, Bool) -> Void = WorkspaceState.copyToGeneralPasteboard,
        telemetryBuildConfigProvider: @escaping @MainActor () -> TelemetryBuildConfig = {
            TelemetryBuildConfig.current()
        },
        groupImageSearchClient: (any GroupImageSearchClient)? = nil,
        nowProvider: @escaping @MainActor () -> Date = { Date() },
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
        self.nowProvider = nowProvider
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
    }

    private static func defaultConversationWindowVisibilityProvider() -> Bool {
        guard let keyWindow = NSApplication.shared.keyWindow else { return false }
        return keyWindow.isVisible && !keyWindow.isMiniaturized
    }

    private func selectedConversationIsVisible() -> Bool {
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

    func bootstrap() async {
        guard client == nil, case .bootstrapping = phase else { return }
        lastError = nil
        do {
            let runtime = try clientFactory()
            client = runtime
            storageRootPath = runtime.storageRootPath
            let summaries = try await runOffMain {
                try runtime.listAccounts()
            }
            accounts = try await accountItems(from: summaries, client: runtime)
            restoreOrSelectFirstAccount()
            try await configureObservabilityRuntime()
            if accounts.isEmpty {
                phase = .onboarding
                return
            }

            try await bringRuntimeOnline(runtime)
            accounts = try await accountItemsFromRuntime(client: runtime)
            restoreOrSelectFirstAccount()
            try await activateReadyState()
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func selectAccount(_ account: AccountItem) {
        switchActiveAccount(
            account,
            finalSelection: chatsByAccount[account.id]?.first.map { WorkspaceSelection.chat($0.id) }
        )
    }

    func selectAccountFromSettings(_ account: AccountItem) {
        switchActiveAccount(account, finalSelection: .settings(.accounts))
    }

    private func switchActiveAccount(_ account: AccountItem, finalSelection: WorkspaceSelection?) {
        prepareForActiveAccountSwitch(to: account, preservingMessageCacheFor: nil)
        selection = finalSelection
        if case .chat(let chatId)? = finalSelection {
            beginTimelineInitialLoadIfNeeded(groupIdHex: chatId)
        }
        Task {
            await reloadChats()
            if let selectedChat {
                await loadMessages(groupIdHex: selectedChat.id)
            }
        }
    }

    /// Performs all account-scoped teardown before any chat or message reloads run.
    /// Keeping listener stops, cache pruning, peer-profile invalidation, and
    /// observability refresh together prevents reloads from seeing stale account state.
    private func prepareForActiveAccountSwitch(
        to account: AccountItem,
        preservingMessageCacheFor groupIdHex: String?
    ) {
        cancelVoiceRecording()
        stopTimelineListener()
        stopChatListListener()
        clearEnteredLoginIdentity()
        activeAccountId = account.id
        UserDefaults.standard.set(account.id, forKey: Self.activeAccountKey)
        searchText = ""
        closeNewChatComposer()
        pruneMessageCache(keeping: groupIdHex)
        // Lookup caches are scoped to the active account's view (directory display names and
        // group membership visibility can differ per account); drop them on switch so the new
        // account does not inherit stale cross-account entries (whitenoise-mac#8/#9).
        peerProfileFFICache.removeAll()
        clearGroupMemberCache()
        refreshObservabilityRuntime()
    }

    private func activateReadyState() async throws {
        phase = .ready
        try await configureObservabilityRuntime()
        await refreshNotificationAuthorizationStatus()
        await loadNotificationSettings()
        await loadPrivacySecuritySettings()
        await reloadChats()
        startNotificationListener()
    }

    func selectChat(_ chat: ChatItem) {
        cancelVoiceRecording()
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
            try await refreshAccounts(preferred: summary)
            try await bringRuntimeOnline(client)
            try await refreshAccounts(preferred: summary)
            authenticationMode = .landing
            try await activateReadyState()
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
            try await refreshAccounts(preferred: summary)
            try await bringRuntimeOnline(client)
            try await refreshAccounts(preferred: summary)
            authenticationMode = .landing
            try await activateReadyState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeActiveAccount() async {
        guard let activeAccount else { return }
        await removeAccount(activeAccount)
    }

    /// Removes a single identity (any account, not just the active one) from this Mac.
    /// Deletes the account's private key and local Marmot/MLS state via the runtime, then
    /// updates `accounts`/`chatsByAccount`. When the removed account is the active one, the
    /// in-memory message/profile caches are cleared and a remaining account is reselected
    /// (or the app returns to onboarding when none remain).
    func removeAccount(_ account: AccountItem) async {
        guard let client, !isRemovingAccount else { return }

        lastError = nil
        isRemovingAccount = true
        defer { isRemovingAccount = false }

        let removedAccountId = account.id
        let wasActive = activeAccountId == removedAccountId
        do {
            if wasActive {
                stopTimelineListener()
                stopChatListListener()
            }
            try await client.removeAccount(accountRef: account.accountRef)
            clearComposerDrafts(forAccountId: removedAccountId)
            accounts = try await accountItemsFromRuntime(client: client)
            chatsByAccount[removedAccountId] = nil

            // `activeAccountId` may have changed during the await above — e.g. the user
            // selected an account from settings while this removal was in flight. Decide
            // recovery from the post-await state, not the pre-await `wasActive` snapshot,
            // so we never leave `activeAccountId`/UserDefaults pointing at a removed
            // account. `needsActiveReset` is true if the removed account was driving the
            // UI, or if the (possibly newly-selected) active account no longer exists.
            let activeAccountInvalid =
                activeAccountId == nil
                || !accounts.contains(where: { $0.id == activeAccountId })
            let needsActiveReset = wasActive || activeAccountInvalid

            if needsActiveReset {
                stopTimelineListener()
                stopChatListListener()
                messagesByChat.removeAll()
                messageLookupByChat.removeAll()
                messageIDsByChat.removeAll()
                mediaDownloads.removeAll()
                peerProfileFFICache.removeAll()
                clearGroupMemberCache()
                timelinePagingByChat.removeAll()
                profileDraft = ProfileDraft()
                keyPackages = []
                auditLogFiles = []
                auditLogUploadStatus = nil
            }

            if accounts.isEmpty {
                activeAccountId = nil
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
                selection = nil
                phase = .onboarding
                notificationSettings = .defaults
                privacySecuritySettings = .defaults
                return
            }

            // Reselecting and reloading is only required when the account currently
            // driving the UI was removed (directly, or via a racing selection of the
            // soon-to-be-removed account). Removing a background identity that leaves a
            // still-valid active account untouched needs no reselection.
            if needsActiveReset {
                restoreOrSelectFirstAccount()
                selection = .settings(.accounts)
                try await configureObservabilityRuntime()
                await loadSettingsData()
                await reloadChats()
            }
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
            observabilityRuntimeConfiguration = nil
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

    /// Loads the aggregate settings snapshot (profile, relays, notifications, privacy/security)
    /// for the active account.
    ///
    /// Settings loading is driven from more than one entry point — the settings view's
    /// `.task(id: workspace.activeAccountId)` and explicit reloads after account mutations (e.g.
    /// `removeAccount`, which changes `activeAccountId` *and* calls this directly). Without
    /// coalescing those paths can issue two overlapping loads for the same account, doubling the
    /// profile/relay/notification/privacy work and racing each other to write UI state. This
    /// method therefore enforces a single owner per account:
    ///
    /// - A concurrent call for the account already loading awaits the in-flight task (coalesces)
    ///   instead of starting a duplicate.
    /// - A call for a *different* account cancels the now-stale load — and the stale task, on
    ///   resuming, sees `activeAccountId` no longer matches and abandons its writes — so a slower
    ///   older load can never clobber the fresher account's UI state.
    func loadSettingsData() async {
        guard let activeAccount else {
            // No active account: cancel any in-flight load and reset to defaults synchronously.
            // The cancelled task may be suspended mid-flight; its `defer` will see a newer
            // generation (bumped below) and decline to touch `isLoadingSettings`, so this path
            // owns clearing the spinner — otherwise it would stay stuck `true` forever (issue #4).
            settingsLoadTask?.cancel()
            settingsLoadTask = nil
            settingsLoadAccountId = nil
            settingsLoadGeneration &+= 1
            isLoadingSettings = false
            profileDraft = ProfileDraft()
            relaySettings = .defaults
            relayDraft = relaySettings.relays(for: selectedRelaySection)
            keyPackages = []
            notificationSettings = .defaults
            privacySecuritySettings = .defaults
            return
        }

        let accountId = activeAccount.id

        // Coalesce: a request for the account already loading joins the in-flight task.
        if let existing = settingsLoadTask, settingsLoadAccountId == accountId {
            await existing.value
            return
        }

        // A request for a different account supersedes the stale in-flight load.
        settingsLoadTask?.cancel()

        settingsLoadGeneration &+= 1
        let generation = settingsLoadGeneration
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSettingsLoad(accountId: accountId, generation: generation)
        }
        settingsLoadTask = task
        settingsLoadAccountId = accountId

        await task.value

        // Only clear ownership if no newer load has since taken over this slot.
        if settingsLoadTask == task {
            settingsLoadTask = nil
            settingsLoadAccountId = nil
        }
    }

    /// Performs the actual settings fetches for `accountId`. Guarded so that if the active account
    /// changes (or the task is canceled) mid-flight, no stale results are written to the UI.
    ///
    /// `generation` is the monotonic token assigned when this load was started. The `defer` clears
    /// `isLoadingSettings` only while this is still the current generation. If a newer load has
    /// since superseded this one, that newer load owns the spinner and we must not dismiss it; if
    /// instead the load was cancelled with no replacement (active account cleared), the
    /// no-active-account branch in `loadSettingsData()` has already cleared the spinner. Keying on
    /// the generation rather than `activeAccountId` also handles a rapid A→B→A switch, where the
    /// account id alone would spuriously match.
    private func performSettingsLoad(accountId: String, generation: UInt64) async {
        guard let client, let activeAccount, activeAccount.id == accountId else { return }

        isLoadingSettings = true
        defer {
            // Only the still-current owner clears the loading flag, so a superseded stale load
            // cannot prematurely dismiss the spinner for the newer account's load.
            if settingsLoadGeneration == generation {
                isLoadingSettings = false
            }
        }

        let accountIdHex = activeAccount.accountIdHex
        let accountRef = activeAccount.accountRef
        let fallbackName = activeAccount.displayName
        let pictureURL = activeAccount.pictureURL

        do {
            let profile = try await runOffMain {
                try client.userProfile(accountIdHex: accountIdHex)
            }
            profileDraft = ProfileDraft(profile: profile, fallbackName: fallbackName)
            let displayName = profileDraft.primaryDisplayName(fallback: fallbackName)
            updateActiveAccountProfile(displayName: displayName, pictureURL: profileDraft.picture)
        } catch {
            lastError = error.localizedDescription
            profileDraft = ProfileDraft(fallbackName: fallbackName)
            let displayName =
                (try? await runOffMain {
                    client.displayName(accountIdHex: accountIdHex)
                }) ?? nil
            if let displayName = displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !displayName.isEmpty
            {
                updateActiveAccountProfile(displayName: displayName, pictureURL: pictureURL)
            }
        }

        do {
            let lists = try await runOffMain {
                try client.accountRelayLists(accountRef: accountRef)
            }
            relaySettings = RelaySettingsSnapshot(lists: lists)
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        } catch {
            lastError = error.localizedDescription
            relaySettings = .defaults
            relayDraft = relaySettings.relays(for: selectedRelaySection)
        }

        await refreshNotificationAuthorizationStatus()
        // The active account may have changed during the await above; abandon stale writes.
        guard !Task.isCancelled, activeAccountId == accountId else { return }
        await loadNotificationSettings()
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

        let accountRef = activeAccount.accountRef

        do {
            let settings = try await runOffMain {
                try client.setLocalNotificationsEnabled(
                    accountRef: accountRef,
                    enabled: enabled
                )
            }
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
            let member = try await runOffMain {
                try client.normalizeMemberRef(memberRef: query)
            }
            try? await client.refreshProfile(accountIdHex: member.accountIdHex, relays: MarmotClient.seedRelays)
            peerProfileFFICache[member.accountIdHex] = nil
            let resolved = try? await runOffMain { () -> ResolvedPeerFFI in
                let profile = try? client.userProfile(accountIdHex: member.accountIdHex)
                return ResolvedPeerFFI(
                    profileDisplayName: profile?.displayName,
                    profileName: profile?.name,
                    profilePicture: profile?.picture,
                    directoryDisplayName: client.displayName(accountIdHex: member.accountIdHex)
                )
            }
            let displayName = firstNonBlank([
                resolved?.profileDisplayName,
                resolved?.profileName,
                resolved?.directoryDisplayName,
            ])
            let recipient = NewChatRecipient(
                sourceQuery: query,
                memberRef: member.memberRef,
                accountIdHex: member.accountIdHex,
                npub: member.npub,
                displayName: displayName,
                pictureURL: resolved?.profilePicture
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
                // `initializeChatReadState` may race a live chat-list delta. Do not let an
                // older read-state row roll back a newer preview/timestamp already applied
                // by the subscription listener while the FFI call was in flight.
                await applyChatRow(
                    row,
                    account: activeAccount,
                    skippingStaleRow: true,
                    shouldEnrich: false
                )
            }

            let subscription = try await client.subscribeTimelineMessages(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                limit: Self.timelinePageLimit
            )
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }

            let page =
                subscription.snapshot()
                ?? TimelinePageFfi(
                    messages: [],
                    hasMoreBefore: false,
                    hasMoreAfter: false
                )
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: activeAccount, client: client)
            // Start the listener first (it tears down any prior listener, which would clear
            // these), then record the subscription so scroll-back pagination can reach it.
            // `startTimelineListener` can bail without starting a task (e.g. selection changed
            // while we awaited above); only record the subscription when it actually started,
            // otherwise we leak a live handle with no `next()` loop draining it.
            startTimelineListener(groupIdHex: groupIdHex, account: activeAccount, subscription: subscription)
            guard timelineTaskGroupId == groupIdHex else { return }
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
            body: message.replyPreviewText
        )
    }

    func cancelReply() {
        replyDraftContext = nil
    }

    func copyText(of message: MessageItem) {
        guard message.canCopyText else { return }
        copyText(message.body)
    }

    func mediaDownloadState(for message: MessageItem, attachment: MessageMediaAttachment) -> MediaDownloadState {
        mediaDownloadStateStore(for: message, attachment: attachment).state
    }

    func mediaDownloadStateStore(
        for message: MessageItem,
        attachment: MessageMediaAttachment
    ) -> MediaDownloadStateStore {
        mediaDownloadStateStore(forKey: mediaDownloadKey(message: message, attachment: attachment))
    }

    func loadMediaAttachment(_ attachment: MessageMediaAttachment, for message: MessageItem) async {
        let key = mediaDownloadKey(message: message, attachment: attachment)
        let stateStore = mediaDownloadStateStore(forKey: key)
        if case .loaded = stateStore.state {
            return
        }
        if case .loading = stateStore.state {
            return
        }

        guard let client, let activeAccount, !message.groupIdHex.isEmpty else {
            stateStore.update(.failed(L10n.string("Attachment unavailable")))
            return
        }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        let groupIdHex = message.groupIdHex
        stateStore.update(.loading)

        do {
            let reference = try await resolvedMediaReference(
                attachment.reference,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            let download = try await client.downloadMedia(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reference: reference
            )
            guard activeAccountId == accountId else { return }
            stateStore.update(
                .loaded(
                    MessageMediaDownload(
                        data: download.plaintext,
                        fileName: download.fileName,
                        mediaType: download.mediaType,
                        sizeBytes: download.sizeBytes
                    )
                )
            )
        } catch {
            guard activeAccountId == accountId else { return }
            stateStore.update(.failed(error.localizedDescription))
        }
    }

    /// Lazily allocates per-attachment stores from SwiftUI body lookup without observing the
    /// backing dictionary; `mediaDownloads` is `@ObservationIgnored`, and pruning bounds it to
    /// the active conversation.
    private func mediaDownloadStateStore(forKey key: String) -> MediaDownloadStateStore {
        if let store = mediaDownloads[key] {
            return store
        }
        let store = MediaDownloadStateStore()
        mediaDownloads[key] = store
        return store
    }

    /// Copies `text` to the system pasteboard.
    ///
    /// Every value copied from this app is private-messenger content — decrypted message
    /// bodies, full conversation transcripts, and Nostr identity keys — so copies default to
    /// `concealed`. A concealed copy additionally carries the `org.nspasteboard.ConcealedType`
    /// marker (see `copyToGeneralPasteboard`), which clipboard-history managers honor to avoid
    /// persisting the value and which discourages Universal Clipboard (Handoff) from syncing it
    /// to the user's other devices.
    func copyText(_ text: String, concealed: Bool = true) {
        copyTextHandler(text, concealed)
    }

    /// The bech32 `npub` form of a hex public key — the canonical, user-facing way to show
    /// a Nostr public key. Falls back to the hex until the account cache has been hydrated
    /// off the main thread.
    func npub(forAccountIdHex accountIdHex: String) -> String {
        let trimmed = accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return accounts.first(where: { $0.accountIdHex == trimmed })?.npub ?? trimmed
    }

    func react(to message: MessageItem, emoji: String) async {
        guard message.supportsChatActions else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        // Reentrancy guard: drop a duplicate of the *same* in-flight reaction
        // (same target + emoji) while allowing a different emoji on the same message.
        let reactionKey = "\(selectedChat.id)\u{1F}\(message.id)\u{1F}\(emoji)"
        guard !inFlightReactionKeys.contains(reactionKey) else { return }
        inFlightReactionKeys.insert(reactionKey)
        defer { inFlightReactionKeys.remove(reactionKey) }
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
        // Reentrancy guard: the removal deletes the reaction event, so key on its id
        // (shared namespace with `deleteMessage`) to drop a repeated in-flight removal.
        guard !inFlightDeleteMessageIds.contains(reactionMessageId) else { return }
        inFlightDeleteMessageIds.insert(reactionMessageId)
        defer { inFlightDeleteMessageIds.remove(reactionMessageId) }
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
        // Reentrancy guard: drop a repeated delete of the same in-flight message.
        guard !inFlightDeleteMessageIds.contains(message.id) else { return }
        inFlightDeleteMessageIds.insert(message.id)
        defer { inFlightDeleteMessageIds.remove(message.id) }
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
        // Invalidate any in-flight load so a stale completion cannot repopulate closed details or
        // resurrect the spinner; this also clears `isLoadingGroupDetails`. See issue #135.
        invalidateGroupDetailsLoad()
        isSavingGroupProfile = false
        isInvitingGroupMember = false
        isAcceptingGroupInvite = false
        isDecliningGroupInvite = false
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
            let normalized = try await runOffMain {
                try client.normalizeMemberRef(memberRef: query)
            }
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

    func acceptGroupInvite(for chat: ChatItem) async {
        guard !chat.isDirect else { return }
        await acceptGroupInvite(groupIdHex: chat.id)
    }

    func declineGroupInvite(for chat: ChatItem) async {
        guard !chat.isDirect else { return }
        await declineGroupInvite(groupIdHex: chat.id)
    }

    func acceptSelectedGroupInvite() async {
        guard let snapshot = groupDetailsSnapshot else { return }
        await acceptGroupInvite(groupIdHex: snapshot.groupIdHex)
    }

    func declineSelectedGroupInvite() async {
        guard let snapshot = groupDetailsSnapshot else { return }
        await declineGroupInvite(groupIdHex: snapshot.groupIdHex)
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
        invalidateGroupImageSearch()
        groupImageSearchQuery = ""
        groupImageResults = []
        isGroupImagePickerPresented = true
    }

    func closeGroupImagePicker() {
        isGroupImagePickerPresented = false
        invalidateGroupImageSearch()
        groupImageResults = []
        isSavingGroupImage = false
    }

    private func dismissGroupImagePickerIfSelectedChatUnavailable() {
        guard isGroupImagePickerPresented, selectedChat == nil else { return }
        closeGroupImagePicker()
    }

    func searchGroupImages() async {
        let query = groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            invalidateGroupImageSearch()
            groupImageResults = []
            return
        }

        lastError = nil
        let searchGeneration = beginGroupImageSearch()
        isSearchingGroupImages = true
        defer {
            // Spinner ownership is keyed on the generation ALONE, independent of the stricter
            // picker/query guard used for committing results. Only a newer search or an
            // `invalidateGroupImageSearch` (both bump the generation, and each sets the spinner
            // state itself) supersedes this one's ownership of `isSearchingGroupImages`. Editing
            // the query mid-flight without resubmitting must NOT strand the spinner at `true`
            // (which would disable the Search button forever), so it is deliberately not part of
            // this check — see issue #110 adversarial review.
            if ownsGroupImageSearch(generation: searchGeneration) {
                isSearchingGroupImages = false
            }
        }

        do {
            let results = try await groupImageSearchClient.searchImages(query: query)
            // Drop results if a newer search superseded this one, the query was edited, or the
            // picker was dismissed/reopened while the request was in flight.
            guard isCurrentGroupImageSearch(generation: searchGeneration, query: query) else { return }
            groupImageResults = results
        } catch {
            guard isCurrentGroupImageSearch(generation: searchGeneration, query: query) else { return }
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

    private func acceptGroupInvite(groupIdHex: String) async {
        guard let client, let activeAccount, !isAcceptingGroupInvite, !isDecliningGroupInvite else { return }
        lastError = nil
        isAcceptingGroupInvite = true
        defer { isAcceptingGroupInvite = false }

        do {
            _ = try await client.acceptGroupInvite(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            await reloadChats()
            if isGroupDetailsPresented, groupDetailsSnapshot?.groupIdHex == groupIdHex {
                await loadGroupDetails(groupIdHex: groupIdHex)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func declineGroupInvite(groupIdHex: String) async {
        guard let client, let activeAccount, !isDecliningGroupInvite, !isAcceptingGroupInvite else { return }
        lastError = nil
        isDecliningGroupInvite = true
        defer { isDecliningGroupInvite = false }

        do {
            _ = try await client.declineGroupInvite(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            if groupDetailsSnapshot?.groupIdHex == groupIdHex {
                closeGroupDetails()
            }
            if case .chat(let selectedGroupId) = selection, selectedGroupId == groupIdHex {
                stopTimelineListener()
                selection = nil
                pruneMessageCache(keeping: nil)
            }
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadGroupDetails(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        guard selectedChat?.id == groupIdHex else { return }

        // Last-request-wins guard (issue #135): this method is reachable concurrently for the same
        // group, and the FFI pair below is completion-ordered, not request-ordered. Capture the
        // generation on entry; only the still-current load may apply its snapshot, clear the shared
        // spinner, or report errors. A superseded load (a newer load started, or `closeGroupDetails`
        // ran) leaves the spinner to its owner so it cannot drop it early or repopulate closed UI.
        let generation = beginGroupDetailsLoad()
        isLoadingGroupDetails = true
        defer {
            if ownsGroupDetailsLoad(generation: generation) {
                isLoadingGroupDetails = false
            }
        }

        do {
            let details = try await client.groupDetails(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            let managementState = try await client.groupManagementState(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            guard ownsGroupDetailsLoad(generation: generation) else { return }
            guard selectedChat?.id == groupIdHex else { return }
            applyGroupDetails(details, managementState: managementState)
        } catch {
            guard ownsGroupDetailsLoad(generation: generation) else { return }
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
        storeGroupMembers(details.members, for: details.group.groupIdHex)
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

    func addMediaAttachments(from urls: [URL]) async {
        guard let draftKey = selectedComposerDraftKey else { return }
        guard canBeginMediaAttachmentSelection() else { return }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        let selected = Array(fileURLs.prefix(remainingMediaAttachmentSlots))
        if selected.count < fileURLs.count {
            presentMaxMediaAttachmentWarning()
        }

        for url in selected {
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)
                appendPendingMediaAttachment(attachment, for: draftKey)
            } catch is CancellationError {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removePendingMediaAttachment(_ id: PendingMediaAttachment.ID) {
        guard let selectedComposerDraftKey else { return }
        var attachments = pendingMediaAttachmentsByConversation[selectedComposerDraftKey] ?? []
        attachments.removeAll { $0.id == id }
        pendingMediaAttachmentsByConversation[selectedComposerDraftKey] = attachments.isEmpty ? nil : attachments
    }

    func toggleVoiceRecording() async {
        if isRecordingVoiceMessage {
            await finishVoiceRecording()
        } else {
            await startVoiceRecording()
        }
    }

    func startVoiceRecording() async {
        guard !isRecordingVoiceMessage else { return }
        guard canBeginMediaAttachmentSelection() else { return }

        let hasPermission = await requestMicrophoneAccess()
        guard hasPermission else {
            lastError = L10n.string("Microphone access is needed to record voice messages.")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteNoiseVoiceRecordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "voice-\(Int(Date().timeIntervalSince1970)).m4a"
            let url = directory.appendingPathComponent(fileName)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw VoiceRecordingFailure.startFailed
            }

            voiceRecorder = recorder
            voiceRecordingURL = url
            voiceRecordingSamples = []
            voiceRecordingDurationSeconds = 0
            isRecordingVoiceMessage = true
            startVoiceRecordingMetering()
        } catch {
            resetVoiceRecording(deleteFile: true)
            lastError = L10n.string("Voice recording could not start.")
        }
    }

    func finishVoiceRecording() async {
        guard isRecordingVoiceMessage, let recorder = voiceRecorder, let url = voiceRecordingURL else {
            resetVoiceRecording(deleteFile: true)
            return
        }
        let draftKey = selectedComposerDraftKey
        let duration = max(voiceRecordingDurationSeconds, recorder.currentTime)
        let samples = voiceRecordingSamples
        let fileName = url.lastPathComponent
        recorder.stop()
        resetVoiceRecording(deleteFile: false)

        guard let draftKey else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        do {
            let attachment = try await OutgoingMediaDraftProcessor.preparedVoiceAttachment(
                from: VoiceRecordingResult(
                    url: url,
                    fileName: fileName,
                    durationSeconds: duration,
                    waveformSamples: samples
                )
            )
            appendPendingMediaAttachment(attachment, for: draftKey)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelVoiceRecording() {
        resetVoiceRecording(deleteFile: true)
    }

    private var remainingMediaAttachmentSlots: Int {
        max(0, OutgoingMediaDraftProcessor.maxAttachmentCount - pendingMediaAttachments.count)
    }

    private func canBeginMediaAttachmentSelection() -> Bool {
        guard client != nil, selectedChat != nil else { return false }
        guard remainingMediaAttachmentSlots > 0 else {
            presentMaxMediaAttachmentWarning()
            return false
        }
        return true
    }

    private func appendPendingMediaAttachment(_ attachment: PendingMediaAttachment, for draftKey: ComposerDraftKey) {
        var attachments = pendingMediaAttachmentsByConversation[draftKey] ?? []
        if attachment.kind == .audio {
            attachments.removeAll { $0.kind == .audio }
        }
        guard attachments.count < OutgoingMediaDraftProcessor.maxAttachmentCount else {
            presentMaxMediaAttachmentWarning()
            return
        }
        attachments.append(attachment)
        pendingMediaAttachmentsByConversation[draftKey] = attachments
        if attachment.kind == .audio {
            draftTextByConversation[draftKey] = nil
        }
    }

    private func presentMaxMediaAttachmentWarning() {
        lastError = String(
            format: L10n.string("You can send up to %lld attachments at once"),
            Int64(OutgoingMediaDraftProcessor.maxAttachmentCount)
        )
    }

    private enum VoiceRecordingFailure: Error {
        case startFailed
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startVoiceRecordingMetering() {
        voiceRecordingMeterTask?.cancel()
        voiceRecordingMeterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 70_000_000)
                } catch {
                    return
                }
                guard let self, let recorder = self.voiceRecorder else { return }
                recorder.updateMeters()
                self.voiceRecordingDurationSeconds = recorder.currentTime
                let power = recorder.averagePower(forChannel: 0)
                let normalized = max(0.05, min(1, CGFloat(pow(10, power / 36))))
                self.voiceRecordingSamples.append(normalized)
                if self.voiceRecordingSamples.count > MediaWaveformAnalyzer.sampleCount {
                    self.voiceRecordingSamples.removeFirst(
                        self.voiceRecordingSamples.count - MediaWaveformAnalyzer.sampleCount)
                }
            }
        }
    }

    private func resetVoiceRecording(deleteFile: Bool) {
        voiceRecordingMeterTask?.cancel()
        voiceRecordingMeterTask = nil
        voiceRecorder?.stop()
        voiceRecorder = nil
        let url = voiceRecordingURL
        voiceRecordingURL = nil
        isRecordingVoiceMessage = false
        voiceRecordingSamples = []
        voiceRecordingDurationSeconds = 0
        if deleteFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func sendDraft() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaAttachments = pendingMediaAttachments
        // `!isSending` is the reentrancy guard: `isSending` flips synchronously here,
        // but the model only suspends (and `draftText` is only cleared) at the `await`
        // below. Without this guard a second invocation delivered before SwiftUI
        // re-renders the disabled send button (⌘-Return auto-repeat, double events)
        // would still observe the old `draftText` and re-send the same message.
        guard let client,
            let activeAccount,
            let selectedChat,
            let draftKey = selectedComposerDraftKey,
            !text.isEmpty || !mediaAttachments.isEmpty,
            !isSending
        else { return }
        isSending = true
        defer { isSending = false }

        do {
            if !mediaAttachments.isEmpty {
                _ = try await client.uploadMedia(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: selectedChat.id,
                    request: MediaUploadRequestFfi(
                        attachments: mediaAttachments.map(\.uploadRequest),
                        caption: text.isEmpty ? nil : text,
                        send: true,
                        blossomServer: nil
                    )
                )
            } else if let replyDraftContext {
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
            pendingMediaAttachmentsByConversation[draftKey] = nil
            await refreshSelectedTimelineAfterSend(groupIdHex: selectedChat.id, account: activeAccount, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleNotificationUpdate(_ update: NotificationUpdateFfi) async {
        guard !update.isFromSelf else { return }
        guard !deliveredNotificationKeys.contains(update.notificationKey) else { return }

        // Read the account's notification settings exactly once over the FFI
        // boundary, then reuse the snapshot for both responsibilities below:
        //   1. Keep the published `notificationSettings` snapshot in sync when
        //      the update targets the active account.
        //   2. Gate notification delivery on `localNotificationsEnabled`.
        // A failed read (`nil`) suppresses delivery and leaves the published
        // snapshot untouched, matching the prior early-return-on-error behavior.
        guard let settings = await fetchNotificationSettings(for: update) else { return }

        if activeAccount?.accountIdHex == update.accountIdHex {
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        }

        guard settings.localNotificationsEnabled else { return }

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

        let switchedAccounts: Bool
        if let account = notificationAccount(from: userInfo), activeAccountId != account.id {
            prepareForActiveAccountSwitch(to: account, preservingMessageCacheFor: groupIdHex)
            switchedAccounts = true
        } else {
            switchedAccounts = false
        }

        selection = .chat(groupIdHex)
        isChatListVisible = true
        if !switchedAccounts {
            closeNewChatComposer()
            pruneMessageCache(keeping: groupIdHex)
        }
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

    private func refreshAccounts(preferred summary: AccountSummaryFfi) async throws {
        guard let client else { return }
        let preferredItems = try await accountItems(from: [summary], client: client)
        let preferredAccount = preferredItems.first ?? Self.accountItem(from: summary, resolved: nil)
        var refreshed = try await accountItemsFromRuntime(client: client)
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

    /// Brings the Marmot runtime online so newly added accounts start their
    /// workers and subscribe to transport events. `start()` is idempotent —
    /// it reconciles all known accounts (spawning a worker for any that lacks
    /// a live one) and rebuilds the user-directory subscriptions, and only
    /// fails when the runtime is shutting down. It must therefore be re-invoked
    /// after every `login()` / `signUp()`, not just once per launch: the
    /// Settings → Add Account flow adds a 2nd+ account while the runtime is
    /// already running, and that account stays offline (no live relay sync /
    /// notifications) until relaunch unless the runtime is brought online
    /// again. See issues #31 and #74.
    private func bringRuntimeOnline(_ runtime: any MarmotRuntime) async throws {
        try await runtime.start()
    }

    private func resetToNewInstallState(storageRootPath: String) {
        accounts = []
        chatsByAccount = [:]
        messagesByChat = [:]
        resetMediaDownloadStateStores()
        messageLookupByChat = [:]
        messageIDsByChat = [:]
        peerProfileFFICache.removeAll()
        clearGroupMemberCache()
        observabilityRuntimeConfiguration = nil
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
        invalidateGroupImageSearch()
        isSavingGroupImage = false
        isGroupDetailsPresented = false
        groupDetailsSnapshot = nil
        groupProfileDraftName = ""
        groupProfileDraftDescription = ""
        groupInviteMemberQuery = ""
        // Invalidate any in-flight load so a stale completion cannot write into the reset state;
        // this also clears `isLoadingGroupDetails`. See issue #135.
        invalidateGroupDetailsLoad()
        isSavingGroupProfile = false
        isInvitingGroupMember = false
        isAcceptingGroupInvite = false
        isDecliningGroupInvite = false
        isArchivingGroup = false
        isLeavingGroup = false
        isExportingGroupTranscript = false
        groupTranscriptExportStatus = nil
        mutatingGroupMemberId = nil
        self.storageRootPath = storageRootPath
        timelinePagingByChat = [:]
        timelineInitialLoadGroupId = nil
        lastMarkedReadMarkers = [:]
        lastConfirmedReadMarkers = [:]
        deliveredNotificationKeys = []
        deliveredNotificationKeyOrder = []
        UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
        phase = .onboarding
    }

    /// The community-convention pasteboard type (https://nspasteboard.org) that privacy-aware
    /// clipboard managers check for to treat an item as transient: they skip persisting it to
    /// clipboard history, and it also discourages Universal Clipboard / Handoff from broadcasting
    /// the item to the user's other Apple devices.
    static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func copyToGeneralPasteboard(_ text: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            // Non-destructive: apps that don't recognise the concealed type still read `.string`.
            pasteboard.setString(text, forType: Self.concealedPasteboardType)
        }
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

    func reportUserActionError(_ message: String) {
        lastError = message
    }

    private func waitBeforeListenerReconnect(attempt: Int) async throws {
        let delay = Self.listenerReconnectDelayNanoseconds(forAttempt: attempt)
        guard delay > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(nanoseconds: delay)
    }

    private func configureObservabilityRuntime() async throws {
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
        let auditTrackerConfig = config.auditTrackerConfig(accountLabel: accountLabel)

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

    private func loadNotificationSettings() async {
        guard let client, let activeAccount else {
            notificationSettings = .defaults
            return
        }

        do {
            let accountRef = activeAccount.accountRef
            let settings = try await runOffMain {
                try client.notificationSettings(accountRef: accountRef)
            }
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
            let (telemetry, auditLog) = try await runOffMain {
                (
                    try client.relayTelemetrySettings(),
                    try client.auditLogSettings()
                )
            }
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
            let current = try await runOffMain {
                try client.relayTelemetrySettings()
            }
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
            auditLogFiles = try await runOffMain {
                try client.auditLogFiles()
            }
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
        var reconnectAttempt = 0

        while !Task.isCancelled {
            do {
                let subscription = try await client.subscribeNotifications()
                while !Task.isCancelled {
                    guard let update = await subscription.next() else { break }
                    reconnectAttempt = 0
                    await handleNotificationUpdate(update)
                }
            } catch is CancellationError {
                return
            } catch {
                setBackgroundStatus(error.localizedDescription)
            }

            guard !Task.isCancelled else { break }
            do {
                try await waitBeforeListenerReconnect(attempt: reconnectAttempt)
            } catch is CancellationError {
                return
            } catch {
                setBackgroundStatus(error.localizedDescription)
            }
            reconnectAttempt += 1
        }

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
        var reconnectAttempt = 0
        var pendingSubscription = existingSubscription

        while !Task.isCancelled, activeAccountId == account.id {
            do {
                let subscription: ChatListSubscription
                if let existing = pendingSubscription {
                    subscription = existing
                    pendingSubscription = nil
                } else {
                    subscription = try await client.subscribeChatList(
                        accountRef: account.accountRef,
                        includeArchived: false
                    )
                    guard activeAccountId == account.id, !Task.isCancelled else { break }
                    await applyChatRows(subscription.snapshot(), account: account)
                }

                while !Task.isCancelled, activeAccountId == account.id {
                    guard let update = await subscription.nextUpdate() else { break }
                    guard !Task.isCancelled, activeAccountId == account.id else { break }
                    reconnectAttempt = 0
                    await applyChatListSubscriptionUpdate(update, account: account)
                }
            } catch is CancellationError {
                return
            } catch {
                if activeAccountId == account.id {
                    setBackgroundStatus(error.localizedDescription)
                }
            }

            guard !Task.isCancelled, activeAccountId == account.id else { break }
            do {
                try await waitBeforeListenerReconnect(attempt: reconnectAttempt)
            } catch is CancellationError {
                return
            } catch {
                if activeAccountId == account.id {
                    setBackgroundStatus(error.localizedDescription)
                }
            }
            reconnectAttempt += 1
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
        var reconnectAttempt = 0
        var pendingSubscription = existingSubscription

        while !Task.isCancelled,
            activeAccountId == account.id,
            selectedChat?.id == groupIdHex
        {
            do {
                let subscription: TimelineMessagesSubscription
                if let existing = pendingSubscription {
                    subscription = existing
                    pendingSubscription = nil
                } else {
                    subscription = try await client.subscribeTimelineMessages(
                        accountRef: account.accountRef,
                        groupIdHex: groupIdHex,
                        limit: Self.timelinePageLimit
                    )
                    guard activeAccountId == account.id,
                        selectedChat?.id == groupIdHex,
                        !Task.isCancelled
                    else { break }
                    activeTimelineSubscription = subscription
                    activeTimelineGroupId = groupIdHex
                    if let page = subscription.snapshot() {
                        await applyTimelineWindow(
                            page,
                            groupIdHex: groupIdHex,
                            account: account,
                            client: client
                        )
                    }
                }
                // `next()` blocks for the next live change and returns the resulting
                // authoritative window (ordering, dedup, head-anchoring while scrolled back,
                // and the cap are all owned by the runtime), so we render it directly.
                while !Task.isCancelled,
                    activeAccountId == account.id,
                    selectedChat?.id == groupIdHex
                {
                    guard let page = await subscription.next() else { break }
                    guard !Task.isCancelled,
                        activeAccountId == account.id,
                        selectedChat?.id == groupIdHex
                    else { break }
                    reconnectAttempt = 0
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

            guard !Task.isCancelled,
                activeAccountId == account.id,
                selectedChat?.id == groupIdHex
            else { break }
            do {
                try await waitBeforeListenerReconnect(attempt: reconnectAttempt)
            } catch is CancellationError {
                return
            } catch {
                if activeAccountId == account.id, selectedChat?.id == groupIdHex {
                    setBackgroundStatus(error.localizedDescription)
                }
            }
            reconnectAttempt += 1
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
        let removedChatIds = previousChatIds.subtracting(nextChatIds)
        for groupId in removedChatIds {
            invalidateGroupMembers(for: groupId)
        }
        clearComposerDrafts(for: Array(removedChatIds), accountId: account.id)
        chatsByAccount[account.id] = sortedChatItems(chatItems)
        dismissGroupImagePickerIfSelectedChatUnavailable()
        startChatListEnrichment(rows: rows, account: account)
    }

    private func invalidateGroupMemberDetailsCacheIfNeeded(
        trigger: ChatListUpdateTriggerFfi,
        groupIdHex: String
    ) {
        switch trigger {
        case .newGroup, .membershipChanged, .snapshotRefresh, .removed:
            invalidateGroupMembers(for: groupIdHex)
        case .newLastMessage,
            .lastMessageDeleted,
            .archiveChanged,
            .pendingConfirmationChanged,
            .unreadChanged:
            break
        }
    }

    private func applyChatListSubscriptionUpdate(
        _ update: ChatListSubscriptionUpdateFfi,
        account: AccountItem
    ) async {
        switch update {
        case .row(let trigger, let row):
            invalidateGroupMemberDetailsCacheIfNeeded(trigger: trigger, groupIdHex: row.groupIdHex)
            await applyChatRow(row, account: account)
        case .removeRow(trigger: _, let groupIdHex):
            invalidateGroupMembers(for: groupIdHex)
            removeChat(groupIdHex: groupIdHex, account: account)
        }
    }

    private func applyChatRow(
        _ row: ChatListRowFfi,
        account: AccountItem,
        skippingStaleRow: Bool = false,
        shouldEnrich: Bool = true
    ) async {
        guard activeAccountId == account.id else { return }

        let chats = chatsByAccount[account.id] ?? []
        if row.archived {
            removeChat(groupIdHex: row.groupIdHex, account: account)
            return
        }

        var chat = baseChatItem(from: row, account: account)
        let current = chats.first(where: { $0.id == chat.id })
        if skippingStaleRow,
            let current,
            isOlderChatRow(chat, than: current)
        {
            return
        }
        if !shouldEnrich, let current {
            // Read-state-only rows do not change the metadata resolved by enrichment
            // (direct-chat title/avatar/isDirect). Preserve it while applying the row's
            // unread/preview/timestamp fields, otherwise skipping enrichment would cause
            // direct chats to flicker back to their raw group-id fallback.
            chat = ChatListOrdering.preservingResolvedMetadata(in: chat, from: current)
        }
        let needsInitialMetadata = !shouldEnrich && readStateRowNeedsMetadataEnrichment(row, current: current)

        chatsByAccount[account.id] = ChatListOrdering.upserting(chat, into: chats)
        if shouldEnrich {
            startChatListEnrichment(rows: [row], account: account, replacingCurrent: false)
        } else if needsInitialMetadata {
            // A read-state row normally does not need enrichment, but the first selected-chat
            // read-state row can arrive after reload wiring cancels the snapshot enrichment.
            // Resolve at most one missing membership cache per invalidation; repeated failures
            // must not put groupDetails/userProfile work back on every read-marker advance.
            readStateMetadataEnrichmentAttempts.insert(row.groupIdHex)
            await enrichChatRows([row], account: account)
        }
    }

    private func isOlderChatRow(_ candidate: ChatItem, than current: ChatItem) -> Bool {
        ChatListOrdering.isOlder(candidate, than: current)
    }

    private func readStateRowNeedsMetadataEnrichment(_ row: ChatListRowFfi, current: ChatItem?) -> Bool {
        if readStateMetadataEnrichmentAttempts.contains(row.groupIdHex) { return false }
        if groupMemberDetailsCache[row.groupIdHex] == nil { return true }
        guard let current else { return true }
        guard !current.isDirect else { return false }
        let rawTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupNameIsBlank = row.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Blank-name group rows use the raw row title until one enrichment pass can confirm
        // whether this is a direct chat. Retry once after invalidation, then leave later
        // read-state-only rows on the hot path without another synchronous metadata lookup.
        return groupNameIsBlank && current.title == rawTitle
    }

    private func removeChat(groupIdHex: String, account: AccountItem) {
        guard activeAccountId == account.id else { return }

        var chats = chatsByAccount[account.id] ?? []
        chats.removeAll { $0.id == groupIdHex }
        chatsByAccount[account.id] = chats
        messagesByChat[groupIdHex] = nil
        messageLookupByChat[groupIdHex] = nil
        messageIDsByChat[groupIdHex] = nil
        invalidateGroupMembers(for: groupIdHex)
        timelinePagingByChat[groupIdHex] = nil
        clearComposerDrafts(for: [groupIdHex], accountId: account.id)
        if timelineInitialLoadGroupId == groupIdHex {
            timelineInitialLoadGroupId = nil
        }
        lastMarkedReadMarkers[groupIdHex] = nil
        lastConfirmedReadMarkers[groupIdHex] = nil

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

    private func refreshSelectedTimelineAfterSend(
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        let pageLimit = Self.timelinePageLimit
        do {
            let page = try await runOffMain {
                try client.timelineMessages(
                    accountRef: account.accountRef,
                    query: TimelineMessageQueryFfi(
                        groupIdHex: groupIdHex,
                        search: nil,
                        before: nil,
                        beforeMessageId: nil,
                        after: nil,
                        afterMessageId: nil,
                        limit: pageLimit
                    )
                )
            }
            guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: account, client: client)
        } catch {
            setBackgroundStatus(error.localizedDescription)
        }
    }

    private func pruneMessageCache(keeping groupIdHex: String?) {
        defer {
            pruneMediaDownloadCache(keeping: groupIdHex)
        }

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

    private func mediaDownloadKey(message: MessageItem, attachment: MessageMediaAttachment) -> String {
        [activeAccountId ?? "", message.groupIdHex, attachment.id].joined(separator: "\u{1F}")
    }

    private func pruneMediaDownloadCache(keeping groupIdHex: String?) {
        guard let activeAccountId, let groupIdHex else {
            resetMediaDownloadStateStores()
            return
        }

        let prefix = [activeAccountId, groupIdHex, ""].joined(separator: "\u{1F}")
        let removedKeys = mediaDownloads.keys.filter { !$0.hasPrefix(prefix) }
        for key in removedKeys {
            // Notify any lingering per-attachment observers before dropping the store.
            mediaDownloads[key]?.update(.idle)
            mediaDownloads[key] = nil
        }
    }

    private func resetMediaDownloadStateStores() {
        for store in mediaDownloads.values {
            // Notify any lingering per-attachment observers before clearing the cache.
            store.update(.idle)
        }
        mediaDownloads.removeAll()
    }

    private func resolvedMediaReference(
        _ reference: MediaAttachmentReferenceFfi,
        accountRef: String,
        groupIdHex: String,
        client: any MarmotRuntime
    ) async throws -> MediaAttachmentReferenceFfi {
        guard reference.sourceEpoch == 0 else {
            return reference
        }

        let records = try await runOffMain {
            try client.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: nil)
        }
        return records.first { record in
            record.reference.plaintextSha256 == reference.plaintextSha256
                || record.reference.ciphertextSha256 == reference.ciphertextSha256
        }?.reference ?? reference
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
        let incremental = enrichedItems.count == 1
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
                isDirect: enrichedItem.isDirect,
                pendingConfirmation: current.pendingConfirmation
            )
            guard next != current else { continue }
            if incremental {
                chats = ChatListOrdering.upserting(next, into: chats)
            } else {
                chats[index] = next
            }
            didUpdate = true
        }

        if didUpdate {
            chatsByAccount[account.id] = incremental ? chats : sortedChatItems(chats)
        }
    }

    private func enrichedChatItem(
        from row: ChatListRowFfi,
        account: AccountItem,
        client: any MarmotRuntime
    ) async -> ChatItem {
        var directPeer: ChatPeerProfile?
        let groupAvatarURL = firstNonBlank([row.avatarUrl])
        if let members = await cachedGroupMembers(
            groupIdHex: row.groupIdHex,
            account: account,
            client: client
        ) {
            // Bail before the second FFI hop (userProfile lookup) if this enrichment has been
            // cancelled — e.g. the listener was torn down or a newer row update for this group
            // superseded us. Avoids running the rest of the wasted FFI work to completion (#40).
            guard !Task.isCancelled else {
                return ChatItem(row: row, activeAccountIdHex: account.accountIdHex)
            }
            directPeer = await directPeerProfile(
                from: members,
                activeAccount: account,
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
        ChatListOrdering.sorted(chatItems)
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
        guard
            let latest = (messagesByChat[groupIdHex] ?? []).last(where: { message in
                message.timelineKind == 9 && !message.isDeleted
            })
        else {
            return
        }
        let marker = ReadMarker(sentAt: latest.sentAt, messageId: latest.id)
        let currentMarker = lastMarkedReadMarkers[groupIdHex]
        guard currentMarker != marker else { return }
        guard currentMarker.map({ $0 < marker }) ?? true else { return }
        lastMarkedReadMarkers[groupIdHex] = marker

        do {
            let accountRef = account.accountRef
            let messageId = latest.id
            let row = try await runOffMain({
                try client.markTimelineMessageRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    messageIdHex: messageId
                )
            })
            guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
            let committedState = ReadMarker.afterSuccessfulCommit(
                current: lastMarkedReadMarkers[groupIdHex],
                confirmed: lastConfirmedReadMarkers[groupIdHex],
                attempted: marker
            )
            lastMarkedReadMarkers[groupIdHex] = committedState.current
            lastConfirmedReadMarkers[groupIdHex] = committedState.confirmed
            if let row {
                await applyChatRow(row, account: account, shouldEnrich: false)
            }
        } catch {
            guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
            lastMarkedReadMarkers[groupIdHex] = ReadMarker.afterFailedOptimisticAdvance(
                current: lastMarkedReadMarkers[groupIdHex],
                attempted: marker,
                confirmed: lastConfirmedReadMarkers[groupIdHex]
            )
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

    /// Reads the notification settings for the account targeted by `update` over
    /// the off-main FFI boundary. Returns `nil` when there is no client or the
    /// read fails, so callers can suppress delivery without mutating UI state.
    ///
    /// This is intentionally side-effect free: refreshing the published
    /// `notificationSettings` snapshot for the active account is the caller's
    /// responsibility (see `handleNotificationUpdate(_:)`), which lets a single
    /// fetch serve both the active-account sync and the delivery gate.
    private func fetchNotificationSettings(for update: NotificationUpdateFfi) async -> NotificationSettingsFfi? {
        guard let client else { return nil }
        let accountRef = update.accountRef
        return try? await runOffMain({
            try client.notificationSettings(accountRef: accountRef)
        })
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
            nsError.code == UNError.Code.notificationsNotAllowed.rawValue
        {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("notification")
            && message.contains("not allowed")
    }

    private func localNotificationRequest(for update: NotificationUpdateFfi) -> LocalNotificationRequest {
        let senderName =
            firstNonBlank([
                update.sender.displayName,
                update.sender.accountIdHex,
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
            "notificationKey": update.notificationKey,
        ]
        if let messageIdHex = update.messageIdHex {
            userInfo["messageIdHex"] = messageIdHex
        }
        return userInfo
    }

    private func notificationAccount(from userInfo: [String: String]) -> AccountItem? {
        if let accountIdHex = userInfo["accountIdHex"],
            let account = accounts.first(where: { $0.accountIdHex == accountIdHex })
        {
            return account
        }

        guard let accountRef = userInfo["accountRef"] else { return nil }
        return accounts.first { account in
            account.accountRef == accountRef || account.id == accountRef
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

    private func beginGroupDetailsLoad() -> Int {
        groupDetailsLoadGeneration += 1
        return groupDetailsLoadGeneration
    }

    /// Invalidate any in-flight group-details load so a stale completion cannot apply its snapshot,
    /// clear the spinner, or report an error against closed/superseded UI state. Also clears the
    /// (now-orphaned) spinner: the in-flight load, once superseded, declines to touch it.
    private func invalidateGroupDetailsLoad() {
        groupDetailsLoadGeneration += 1
        isLoadingGroupDetails = false
    }

    /// True while `generation` still owns the group-details load — i.e. no newer `loadGroupDetails`
    /// or `invalidateGroupDetailsLoad` (via `closeGroupDetails`) has bumped the generation.
    private func ownsGroupDetailsLoad(generation: Int) -> Bool {
        groupDetailsLoadGeneration == generation
    }

    private func beginGroupImageSearch() -> Int {
        groupImageSearchGeneration += 1
        return groupImageSearchGeneration
    }

    private func invalidateGroupImageSearch() {
        groupImageSearchGeneration += 1
        isSearchingGroupImages = false
    }

    /// True while `generation` still owns the group-image search spinner — i.e. no newer
    /// `beginGroupImageSearch` or `invalidateGroupImageSearch` has bumped the generation. This is
    /// intentionally looser than `isCurrentGroupImageSearch`: it does NOT require the picker to be
    /// presented or the live query to match, because spinner ownership must transfer cleanly even
    /// when the user edits the query mid-flight without resubmitting (otherwise the spinner would
    /// stay stuck `true` and disable the Search button — issue #110 review).
    private func ownsGroupImageSearch(generation: Int) -> Bool {
        groupImageSearchGeneration == generation
    }

    /// True only if `generation` is still the latest group-image search, the picker is still
    /// presented, and the live (trimmed) query still equals the one this search was issued for.
    /// Any of: a newer search, a dismissed/reopened picker, or an edited query invalidates the
    /// in-flight result so it cannot overwrite current UI state.
    private func isCurrentGroupImageSearch(generation: Int, query: String) -> Bool {
        ownsGroupImageSearch(generation: generation)
            && isGroupImagePickerPresented
            && groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    private func insertCreatedChatIfNeeded(groupIdHex: String, title: String, avatarSeed: String, pictureURL: String?) {
        guard let activeAccountId else { return }
        let chats = chatsByAccount[activeAccountId] ?? []
        guard !chats.contains(where: { $0.id == groupIdHex }) else { return }

        let chat = ChatItem(
            id: groupIdHex,
            title: title,
            subtitle: L10n.string("Direct message"),
            preview: L10n.string("No messages yet"),
            updatedAt: nil,
            avatarSeed: avatarSeed,
            pictureURL: pictureURL,
            unreadCount: 0,
            isDirect: true
        )
        chatsByAccount[activeAccountId] = ChatListOrdering.upserting(chat, into: chats)
    }

    private func storeGroupMembers(_ members: [GroupMemberDetailsFfi], for groupIdHex: String) {
        groupMemberDetailsLookups[groupIdHex]?.task.cancel()
        groupMemberDetailsLookups[groupIdHex] = nil
        groupMemberDetailsCache[groupIdHex] = members
    }

    private func invalidateGroupMembers(for groupIdHex: String) {
        groupMemberDetailsCache[groupIdHex] = nil
        groupMemberDetailsLookups[groupIdHex]?.task.cancel()
        groupMemberDetailsLookups[groupIdHex] = nil
        readStateMetadataEnrichmentAttempts.remove(groupIdHex)
    }

    private func clearGroupMemberCache() {
        groupMemberDetailsCache.removeAll()
        for lookup in groupMemberDetailsLookups.values {
            lookup.task.cancel()
        }
        groupMemberDetailsLookups.removeAll()
        readStateMetadataEnrichmentAttempts.removeAll()
    }

    private func cachedGroupMembers(
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async -> [GroupMemberDetailsFfi]? {
        if let cached = groupMemberDetailsCache[groupIdHex] {
            return cached
        }
        if let lookup = groupMemberDetailsLookups[groupIdHex] {
            return await lookup.task.value
        }

        nextGroupMemberDetailsLookupToken += 1
        let token = nextGroupMemberDetailsLookupToken
        let accountRef = account.accountRef
        let task = Task { () -> [GroupMemberDetailsFfi]? in
            guard
                let details = try? await client.groupDetails(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
            else {
                return nil
            }
            return details.members
        }
        groupMemberDetailsLookups[groupIdHex] = GroupMemberDetailsLookup(token: token, task: task)

        let members = await task.value
        if groupMemberDetailsLookups[groupIdHex]?.token == token {
            groupMemberDetailsLookups[groupIdHex] = nil
            if activeAccountId == account.id, let members {
                groupMemberDetailsCache[groupIdHex] = members
            }
        }
        return members
    }

    private func directPeerProfile(
        from members: [GroupMemberDetailsFfi],
        activeAccount: AccountItem,
        client: any MarmotRuntime
    ) async -> ChatPeerProfile? {
        let otherMembers = members.filter { member in
            !member.isSelf && member.memberIdHex != activeAccount.accountIdHex
        }
        guard otherMembers.count == 1,
            let otherMember = otherMembers.first
        else { return nil }

        let memberId = otherMember.memberIdHex
        let resolved = await resolvedPeerFFI(
            accountIdHex: memberId,
            activeAccount: activeAccount,
            client: client
        )
        let displayName = firstNonBlank([
            resolved?.profileDisplayName,
            resolved?.profileName,
            otherMember.displayName,
            resolved?.directoryDisplayName,
        ])

        return ChatPeerProfile(
            accountIdHex: memberId,
            displayName: displayName,
            pictureURL: resolved?.profilePicture?.nilIfBlank
        )
    }

    private func resolvedPeerFFI(
        accountIdHex: String,
        activeAccount: AccountItem,
        client: any MarmotRuntime
    ) async -> ResolvedPeerFFI? {
        let now = nowProvider()
        if let cached = peerProfileFFICache[accountIdHex],
            cached.isFresh(now: now, ttl: Self.peerProfileCacheTTL)
        {
            return cached.resolved
        }

        let resolved = try? await runOffMain { () -> ResolvedPeerFFI in
            let profile = try? client.userProfile(accountIdHex: accountIdHex)
            return ResolvedPeerFFI(
                profileDisplayName: profile?.displayName,
                profileName: profile?.name,
                profilePicture: profile?.picture,
                directoryDisplayName: client.displayName(accountIdHex: accountIdHex)
            )
        }
        if activeAccountId == activeAccount.id, let resolved {
            peerProfileFFICache[accountIdHex] = CachedPeerProfile(resolved: resolved, resolvedAt: now)
        }
        return resolved
    }

    private func messageSenderProfiles(
        from records: [TimelineMessageRecordFfi],
        groupIdHex: String,
        activeAccount: AccountItem,
        client: any MarmotRuntime
    ) async -> [String: ChatPeerProfile] {
        let senderIds = Set(
            records.flatMap { record in
                [record.sender, record.replyPreview?.sender]
            }
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        )
        guard !senderIds.isEmpty else { return [:] }

        let nonLocalSenderIds = senderIds.filter { $0 != activeAccount.accountIdHex }
        let groupMemberNames: [String: String]
        if nonLocalSenderIds.isEmpty {
            groupMemberNames = [:]
        } else {
            let members =
                await cachedGroupMembers(
                    groupIdHex: groupIdHex,
                    account: activeAccount,
                    client: client
                ) ?? []
            groupMemberNames = members.reduce(into: [String: String]()) { result, member in
                if let displayName = firstNonBlank([member.displayName]) {
                    result[member.memberIdHex] = displayName
                }
            }
        }

        // Resolve any senders whose cached lookup is missing, incomplete, or stale in a
        // single off-main FFI batch, then cache the raw lookups (timestamped) so repeated
        // scroll-up pages skip Rust entirely. Incomplete lookups (relay not yet
        // propagated, or a failed lookup) are always re-resolved so a contact is never
        // pinned to a fallback name/avatar for the life of the process; complete lookups
        // are re-resolved once the TTL elapses so later name/avatar changes are picked up
        // within a session (whitenoise-mac#8).
        let now = nowProvider()
        let unresolvedIds = senderIds.filter { senderId in
            guard senderId != activeAccount.accountIdHex else { return false }
            guard let cached = peerProfileFFICache[senderId] else { return true }
            return !cached.isFresh(now: now, ttl: Self.peerProfileCacheTTL)
        }
        if !unresolvedIds.isEmpty {
            let resolved =
                (try? await runOffMain { () -> [String: ResolvedPeerFFI] in
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
            // The off-main resolution above suspends this actor. If the user switched
            // accounts while the batch was in flight, `selectAccount`/
            // `selectAccountFromSettings` already cleared `peerProfileFFICache` for the
            // newly selected account. Writing these now-stale, account-scoped lookups
            // would repopulate the cache with the *previous* account's directory/profile
            // entries and leak them into the new account until TTL expiry, undercutting
            // the account-scoped invalidation this code path relies on. Only commit the
            // results if we are still resolving for the same active account; otherwise
            // drop them — the caller re-checks `activeAccountId` after this await and
            // discards the stale window anyway (whitenoise-mac#8).
            if activeAccountId == activeAccount.id {
                for (senderId, value) in resolved {
                    peerProfileFFICache[senderId] = CachedPeerProfile(resolved: value, resolvedAt: now)
                }
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

            let resolved = peerProfileFFICache[senderId]?.resolved
            profiles[senderId] = ChatPeerProfile(
                accountIdHex: senderId,
                displayName: firstNonBlank([
                    resolved?.profileDisplayName,
                    resolved?.profileName,
                    groupMemberNames[senderId],
                    resolved?.directoryDisplayName,
                ]),
                pictureURL: resolved?.profilePicture?.nilIfBlank
            )
        }

        return profiles
    }

    private func accountItemsFromRuntime(client: any MarmotRuntime) async throws -> [AccountItem] {
        let summaries = try await runOffMain {
            try client.listAccounts()
        }
        return try await accountItems(from: summaries, client: client)
    }

    private func accountItems(
        from summaries: [AccountSummaryFfi],
        client: any MarmotRuntime
    ) async throws -> [AccountItem] {
        try await runOffMain {
            summaries.map { summary in
                let resolved = Self.resolvedAccountFFI(from: summary, client: client)
                return Self.accountItem(from: summary, resolved: resolved)
            }
        }
    }

    nonisolated private static func resolvedAccountFFI(
        from summary: AccountSummaryFfi,
        client: any MarmotRuntime
    ) -> ResolvedAccountFFI {
        let profile = try? client.userProfile(accountIdHex: summary.accountIdHex)
        return ResolvedAccountFFI(
            profileDisplayName: profile?.displayName,
            profileName: profile?.name,
            profilePicture: profile?.picture,
            directoryDisplayName: client.displayName(accountIdHex: summary.accountIdHex),
            npub: client.npub(accountIdHex: summary.accountIdHex)
        )
    }

    nonisolated private static func accountItem(
        from summary: AccountSummaryFfi,
        resolved: ResolvedAccountFFI?
    ) -> AccountItem {
        let base = AccountItem(summary: summary)
        let displayName =
            firstNonBlank([
                resolved?.profileDisplayName,
                resolved?.profileName,
                resolved?.directoryDisplayName,
            ]) ?? base.displayName

        return AccountItem(
            id: base.id,
            accountRef: base.accountRef,
            displayName: displayName,
            accountIdHex: base.accountIdHex,
            npub: resolved?.npub,
            pictureURL: resolved?.profilePicture,
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
        return
            relays
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

struct ReadMarker: Equatable, Comparable {
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
            URLQueryItem(name: "page_size", value: "24"),
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
        firstNonBlank([displayName, name, fallback]) ?? fallback
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
            publishedAt: package.publishedAt == 0
                ? nil : Date(timeIntervalSince1970: TimeInterval(package.publishedAt)),
            keyPackageBytes: package.keyPackageBytes,
            sourceRelays: package.sourceRelays,
            isLocal: package.local,
            isRelayDiscovered: package.relay
        )
    }
}
