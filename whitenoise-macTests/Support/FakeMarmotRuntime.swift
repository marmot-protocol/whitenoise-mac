//
//  FakeMarmotRuntime.swift
//  whitenoise-macTests
//
//  Shared test double for `MarmotRuntime` plus the value types it records into.
//  Extracted verbatim from `whitenoise_macTests.swift` so test files other than
//  that one can drive a fake core. `internal`, not `private`: a file-scoped
//  `private` here would be invisible to every other test file.
//

import Foundation
import MarmotKit

@testable import whitenoise_mac

nonisolated final class FakeMarmotRuntime: MarmotRuntime, @unchecked Sendable {
    private var storedAccounts: [AccountSummaryFfi]
    /// The account that `login` / `createIdentity` will materialise. `var` so a
    /// test can point the next add at a different account (multi-account flows).
    var createdAccount: AccountSummaryFfi?
    private(set) var startCallCount = 0
    var didStart: Bool { startCallCount > 0 }
    /// When set, `start()` throws it instead of bringing accounts online, modelling
    /// the runtime failing to come online (e.g. shutting down). Used to exercise the
    /// add-account failure path that must not commit the active-account switch (#333).
    var startError: Error?
    /// Where the app writes the files it keeps beside the core — the hidden-message,
    /// pinned-chat, contact-nickname and direct-peer stores `WorkspaceState` builds for
    /// itself whenever a test does not inject one. Defaulted per test by
    /// `TestStorageRoot.isolated`; see that type for why it is not one shared constant.
    let storageRootPath: String
    private var profile = UserProfileMetadataFfi(
        name: "desktop",
        displayName: "Desktop Account",
        about: nil,
        picture: "https://example.com/avatar.png",
        nip05: nil,
        lud16: nil
    )
    /// Overrides the account's published NIP-65 write relays, so a test can prove a peer
    /// profile refresh searches them alongside the seed relays.
    func installAccountNip65Relays(_ relays: [String]) {
        relayLists = AccountRelayListsFfi(
            complete: relayLists.complete,
            missing: relayLists.missing,
            defaultRelays: relayLists.defaultRelays,
            bootstrapRelays: relayLists.bootstrapRelays,
            nip65: RelayListFfi(kind: 10002, relays: relays),
            inbox: relayLists.inbox
        )
    }

    private var relayLists = AccountRelayListsFfi(
        complete: true,
        missing: [],
        defaultRelays: MarmotClient.seedRelays,
        bootstrapRelays: MarmotClient.seedRelays,
        nip65: RelayListFfi(kind: 10002, relays: MarmotClient.seedRelays),
        inbox: RelayListFfi(kind: 10050, relays: MarmotClient.seedRelays)
    )
    private var keyPackages = [
        AccountKeyPackageFfi(
            accountRef: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "slot-local",
            keyPackageRefHex: "ref-local",
            eventIdHex: "event-local",
            publishedAt: 1_700_000_000,
            keyPackageBytes: 512,
            sourceRelays: MarmotClient.seedRelays,
            local: true,
            relay: false
        ),
        AccountKeyPackageFfi(
            accountRef: nil,
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "slot-fetched",
            keyPackageRefHex: "ref-fetched",
            eventIdHex: "event-fetched",
            publishedAt: 1_700_000_100,
            keyPackageBytes: 520,
            sourceRelays: [],
            local: false,
            relay: true
        ),
    ]
    /// Kind-3 follow lists keyed by `accountRef`, lowercased hex.
    private var followsByAccountRef: [String: Set<String>] = [:]
    private(set) var followMutationCalls: [FollowMutationCall] = []
    /// Injected failure for `followUser` / `unfollowUser` — notably
    /// `MarmotKitError.FollowListUnavailable`, which is a refusal to publish, not a partial write.
    var followMutationError: Error?
    /// Injected failure for the network-free cached reads.
    var followReadError: Error?
    /// Forces the list a mutation returns, so a test can drive the case where the core
    /// published something other than what was requested.
    var followMutationResultOverride: [String]?
    private(set) var isFollowingCallCount = 0
    private let followMutationGate = AsyncFfiGate()
    private let followReadGate = BlockingFfiGate()
    private let followListReadGate = BlockingFfiGate()
    private var groups: [AppGroupRecordFfi] = []
    /// Groups whose SelfRemove has published but not yet been committed by a remaining member —
    /// the durable, possibly permanent `leaveRequestPending` the chat list has to render.
    private var pendingLeaveGroupIds: Set<String> = []
    private var messagesByGroupId: [String: [AppMessageRecordFfi]] = [:]
    private var timelinePagesByGroupId: [String: TimelinePageFfi] = [:]
    private var timelineUpdatesByGroupId: [String: [TimelineSubscriptionUpdateFfi]] = [:]
    private var mediaRecordsByGroupId: [String: [MediaRecordFfi]] = [:]
    private var mediaDownloadsByPlaintextSha256: [String: MediaDownloadResultFfi] = [:]
    private var chatListUpdates: [ChatListSubscriptionUpdateFfi] = []
    private(set) var createdGroupMemberRefs: [String] = []
    /// Every `createGroup` call in order, refused ones included — `createdGroupMemberRefs` records
    /// only the roster that went through, so it cannot show how a refusal was chased down.
    private(set) var createGroupAttempts: [[String]] = []
    /// Run at the top of every member-resolving call, before it refuses or commits. A test can read
    /// the workspace from here to see what the UI would have been rendering *while* a press is still
    /// working through the roster.
    var onMemberResolutionAttempt: (@Sendable () async -> Void)?
    private(set) var createdGroupName: String?
    private(set) var createdGroupDescription: String?
    /// Member refs the core would refuse for want of a published KeyPackage. `createGroup` mirrors
    /// the real member-resolution order: it stops at the *first* one it finds in `memberRefs` and
    /// throws `MissingKeyPackage` naming that account, so a roster with several surfaces them one
    /// attempt at a time. Keyed by member ref, valued by the account id hex the core reports.
    var missingKeyPackageAccountIdHexByMemberRef: [String: String] = [:]
    /// Member refs the core would refuse over a KeyPackage that exists but cannot be used. Unlike
    /// `missingKeyPackageAccountIdHexByMemberRef`, `InvalidKeyPackageEvent` names no account, so a
    /// roster containing one of these is refused without saying who is at fault. Resolution order
    /// is shared with the missing-KeyPackage set: whichever comes first in `memberRefs` wins.
    var invalidKeyPackageMemberRefs: Set<String> = []
    /// Member refs whose resolution fails in a way that has nothing to do with KeyPackages — a
    /// person with no relay list to fetch one from, say. Shares the same resolution order: an error
    /// like this still stops the whole create at the member it belongs to.
    var unresolvableMemberRefs: Set<String> = []
    /// Thrown by `createGroup` regardless of the roster, for failures that name nobody.
    var createGroupFailure: Error?
    /// Holds `createGroupFailure` back until this many attempts have been made, posing as a failure
    /// that is about the account rather than any member and only starts once resolution gets past
    /// the roster.
    var createGroupFailureAfterAttempts = 0
    /// Forgets every missing KeyPackage once this many `createGroup` attempts have been made, posing
    /// as a member who publishes one *between* two attempts of the same press.
    var forgetsMissingKeyPackagesAfterAttempts: Int?
    private(set) var repliedMessage: SentReply?
    private(set) var reactedMessage: SentReaction?
    private(set) var deletedMessage: DeletedMessage?
    private(set) var editedMessage: EditedMessage?
    private(set) var sentText: SentText?
    /// Recorded on the far side of the FFI gate, unlike `sentText`, so the order here is the order
    /// the texts actually published in rather than the order the calls were made.
    private(set) var publishedTexts: [SentText] = []
    private(set) var retriedGroupIdHex: String?
    // Stage-time uploads run one detached task per attachment, and `uploadMedia` is `nonisolated
    // async`, so those tasks execute it concurrently on the cooperative pool rather than on the
    // caller's actor. Everything it records therefore lives behind `recordedStateLock`, read back
    // through the same lock so a test's assertions cannot race an upload still in flight.
    var uploadedMedia: UploadedMedia? {
        recordedStateLock.withLock { _uploadedMedia }
    }
    private var _uploadedMedia: UploadedMedia?
    /// Every stage-time upload, in call order — attachments now upload one call each, so the last
    /// call alone no longer describes what the composer did.
    var uploadedMediaRequests: [UploadedMedia] {
        recordedStateLock.withLock { _uploadedMediaRequests }
    }
    private var _uploadedMediaRequests: [UploadedMedia] = []
    var sentMediaAttachments: [SentMediaAttachments] {
        recordedStateLock.withLock { _sentMediaAttachments }
    }
    private var _sentMediaAttachments: [SentMediaAttachments] = []
    var sendMediaAttachmentsCallCount: Int {
        recordedStateLock.withLock { _sendMediaAttachmentsCallCount }
    }
    private var _sendMediaAttachmentsCallCount = 0
    var sendMediaAttachmentsError: Error?
    /// File names whose *next* upload attempt throws, so a test can drive the failed → retry path.
    var uploadMediaFailingFileNames: Set<String> {
        get { recordedStateLock.withLock { _uploadMediaFailingFileNames } }
        set { recordedStateLock.withLock { _uploadMediaFailingFileNames = newValue } }
    }
    private var _uploadMediaFailingFileNames: Set<String> = []
    /// File names whose upload returns success but no attachment, so a test can drive the
    /// reference-less result the composer has to treat as a failure rather than as still in flight.
    var uploadMediaEmptyResultFileNames: Set<String> {
        get { recordedStateLock.withLock { _uploadMediaEmptyResultFileNames } }
        set { recordedStateLock.withLock { _uploadMediaEmptyResultFileNames = newValue } }
    }
    private var _uploadMediaEmptyResultFileNames: Set<String> = []
    let uploadReleaseGate = UploadReleaseGate()
    private var _uploadedAttachmentSequence = 0
    private var storedMessageDraftsByAccountRef: [String: [String: MessageDraftFfi]] = [:]
    private var messageDraftTimestamp: Int64 = 1_700_000_000_000
    private let messageDraftReadGate = BlockingFfiGate()
    var messageDraftReadGateEnabled: Bool {
        get { messageDraftReadGate.isEnabled }
        set { messageDraftReadGate.isEnabled = newValue }
    }
    var didReachMessageDraftReadGate: Bool {
        messageDraftReadGate.didReach
    }
    // Issue #78 reentrancy-test support: count message-action FFI calls so a test can prove
    // an overlapping duplicate was dropped by the WorkspaceState guard before reaching the runtime.
    private(set) var sendTextCallCount = 0
    var sendTextError: Error?
    private(set) var retryGroupConvergenceCallCount = 0
    var retryGroupConvergenceError: Error?
    private(set) var replyToMessageCallCount = 0
    var replyToMessageError: Error?
    private(set) var reactToMessageCallCount = 0
    private(set) var deleteMessageCallCount = 0
    private(set) var editMessageCallCount = 0
    var uploadMediaCallCount: Int {
        recordedStateLock.withLock { _uploadMediaCallCount }
    }
    private var _uploadMediaCallCount = 0
    var listMediaCallCount: Int {
        recordedStateLock.withLock { _listMediaCallCount }
    }
    private var _listMediaCallCount = 0
    var downloadMediaCallCount: Int {
        recordedStateLock.withLock { _downloadMediaCallCount }
    }
    private var _downloadMediaCallCount = 0
    var downloadedMediaReferences: [MediaAttachmentReferenceFfi] {
        recordedStateLock.withLock { _downloadedMediaReferences }
    }
    private var _downloadedMediaReferences: [MediaAttachmentReferenceFfi] = []
    private(set) var updatedGroupAvatar: UpdatedGroupAvatar?
    private(set) var updateGroupAvatarUrlCallCount = 0
    private(set) var updatedEncryptedGroupImage: Data?
    private(set) var updatedEncryptedGroupImageMediaType: String?
    private(set) var updateGroupImageCallCount = 0
    private(set) var clearGroupImageCallCount = 0
    private(set) var downloadGroupImageCallCount = 0
    var downloadedGroupImage = Data([0x89, 0x50, 0x4E, 0x47])
    private(set) var updatedGroupProfile: UpdatedGroupProfile?
    private(set) var updateGroupProfileCallCount = 0
    private(set) var archivedGroup: ArchivedGroup?
    private(set) var setGroupArchivedCallCount = 0
    var setGroupArchivedError: Error?
    private(set) var leftGroupIdHex: String?
    private(set) var leaveGroupCallCount = 0
    var leaveGroupError: Error?
    /// Ordered log of the group mutations a leave can issue, so tests can assert that a
    /// self-demote precedes the leave it unblocks rather than merely accompanying it.
    private(set) var groupMutationOrder: [String] = []
    var promoteAdminError: Error?
    /// Suppresses the management-state recomputation a promotion normally triggers, so a test can
    /// pose as a core that still reports this account as the blocked sole admin after the promote
    /// committed.
    var keepsManagementStateAfterPromote = false
    private(set) var acceptedInviteGroupIds: [String] = []
    private(set) var acceptGroupInviteCallCount = 0
    private(set) var declinedInviteGroupIds: [String] = []
    private(set) var declineGroupInviteCallCount = 0
    private(set) var invitedMemberRefs: [String] = []
    /// Every invite call in order, refused ones included — `invitedMemberRefs` records only the
    /// roster that committed, so it cannot show how a refusal was chased down.
    private(set) var inviteMemberRefAttempts: [[String]] = []
    private(set) var inviteMembersDetailedCallCount = 0
    private(set) var promotedAdminRef: String?
    private(set) var promoteAdminDetailedCallCount = 0
    private(set) var demotedAdminRef: String?
    private(set) var demoteAdminDetailedCallCount = 0
    private(set) var selfDemotedGroupIdHex: String?
    private(set) var selfDemoteAdminDetailedCallCount = 0
    private(set) var removedMemberRefs: [String] = []
    private(set) var removeMembersDetailedCallCount = 0
    private(set) var lastPackageFetchBootstrapRelays: [String] = []
    private(set) var didPublishNewKeyPackage = false
    private(set) var didRepublishKeyPackage = false
    private(set) var deletedPackageEventId: String?
    private(set) var lastPackageDeleteRelays: [String] = []
    private(set) var lastPublishedProfileDefaultRelays: [String] = []
    private(set) var lastPublishedProfileBootstrapRelays: [String] = []
    /// How many times the profile was actually pushed at the network. A deterministic witness for
    /// "Cancel published nothing", which the relay arrays cannot be: they start empty.
    private(set) var publishUserProfileCallCount = 0
    private(set) var uploadedProfileImageData: Data?
    private(set) var uploadedProfileImageMediaType: String?
    private(set) var uploadedProfileImageBlossomServer: String?
    var uploadedProfileImageURL = "https://blossom.example/profile-image.jpg"
    private(set) var lastSetInboxBootstrapRelays: [String] = []
    private(set) var lastSetNip65BootstrapRelays: [String] = []
    var refreshedProfileIds: [String] {
        recordedStateLock.withLock { _refreshedProfileIds }
    }
    private var _refreshedProfileIds: [String] = []
    /// Relay set the most recent `refreshProfile` searched.
    var lastProfileRefreshRelays: [String] {
        recordedStateLock.withLock { _lastProfileRefreshRelays }
    }
    private var _lastProfileRefreshRelays: [String] = []
    private(set) var markedReadMessageIds: [String] = []
    private(set) var accountKeyPackagesCallCount = 0
    /// Number of times `userProfile` was queried — used to assert settings-load coalescing
    /// (issue #4 regression): overlapping `loadSettingsData()` calls for the same account must
    /// not duplicate the per-account profile fetch.
    private(set) var userProfileCallCount = 0
    private(set) var accountRelayListsCallCount = 0
    /// Per-group call count for `groupDetails`, used to assert chat-list enrichment runs
    /// through the incremental per-row path (issue #40 regression).
    var groupDetailsCallCounts: [String: Int] {
        recordedStateLock.withLock { _groupDetailsCallCounts }
    }
    private var _groupDetailsCallCounts: [String: Int] = [:]
    var groupDetailsFailureGroupIds = Set<String>()
    var chatListSubscriptionCount: Int {
        recordedStateLock.withLock { _chatListSubscriptionCount }
    }
    private var _chatListSubscriptionCount = 0
    var notificationSubscriptionCount: Int {
        recordedStateLock.withLock { _notificationSubscriptionCount }
    }
    private var _notificationSubscriptionCount = 0
    var timelineSubscriptionCount: Int {
        recordedStateLock.withLock { _timelineSubscriptionCount }
    }
    private var _timelineSubscriptionCount = 0
    var timelineSubscriptionAccountRefs: [String] {
        recordedStateLock.withLock { _timelineSubscriptionAccountRefs }
    }
    private var _timelineSubscriptionAccountRefs: [String] = []
    var lastTimelineSubscription: FakeTimelineMessagesSubscription? {
        recordedStateLock.withLock { _lastTimelineSubscription }
    }
    private var _lastTimelineSubscription: FakeTimelineMessagesSubscription?
    var chatListStreamEndsAfterUpdates = false
    /// Simulates async relay/runtime latency before a chat-list subscription is ready.
    var chatListSubscriptionDelayNanoseconds: UInt64 = 0
    /// Ordered script of web-of-trust search updates every `searchUsers` subscription replays.
    var userSearchUpdates: [UserSearchUpdateFfi] = []
    /// Per-update latency, so a test can change the query or switch accounts mid-stream.
    var userSearchUpdateDelayNanoseconds: UInt64 = 0
    /// When set, `searchUsers` throws instead of returning a subscription.
    var searchUsersError: Error?
    var userSearchCalls: [UserSearchCall] {
        recordedStateLock.withLock { _userSearchCalls }
    }
    private var _userSearchCalls: [UserSearchCall] = []
    /// Total `nextUpdate()` calls across every subscription this runtime handed out. A host that
    /// abandons a search must release the subscription rather than draining it, and this counter
    /// is the only observable consequence of getting that wrong.
    var userSearchNextUpdateCount: Int {
        recordedStateLock.withLock { _userSearchNextUpdateCount }
    }
    private var _userSearchNextUpdateCount = 0

    struct UserSearchCall: Equatable {
        let accountIdHex: String
        let query: String
        let radiusStart: UInt8
        let radiusEnd: UInt8
    }
    var notificationStreamEndsImmediately = false
    var timelineStreamEndsAfterUpdates = false
    private(set) var timelineMessageQueries: [TimelineMessageQueryFfi] = []
    var profileRefreshDelaysByAccountId: [String: UInt64] = [:]
    var accountIdsMissingProfiles = Set<String>()
    var timelineMessagesHandler: ((TimelineMessageQueryFfi) throws -> TimelinePageFfi)?
    private let syncCallThreadLock = NSLock()
    private var syncCallThreads: [String: [Bool]] = [:]
    /// Guards recorded-call state mutated by concurrent runtime calls while tests poll it mid-flight.
    private let recordedStateLock = NSLock()
    /// When set, `subscribeNotifications()` throws this error, simulating a background
    /// notification-listener failure for routing tests.
    var subscribeNotificationsError: Error?
    /// Simulates the async relay/runtime delay before the first timeline snapshot is available.
    var timelineSubscriptionDelayNanoseconds: UInt64 = 0
    var timelineUpdateDelayNanoseconds: UInt64 = 0
    /// Issue #78 reentrancy-test support: when armed, the first message-action FFI call
    /// (`sendText`/`replyToMessage`/`reactToMessage`/`deleteMessage`) suspends until
    /// `releaseMessageActionGate()` is invoked, holding the first invocation in-flight so a
    /// test can issue an overlapping second call and assert the WorkspaceState guard dropped it.
    private let messageActionGate = AsyncFfiGate()
    var messageActionGateEnabled: Bool {
        get { messageActionGate.isEnabled }
        set { messageActionGate.isEnabled = newValue }
    }
    var didReachMessageActionGate: Bool {
        messageActionGate.didReach
    }
    /// Issue #230 media-cache teardown-test support: when armed, the first `downloadMedia`
    /// call suspends after capturing the download bytes so a purge can complete before it returns.
    private let mediaDownloadGate = AsyncFfiGate()
    var mediaDownloadGateEnabled: Bool {
        get { mediaDownloadGate.isEnabled }
        set { mediaDownloadGate.isEnabled = newValue }
    }
    var didReachMediaDownloadGate: Bool {
        mediaDownloadGate.didReach
    }
    /// Issue #286 reference-resolution cache-test support: when armed, the first synchronous
    /// `listMedia` call blocks on the FFI queue so overlapping attachment loads can join it.
    private let listMediaGate = BlockingFfiGate()
    var listMediaGateEnabled: Bool {
        get { listMediaGate.isEnabled }
        set { listMediaGate.isEnabled = newValue }
    }
    var didReachListMediaGate: Bool {
        listMediaGate.didReach
    }
    private let markTimelineMessageReadGate = BlockingFfiGate()
    var markTimelineMessageReadGateEnabled: Bool {
        get { markTimelineMessageReadGate.isEnabled }
        set { markTimelineMessageReadGate.isEnabled = newValue }
    }
    var didReachMarkTimelineMessageReadGate: Bool {
        markTimelineMessageReadGate.didReach
    }
    var markTimelineMessageReadError: Error?
    /// Issue #134 reentrancy-test support: when armed, the first group-avatar update FFI call
    /// suspends until `releaseGroupAvatarUpdateGate()` is invoked, holding the first invocation
    /// in-flight so a test can issue an overlapping clear/set action and assert the guard dropped it.
    private let groupAvatarUpdateGate = AsyncFfiGate()
    var groupAvatarUpdateGateEnabled: Bool {
        get { groupAvatarUpdateGate.isEnabled }
        set { groupAvatarUpdateGate.isEnabled = newValue }
    }
    var didReachGroupAvatarUpdateGate: Bool {
        groupAvatarUpdateGate.didReach
    }
    /// Issue #553 reentrancy-test support: when armed, the first pending-invite FFI call (accept or
    /// decline) suspends until `releaseGroupInviteGate()` is invoked so a test can close group
    /// details mid-operation and assert overlapping accept/decline invocations do not reach FFI.
    private let groupInviteGate = AsyncFfiGate()
    var groupInviteGateEnabled: Bool {
        get { groupInviteGate.isEnabled }
        set { groupInviteGate.isEnabled = newValue }
    }
    var didReachGroupInviteGate: Bool {
        groupInviteGate.didReach
    }
    /// Issue #310 reentrancy-test support: when armed, the first group mutation FFI call suspends
    /// until `releaseGroupMutationGate()` is invoked, holding the first invocation in-flight so a
    /// test can issue an overlapping duplicate and assert the WorkspaceState guard dropped it.
    private let groupMutationGate = AsyncFfiGate()
    var groupMutationGateEnabled: Bool {
        get { groupMutationGate.isEnabled }
        set { groupMutationGate.isEnabled = newValue }
    }
    var didReachGroupMutationGate: Bool {
        groupMutationGate.didReach
    }
    /// Issue #135 last-request-wins-test support: when armed, the first `groupDetails` FFI call
    /// suspends until `releaseGroupDetailsGate()` is invoked, holding the older `loadGroupDetails`
    /// in-flight so a test can run a newer overlapping load to completion and then assert the stale
    /// older completion does not clobber the newer snapshot or drop the shared spinner.
    private let groupDetailsGate = AsyncFfiGate()
    var groupDetailsGateEnabled: Bool {
        get { groupDetailsGate.isEnabled }
        set { groupDetailsGate.isEnabled = newValue }
    }
    var didReachGroupDetailsGate: Bool {
        groupDetailsGate.didReach
    }
    /// Reentrancy-test support for the two-phase chat leave: when armed, the first
    /// `groupManagementState` FFI call suspends until `releaseGroupManagementStateGate()` is
    /// invoked, so a test can hold one eligibility fetch in flight and run an overlapping
    /// preparation to completion against it. Without this the installed-state path returns without
    /// ever suspending, and two `async let` preparations on the main actor run strictly one after
    /// the other — never overlapping at all.
    private let groupManagementStateGate = AsyncFfiGate()
    var groupManagementStateGateEnabled: Bool {
        get { groupManagementStateGate.isEnabled }
        set { groupManagementStateGate.isEnabled = newValue }
    }
    var didReachGroupManagementStateGate: Bool {
        groupManagementStateGate.didReach
    }
    /// Issue #207 last-request-wins-test support: when armed, the first `accountKeyPackages` FFI
    /// call suspends until `releaseAccountKeyPackagesGate()` is invoked, holding an older
    /// `loadKeyPackages()` in-flight so a test can switch the active account, run a newer load to
    /// completion, then assert the stale older completion does not overwrite (or, on error, blank)
    /// the newer account's key-package list.
    private let accountKeyPackagesGate = AsyncFfiGate()
    var accountKeyPackagesGateEnabled: Bool {
        get { accountKeyPackagesGate.isEnabled }
        set { accountKeyPackagesGate.isEnabled = newValue }
    }
    var didReachAccountKeyPackagesGate: Bool {
        accountKeyPackagesGate.didReach
    }
    /// Issue #229 stale-account-test support: when armed, the first `createGroup` FFI call suspends
    /// until `releaseCreateGroupGate()` is invoked, holding `createNewChat()` in-flight so a test can
    /// switch the active account before the create resolves and assert the freshly created group is
    /// not grafted onto / selected under the switched-to account.
    private let createGroupGate = AsyncFfiGate()
    var createGroupGateEnabled: Bool {
        get { createGroupGate.isEnabled }
        set { createGroupGate.isEnabled = newValue }
    }
    var didReachCreateGroupGate: Bool {
        createGroupGate.didReach
    }
    /// Hold `createIdentity` / `login` in flight so a test can observe which authentication
    /// path is running while it runs — the state a progress label reads.
    private let createIdentityGate = AsyncFfiGate()
    var createIdentityGateEnabled: Bool {
        get { createIdentityGate.isEnabled }
        set { createIdentityGate.isEnabled = newValue }
    }
    var didReachCreateIdentityGate: Bool {
        createIdentityGate.didReach
    }
    private let loginGate = AsyncFfiGate()
    var loginGateEnabled: Bool {
        get { loginGate.isEnabled }
        set { loginGate.isEnabled = newValue }
    }
    var didReachLoginGate: Bool {
        loginGate.didReach
    }
    /// Issue #228 last-request-wins support for synchronous notification FFI reads: when armed,
    /// the first `notificationSettings` call blocks on the FFI queue until released, holding an
    /// older account's result while the test switches accounts and loads the newer snapshot.
    private let notificationSettingsGate = BlockingFfiGate()
    var notificationSettingsGateEnabled: Bool {
        get { notificationSettingsGate.isEnabled }
        set { notificationSettingsGate.isEnabled = newValue }
    }
    var didReachNotificationSettingsGate: Bool {
        notificationSettingsGate.didReach
    }
    /// Issue #562 load-vs-save support: capture the first telemetry snapshot, then block its
    /// synchronous read so a newer save can complete before the stale load returns.
    private let relayTelemetrySettingsGate = BlockingFfiGate()
    var relayTelemetrySettingsGateEnabled: Bool {
        get { relayTelemetrySettingsGate.isEnabled }
        set { relayTelemetrySettingsGate.isEnabled = newValue }
    }
    var didReachRelayTelemetrySettingsGate: Bool {
        relayTelemetrySettingsGate.didReach
    }
    private let telemetryInstallIdGate = BlockingFfiGate()
    var telemetryInstallIdGateEnabled: Bool {
        get { telemetryInstallIdGate.isEnabled }
        set { telemetryInstallIdGate.isEnabled = newValue }
    }
    var didReachTelemetryInstallIdGate: Bool {
        telemetryInstallIdGate.didReach
    }
    var setNativePushEnabledError: Error?
    private(set) var nativePushEnabledSet: Bool?
    private(set) var setNativePushEnabledCallCount = 0
    /// Issue #228 equivalent gate for the synchronous `setLocalNotificationsEnabled` FFI write.
    private let setLocalNotificationsGate = BlockingFfiGate()
    var setLocalNotificationsGateEnabled: Bool {
        get { setLocalNotificationsGate.isEnabled }
        set { setLocalNotificationsGate.isEnabled = newValue }
    }
    var didReachSetLocalNotificationsGate: Bool {
        setLocalNotificationsGate.didReach
    }
    /// Issue #366 reentrancy-test support: when armed, the first synchronous
    /// `auditLogFiles` read blocks on the off-main FFI batch while a test issues
    /// an overlapping load that must be coalesced by WorkspaceState.
    private let auditLogFilesGate = BlockingFfiGate()
    var auditLogFilesGateEnabled: Bool {
        get { auditLogFilesGate.isEnabled }
        set { auditLogFilesGate.isEnabled = newValue }
    }
    var didReachAuditLogFilesGate: Bool {
        auditLogFilesGate.didReach
    }
    /// Issue #283 stale-account-test support: when armed, the first synchronous `userProfile` FFI
    /// read blocks on the off-main FFI batch until released, holding `performSettingsLoad`'s profile
    /// fetch in-flight so a test can switch the active account and assert account A's stale profile
    /// is not written onto account B's `profileDraft` / `accounts[]` entry.
    private let userProfileGate = BlockingFfiGate()
    var userProfileGateEnabled: Bool {
        get { userProfileGate.isEnabled }
        set { userProfileGate.isEnabled = newValue }
    }
    var didReachUserProfileGate: Bool {
        userProfileGate.didReach
    }
    /// Issue #283 equivalent gate for the synchronous `accountRelayLists` FFI read, holding
    /// `performSettingsLoad`'s relay fetch in-flight across an account switch.
    private let accountRelayListsGate = BlockingFfiGate()
    var accountRelayListsGateEnabled: Bool {
        get { accountRelayListsGate.isEnabled }
        set { accountRelayListsGate.isEnabled = newValue }
    }
    var didReachAccountRelayListsGate: Bool {
        accountRelayListsGate.didReach
    }
    /// Issue #287 stale-account-test support: when armed, the first `publishUserProfile` FFI call
    /// suspends until `releasePublishUserProfileGate()` is invoked, holding `saveProfile()` in-flight
    /// so a test can switch the active account before the publish resolves and assert the just-saved
    /// profile is not misattributed to the switched-to account.
    private let publishUserProfileGate = AsyncFfiGate()
    var publishUserProfileGateEnabled: Bool {
        get { publishUserProfileGate.isEnabled }
        set { publishUserProfileGate.isEnabled = newValue }
    }
    var didReachPublishUserProfileGate: Bool {
        publishUserProfileGate.didReach
    }
    /// Issue #287 equivalent gate for the `setAccountNip65Relays` / `setAccountInboxRelays` FFI
    /// writes: when armed, the first relay-save call suspends until `releaseSetAccountRelaysGate()`,
    /// holding `saveRelaySettings()` in-flight across an account switch.
    private let setAccountRelaysGate = AsyncFfiGate()
    var setAccountRelaysGateEnabled: Bool {
        get { setAccountRelaysGate.isEnabled }
        set { setAccountRelaysGate.isEnabled = newValue }
    }
    var didReachSetAccountRelaysGate: Bool {
        setAccountRelaysGate.didReach
    }
    /// Per-account key packages keyed by `accountRef`. Falls back to the default `keyPackages`
    /// fixture when an account has no explicit install, so existing single-account tests are
    /// unaffected.
    private var keyPackagesByAccountRef: [String: [AccountKeyPackageFfi]] = [:]
    private var profilesByAccountId: [String: UserProfileMetadataFfi] = [:]
    private var normalizedMembersByRef: [String: MemberRefFfi] = [:]
    private var groupDetailsById: [String: GroupDetailsFfi] = [:]
    private var groupManagementStateById: [String: GroupManagementStateFfi] = [:]
    var notificationSettings = NotificationSettingsFfi(
        accountRef: "Desktop Account",
        accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        localNotificationsEnabled: false,
        nativePushEnabled: false
    )
    private var notificationSettingsByAccountRef: [String: NotificationSettingsFfi] = [:]
    var storedAuditLogSettings = AuditLogSettingsFfi(enabled: false, dataMode: .obfuscatedSensitiveData)
    var storedAuditLogFiles: [AuditLogFileFfi] = []
    var auditLogDeleteFailurePaths: Set<String> = []
    var nextAuditLogTrackerUpdate = AuditLogTrackerUpdateResultFfi(
        enabled: true,
        uploaded: [],
        skippedReason: nil
    )
    var storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
        exportEnabled: false,
        exportIntervalSeconds: 60
    )
    private(set) var localNotificationsEnabledSet: Bool?
    private(set) var auditLogTrackerConfig: AuditLogTrackerConfigFfi?
    private(set) var auditLogTrackerConfigSetCallCount = 0
    private(set) var deletedAuditLogFilePaths: [String] = []
    private(set) var didPostAuditLogTrackerUpdate = false
    private(set) var relayTelemetryRuntimeConfig: RelayTelemetryRuntimeConfigFfi?
    private(set) var relayTelemetryRuntimeConfigSetCallCount = 0
    private(set) var telemetryInstallIdCallCount = 0
    var telemetryInstallIdError: Error?
    private(set) var removedAccountRefs: [String] = []
    var removeAccountError: Error?
    private(set) var didDeleteAllLocalData = false
    var deleteAllLocalDataError: Error?
    var signOutError: Error?
    /// When set, `publishUserProfile` throws instead of publishing — the failure that leaves a
    /// minted-but-unpublished identity behind for `cancelSignUp()` to carry forward into the app.
    var publishUserProfileError: Error?
    /// Optional hook fired after `deleteAllLocalData` starts but before storage is cleared,
    /// used to simulate a racing account mutation while a full wipe is in flight.
    var onDeleteAllLocalDataMidFlight: (@Sendable () async -> Void)?
    /// Optional hook fired inside `removeAccount` after the ref is recorded but before the
    /// account is actually dropped, used to simulate a racing UI action (e.g. the user
    /// selecting the account currently being removed) mid-await.
    var onRemoveAccountMidFlight: (@Sendable (String) async -> Void)?
    /// Optional hook fired inside `signOut` after the ref is recorded and the stored account is
    /// marked signed out, but before the call returns, used to simulate a racing UI action (e.g.
    /// the user selecting another account while sign-out is in flight) mid-await.
    var onSignOutAccountMidFlight: (@Sendable (String) async -> Void)?
    /// Optional hook fired inside `signInAccount` after the stored account is marked signed in,
    /// but before the call returns, used to simulate a racing UI action (e.g. the user selecting
    /// another account while sign-in is in flight) mid-await.
    var onSignInAccountMidFlight: (@Sendable (String) async -> Void)?
    /// Optional hook fired inside `userProfile`, on the off-main FFI batch thread. A test can
    /// use it to advance an injected clock and model a slow batch (whitenoise-mac#181).
    var onUserProfileLookup: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - storageRoot: Where this fake reports its storage root. Isolated per test by
    ///     default, so a test that forgets to inject a file store still cannot read
    ///     another test's records; pass `.explicit` only to share a directory on purpose.
    ///   - function: Do not pass these. They default at the call site, which is how the
    ///     isolated root falls back to naming the caller when there is no running test.
    init(
        accounts: [AccountSummaryFfi],
        createdAccount: AccountSummaryFfi? = nil,
        storageRoot: TestStorageRoot = .isolated,
        function: StaticString = #function,
        fileID: StaticString = #fileID
    ) {
        self.storedAccounts = accounts
        self.createdAccount = createdAccount
        self.storageRootPath = storageRoot.resolvedPath(function: function, fileID: fileID)
    }

    func start() async throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
        storedAccounts = storedAccounts.map { account in
            var runningAccount = account
            runningAccount.running = true
            return runningAccount
        }
    }

    func listAccounts() throws -> [AccountSummaryFfi] {
        recordSyncCall("listAccounts")
        return storedAccounts
    }

    func clearSyncCallThreadRecords() {
        syncCallThreadLock.lock()
        syncCallThreads = [:]
        syncCallThreadLock.unlock()
    }

    func syncCallThreadRecord(_ name: String) -> [Bool] {
        syncCallThreadLock.lock()
        let threads = syncCallThreads[name] ?? []
        syncCallThreadLock.unlock()
        return threads
    }

    private func recordSyncCall(_ name: String) {
        syncCallThreadLock.lock()
        syncCallThreads[name, default: []].append(Thread.isMainThread)
        syncCallThreadLock.unlock()
    }

    func npub(accountIdHex: String) -> String? {
        recordSyncCall("npub")
        return "npub1\(accountIdHex.prefix(12))"
    }

    func displayName(accountIdHex: String) -> String? {
        recordSyncCall("displayName")
        guard !accountIdsMissingProfiles.contains(accountIdHex) else { return nil }
        let resolvedProfile = profilesByAccountId[accountIdHex] ?? profile
        return resolvedProfile.displayName ?? resolvedProfile.name
    }

    func userProfile(accountIdHex: String) throws -> UserProfileMetadataFfi? {
        userProfileCallCount += 1
        recordSyncCall("userProfile")
        // Test-only hook fired inside the off-main profile-resolution batch, used to
        // simulate a slow batch advancing the wall clock so the post-FFI cache stamp can
        // be distinguished from a pre-FFI one (whitenoise-mac#181).
        onUserProfileLookup?(accountIdHex)
        // Snapshot the result *before* the gate so a held older load returns its account's profile
        // and a later switch/reinstall cannot retroactively change them (issue #283).
        let result: UserProfileMetadataFfi? =
            accountIdsMissingProfiles.contains(accountIdHex) ? nil : (profilesByAccountId[accountIdHex] ?? profile)
        userProfileGate.passIfArmed()
        return result
    }

    func releaseUserProfileGate() {
        userProfileGate.release()
    }

    func normalizeMemberRef(memberRef: String) throws -> MemberRefFfi {
        recordSyncCall("normalizeMemberRef")
        if let member = normalizedMembersByRef[memberRef] {
            return member
        }
        return MemberRefFfi(
            memberRef: memberRef,
            accountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            npub: "npub1alyce"
        )
    }

    func refreshProfile(accountIdHex: String, relays: [String]) async throws {
        recordedStateLock.withLock {
            _refreshedProfileIds.append(accountIdHex)
            _lastProfileRefreshRelays = relays
        }
        if let delay = profileRefreshDelaysByAccountId[accountIdHex] {
            try await Task.sleep(nanoseconds: delay)
        }
    }

    func clearRefreshedProfileIds() {
        recordedStateLock.withLock { _refreshedProfileIds = [] }
    }

    func clearTimelineMessageQueries() {
        timelineMessageQueries = []
    }

    func installDirectGroup(
        _ group: AppGroupRecordFfi,
        selfAccountIdHex: String,
        otherAccountIdHex: String,
        otherDisplayName: String,
        otherProfile: UserProfileMetadataFfi
    ) {
        groups = [group]
        registerDirectGroupDetails(
            group,
            selfAccountIdHex: selfAccountIdHex,
            otherAccountIdHex: otherAccountIdHex,
            otherDisplayName: otherDisplayName,
            otherProfile: otherProfile
        )
    }

    /// Install a direct group *alongside* the supplied companion groups (which stay raw group
    /// chats) instead of replacing the whole group set. Lets a test keep the direct chat
    /// non-selected while another, more-recent chat is auto-selected on bootstrap.
    func installDirectGroup(
        _ group: AppGroupRecordFfi,
        alongside companions: [AppGroupRecordFfi],
        selfAccountIdHex: String,
        otherAccountIdHex: String,
        otherDisplayName: String,
        otherProfile: UserProfileMetadataFfi
    ) {
        installGroups(companions + [group])
        registerDirectGroupDetails(
            group,
            selfAccountIdHex: selfAccountIdHex,
            otherAccountIdHex: otherAccountIdHex,
            otherDisplayName: otherDisplayName,
            otherProfile: otherProfile
        )
    }

    private func registerDirectGroupDetails(
        _ group: AppGroupRecordFfi,
        selfAccountIdHex: String,
        otherAccountIdHex: String,
        otherDisplayName: String,
        otherProfile: UserProfileMetadataFfi
    ) {
        profilesByAccountId[otherAccountIdHex] = otherProfile
        let details = GroupDetailsFfi(
            group: group,
            members: [
                GroupMemberDetailsFfi(
                    memberIdHex: selfAccountIdHex,
                    account: "Desktop Account",
                    local: true,
                    isAdmin: true,
                    isSelf: true,
                    npub: "npub1self",
                    displayName: "Desktop Account"
                ),
                GroupMemberDetailsFfi(
                    memberIdHex: otherAccountIdHex,
                    account: nil,
                    local: false,
                    isAdmin: false,
                    isSelf: false,
                    npub: "npub1alyce",
                    displayName: otherDisplayName
                ),
            ]
        )
        groupDetailsById[group.groupIdHex] = details
        groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
    }

    func installMessages(_ messages: [AppMessageRecordFfi], groupIdHex: String) {
        messagesByGroupId[groupIdHex] = messages
        timelinePagesByGroupId[groupIdHex] = projectedTimeline(from: messages)
    }

    func installTimelinePage(_ page: TimelinePageFfi, groupIdHex: String) {
        timelinePagesByGroupId[groupIdHex] = page
    }

    func installGroup(_ group: AppGroupRecordFfi) {
        groups = [group]
        let details = GroupDetailsFfi(group: group, members: [])
        groupDetailsById[group.groupIdHex] = details
        groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
    }

    func installMessageDraft(_ draft: MessageDraftFfi, accountRef: String) {
        recordedStateLock.withLock {
            storedMessageDraftsByAccountRef[accountRef, default: [:]][draft.groupIdHex] = draft
        }
    }

    func storedMessageDraft(accountRef: String, groupIdHex: String) -> MessageDraftFfi? {
        recordedStateLock.withLock {
            storedMessageDraftsByAccountRef[accountRef]?[groupIdHex]
        }
    }

    func installGroups(_ groups: [AppGroupRecordFfi]) {
        self.groups = groups
        for group in groups {
            let details = GroupDetailsFfi(group: group, members: [])
            groupDetailsById[group.groupIdHex] = details
            groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
        }
    }

    func installGroupDetails(_ details: GroupDetailsFfi, managementState: GroupManagementStateFfi? = nil) {
        groups = [details.group]
        groupDetailsById[details.group.groupIdHex] = details
        groupManagementStateById[details.group.groupIdHex] =
            managementState ?? defaultGroupManagementState(for: details)
    }

    func installGroupDetailsRecord(_ details: GroupDetailsFfi, managementState: GroupManagementStateFfi? = nil) {
        if let index = groups.firstIndex(where: { $0.groupIdHex == details.group.groupIdHex }) {
            groups[index] = details.group
        } else {
            groups.append(details.group)
        }
        groupDetailsById[details.group.groupIdHex] = details
        groupManagementStateById[details.group.groupIdHex] =
            managementState ?? defaultGroupManagementState(for: details)
    }

    func installChatListUpdates(_ updates: [ChatListSubscriptionUpdateFfi]) {
        chatListUpdates = updates
    }

    func installTimelineUpdates(_ updates: [TimelineSubscriptionUpdateFfi], groupIdHex: String) {
        timelineUpdatesByGroupId[groupIdHex] = updates
    }

    func installMediaRecord(_ record: MediaRecordFfi, download: MediaDownloadResultFfi) {
        mediaRecordsByGroupId[record.groupIdHex, default: []].append(record)
        mediaDownloadsByPlaintextSha256[record.reference.plaintextSha256] = download
    }

    func installProfile(accountIdHex: String, profile: UserProfileMetadataFfi) {
        profilesByAccountId[accountIdHex] = profile
    }

    func installRelayLists(
        defaultRelays: [String],
        bootstrapRelays: [String],
        nip65: [String],
        inbox: [String],
        complete: Bool = true,
        missing: [MissingRelayListKindFfi] = []
    ) {
        relayLists = AccountRelayListsFfi(
            complete: complete,
            missing: missing,
            defaultRelays: defaultRelays,
            bootstrapRelays: bootstrapRelays,
            nip65: RelayListFfi(kind: 10002, relays: nip65),
            inbox: RelayListFfi(kind: 10050, relays: inbox)
        )
    }

    func installNormalizedMemberRef(query: String, accountIdHex: String, npub: String) {
        normalizedMembersByRef[query] = MemberRefFfi(
            memberRef: query,
            accountIdHex: accountIdHex,
            npub: npub
        )
    }

    func createIdentity(defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        guard let createdAccount else { throw FakeMarmotRuntimeError.missingCreatedAccount }
        await createIdentityGate.passIfArmed()
        addOrReplaceAccount(createdAccount)
        return createdAccount
    }

    func releaseCreateIdentityGate() {
        createIdentityGate.release()
    }

    func login(identity: String, defaultRelays: [String], bootstrapRelays: [String]) async throws -> AccountSummaryFfi {
        guard let createdAccount else { throw FakeMarmotRuntimeError.missingCreatedAccount }
        await loginGate.passIfArmed()
        addOrReplaceAccount(createdAccount)
        return createdAccount
    }

    func releaseLoginGate() {
        loginGate.release()
    }

    /// Mirrors the real runtime: `login` / `createIdentity` add the account to
    /// the known set (replacing any existing entry with the same id) rather
    /// than discarding accounts already brought up this session. The account is
    /// not marked `running` here — only `start()` brings accounts online, which
    /// is the behaviour issues #31 / #74 exercise.
    private func addOrReplaceAccount(_ account: AccountSummaryFfi) {
        if let index = storedAccounts.firstIndex(where: { $0.accountIdHex == account.accountIdHex }) {
            storedAccounts[index] = account
        } else {
            storedAccounts.append(account)
        }
    }

    func publishUserProfile(
        accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]
    ) async throws -> UserProfileMetadataFfi {
        publishUserProfileCallCount += 1
        lastPublishedProfileDefaultRelays = defaultRelays
        lastPublishedProfileBootstrapRelays = bootstrapRelays
        if let publishUserProfileError {
            throw publishUserProfileError
        }
        self.profile = profile
        await publishUserProfileGate.passIfArmed()
        return profile
    }

    func uploadProfileImage(accountRef: String, data: Data, mediaType: String, blossomServer: String?) async throws
        -> String
    {
        uploadedProfileImageData = data
        uploadedProfileImageMediaType = mediaType
        uploadedProfileImageBlossomServer = blossomServer
        return uploadedProfileImageURL
    }

    func releasePublishUserProfileGate() {
        publishUserProfileGate.release()
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        accountRelayListsCallCount += 1
        recordSyncCall("accountRelayLists")
        // Snapshot the result *before* the gate so a held older load returns its account's relays
        // and a later switch/reinstall cannot retroactively change them (issue #283).
        let result = relayLists
        accountRelayListsGate.passIfArmed()
        return result
    }

    func releaseAccountRelayListsGate() {
        accountRelayListsGate.release()
    }

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        accountKeyPackagesCallCount += 1
        lastPackageFetchBootstrapRelays = bootstrapRelays
        // Snapshot the result *before* the gate so a held older load returns its account's packages
        // and a later switch/mutation cannot retroactively change them (issue #207).
        let result = keyPackagesByAccountRef[accountRef] ?? keyPackages
        await accountKeyPackagesGate.passIfArmed()
        return result
    }

    func accountFollows(accountRef: String) throws -> [String] {
        recordSyncCall("accountFollows")
        let resolved = followsByAccountRef[accountRef]?.sorted() ?? []
        followListReadGate.passIfArmed()
        if let followReadError { throw followReadError }
        return resolved
    }

    func isFollowing(accountRef: String, userRef: String) throws -> Bool {
        recordSyncCall("isFollowing")
        isFollowingCallCount += 1
        // Resolved before the gate on purpose: a gated read models the core answering from its
        // cache and the app receiving that answer later, which is exactly what makes a late
        // read *stale*. Resolving after the gate would let the fake see writes the real read
        // never could, and no test could reproduce a stale answer landing on fresh state.
        let resolved = followsByAccountRef[accountRef]?.contains(userRef.lowercased()) ?? false
        followReadGate.passIfArmed()
        if let followReadError { throw followReadError }
        return resolved
    }

    var followReadGateEnabled: Bool {
        get { followReadGate.isEnabled }
        set { followReadGate.isEnabled = newValue }
    }

    var didReachFollowReadGate: Bool {
        followReadGate.didReach
    }

    func releaseFollowReadGate() {
        followReadGate.release()
    }

    var followListReadGateEnabled: Bool {
        get { followListReadGate.isEnabled }
        set { followListReadGate.isEnabled = newValue }
    }

    var didReachFollowListReadGate: Bool {
        followListReadGate.didReach
    }

    func releaseFollowListReadGate() {
        followListReadGate.release()
    }

    func followUser(accountRef: String, userRef: String) async throws -> [String] {
        try await mutateFollow(accountRef: accountRef, userRef: userRef, isFollow: true)
    }

    func unfollowUser(accountRef: String, userRef: String) async throws -> [String] {
        try await mutateFollow(accountRef: accountRef, userRef: userRef, isFollow: false)
    }

    private func mutateFollow(accountRef: String, userRef: String, isFollow: Bool) async throws -> [String] {
        followMutationCalls.append(
            FollowMutationCall(accountRef: accountRef, userRef: userRef, isFollow: isFollow)
        )
        await followMutationGate.passIfArmed()
        if let followMutationError { throw followMutationError }
        var follows = followsByAccountRef[accountRef] ?? []
        if isFollow {
            follows.insert(userRef.lowercased())
        } else {
            follows.remove(userRef.lowercased())
        }
        followsByAccountRef[accountRef] = follows
        // The real core returns the complete list it actually published, which is not
        // necessarily the one the caller asked for.
        return followMutationResultOverride ?? follows.sorted()
    }

    func installFollows(accountRef: String, follows: [String]) {
        followsByAccountRef[accountRef] = Set(follows.map { $0.lowercased() })
    }

    var followMutationGateEnabled: Bool {
        get { followMutationGate.isEnabled }
        set { followMutationGate.isEnabled = newValue }
    }

    var didReachFollowMutationGate: Bool {
        followMutationGate.didReach
    }

    func releaseFollowMutationGate() {
        followMutationGate.release()
    }

    func installKeyPackages(accountRef: String, packages: [AccountKeyPackageFfi]) {
        keyPackagesByAccountRef[accountRef] = packages
    }

    func releaseAccountKeyPackagesGate() {
        accountKeyPackagesGate.release()
    }

    func auditLogFiles() throws -> [AuditLogFileFfi] {
        recordSyncCall("auditLogFiles")
        auditLogFilesGate.passIfArmed()
        return storedAuditLogFiles
    }

    func auditLogSettings() throws -> AuditLogSettingsFfi {
        recordSyncCall("auditLogSettings")
        return storedAuditLogSettings
    }

    func deleteAuditLogFile(path: String) async throws -> AuditLogDeleteResultFfi {
        guard !auditLogDeleteFailurePaths.contains(path) else {
            throw FakeMarmotRuntimeError.auditLogDeleteFailed
        }
        deletedAuditLogFilePaths.append(path)
        storedAuditLogFiles.removeAll { $0.path == path }
        return AuditLogDeleteResultFfi(stillRecording: storedAuditLogSettings.enabled)
    }

    func notificationSettings(accountRef: String) throws -> NotificationSettingsFfi {
        recordSyncCall("notificationSettings")
        let result = notificationSettingsByAccountRef[accountRef] ?? notificationSettings
        passNotificationSettingsGateIfArmed()
        return result
    }

    func installNotificationSettings(accountRef: String, settings: NotificationSettingsFfi) {
        notificationSettingsByAccountRef[accountRef] = settings
    }

    private func passNotificationSettingsGateIfArmed() {
        notificationSettingsGate.passIfArmed()
    }

    func releaseNotificationSettingsGate() {
        notificationSettingsGate.release()
    }

    func postAuditLogTrackerUpdate() async throws -> AuditLogTrackerUpdateResultFfi {
        didPostAuditLogTrackerUpdate = true
        return nextAuditLogTrackerUpdate
    }

    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi {
        recordSyncCall("relayTelemetrySettings")
        let result = storedRelayTelemetrySettings
        relayTelemetrySettingsGate.passIfArmed()
        return result
    }

    func releaseRelayTelemetrySettingsGate() {
        relayTelemetrySettingsGate.release()
    }

    var setAuditLogSettingsError: Error?

    func setAuditLogSettings(settings: AuditLogSettingsFfi) async throws -> AuditLogSettingsFfi {
        if let setAuditLogSettingsError { throw setAuditLogSettingsError }
        storedAuditLogSettings = settings
        return storedAuditLogSettings
    }

    func setAuditLogTrackerConfig(config: AuditLogTrackerConfigFfi) throws -> AuditLogTrackerConfigFfi {
        auditLogTrackerConfigSetCallCount += 1
        recordSyncCall("setAuditLogTrackerConfig")
        auditLogTrackerConfig = config
        return config
    }

    func setLocalNotificationsEnabled(accountRef: String, enabled: Bool) throws -> NotificationSettingsFfi {
        recordSyncCall("setLocalNotificationsEnabled")
        localNotificationsEnabledSet = enabled
        var updated = notificationSettingsByAccountRef[accountRef] ?? notificationSettings
        updated.localNotificationsEnabled = enabled
        if notificationSettingsByAccountRef[accountRef] != nil {
            notificationSettingsByAccountRef[accountRef] = updated
        } else {
            notificationSettings = updated
        }
        passSetLocalNotificationsGateIfArmed()
        return updated
    }

    func setNativePushEnabled(accountRef: String, enabled: Bool) async throws -> NotificationSettingsFfi {
        if let setNativePushEnabledError { throw setNativePushEnabledError }
        nativePushEnabledSet = enabled
        setNativePushEnabledCallCount += 1
        var updated = notificationSettingsByAccountRef[accountRef] ?? notificationSettings
        updated.nativePushEnabled = enabled
        if notificationSettingsByAccountRef[accountRef] != nil {
            notificationSettingsByAccountRef[accountRef] = updated
        } else {
            notificationSettings = updated
        }
        return updated
    }

    private func passSetLocalNotificationsGateIfArmed() {
        setLocalNotificationsGate.passIfArmed()
    }

    func releaseSetLocalNotificationsGate() {
        setLocalNotificationsGate.release()
    }

    func releaseAuditLogFilesGate() {
        auditLogFilesGate.release()
    }

    func setRelayTelemetryRuntimeConfig(config: RelayTelemetryRuntimeConfigFfi) async throws {
        relayTelemetryRuntimeConfigSetCallCount += 1
        relayTelemetryRuntimeConfig = config
    }

    var setRelayTelemetrySettingsError: Error?

    func setRelayTelemetrySettings(settings: RelayTelemetrySettingsFfi) async throws -> RelayTelemetrySettingsFfi {
        if let setRelayTelemetrySettingsError { throw setRelayTelemetrySettingsError }
        storedRelayTelemetrySettings = settings
        return storedRelayTelemetrySettings
    }

    func telemetryInstallId() throws -> String {
        telemetryInstallIdCallCount += 1
        recordSyncCall("telemetryInstallId")
        telemetryInstallIdGate.passIfArmed()
        if let telemetryInstallIdError {
            throw telemetryInstallIdError
        }
        return "test-install-id"
    }

    func releaseTelemetryInstallIdGate() {
        telemetryInstallIdGate.release()
    }

    func deleteAllLocalData() async throws {
        didDeleteAllLocalData = true
        await onDeleteAllLocalDataMidFlight?()
        if let deleteAllLocalDataError {
            throw deleteAllLocalDataError
        }
        storedAccounts = []
        groups = []
        messagesByGroupId = [:]
        timelinePagesByGroupId = [:]
        timelineUpdatesByGroupId = [:]
        mediaRecordsByGroupId = [:]
        mediaDownloadsByPlaintextSha256 = [:]
        chatListUpdates = []
        storedAuditLogFiles = []
    }

    func removeAccount(accountRef: String) async throws {
        removedAccountRefs.append(accountRef)
        if let removeAccountError { throw removeAccountError }
        if let onRemoveAccountMidFlight {
            await onRemoveAccountMidFlight(accountRef)
        }
        storedAccounts.removeAll { $0.label == accountRef }
    }

    func publishNewKeyPackage(accountRef: String) async throws -> UInt64 {
        didPublishNewKeyPackage = true
        keyPackages.append(
            AccountKeyPackageFfi(
                accountRef: accountRef,
                accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                keyPackageId: "slot-new",
                keyPackageRefHex: "ref-new",
                eventIdHex: "event-new",
                publishedAt: 1_700_000_200,
                keyPackageBytes: 524,
                sourceRelays: MarmotClient.seedRelays,
                local: true,
                relay: true
            )
        )
        return 1
    }

    func republishKeyPackage(accountRef: String) async throws -> UInt64 {
        didRepublishKeyPackage = true
        return 1
    }

    func deleteAccountKeyPackage(accountRef: String, eventIdHex: String, relays: [String]) async throws -> UInt64 {
        deletedPackageEventId = eventIdHex
        lastPackageDeleteRelays = relays
        keyPackages.removeAll { $0.eventIdHex == eventIdHex }
        return 1
    }

    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws
        -> String
    {
        createGroupAttempts.append(memberRefs)
        await onMemberResolutionAttempt?()
        if let forgetsMissingKeyPackagesAfterAttempts,
            createGroupAttempts.count > forgetsMissingKeyPackagesAfterAttempts
        {
            missingKeyPackageAccountIdHexByMemberRef = [:]
        }
        // Member resolution runs in list order and stops at the first member it can't resolve,
        // whichever way that member fails.
        let refusedMemberRef = memberRefs.first {
            missingKeyPackageAccountIdHexByMemberRef[$0] != nil || invalidKeyPackageMemberRefs.contains($0)
                || unresolvableMemberRefs.contains($0)
        }
        let pendingFailure =
            createGroupAttempts.count > createGroupFailureAfterAttempts ? createGroupFailure : nil
        if pendingFailure != nil || refusedMemberRef != nil {
            // Pass the gate before throwing so a test can hold a *failing* create in flight and
            // switch accounts under it. Deliberately ahead of every mutation below, so a refused
            // create still records nothing — the success path keeps its own gate at the end.
            await createGroupGate.passIfArmed()
            if let pendingFailure {
                throw pendingFailure
            }
            if let refusedMemberRef {
                if let accountIdHex = missingKeyPackageAccountIdHexByMemberRef[refusedMemberRef] {
                    throw MarmotKitError.MissingKeyPackage(account: accountIdHex)
                }
                if unresolvableMemberRefs.contains(refusedMemberRef) {
                    throw MarmotKitError.Publish(details: "no relay list for member")
                }
                throw MarmotKitError.InvalidKeyPackageEvent(details: "unusable key package event")
            }
        }
        createdGroupMemberRefs = memberRefs
        createdGroupName = name
        createdGroupDescription = description
        groups = [
            AppGroupRecordFfi(
                groupIdHex: "created-group",
                endpoint: "",
                name: name,
                description: description ?? "",
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
                selfMembership: .member,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            )
        ]
        if let group = groups.first {
            let details = GroupDetailsFfi(group: group, members: [])
            groupDetailsById[group.groupIdHex] = details
            groupManagementStateById[group.groupIdHex] = defaultGroupManagementState(for: details)
        }
        await createGroupGate.passIfArmed()
        return "created-group"
    }

    func releaseCreateGroupGate() {
        createGroupGate.release()
    }

    func acceptGroupInvite(accountRef: String, groupIdHex: String) async throws -> AppGroupRecordFfi {
        acceptGroupInviteCallCount += 1
        await groupInviteGate.passIfArmed()
        acceptedInviteGroupIds.append(groupIdHex)
        guard let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) else {
            throw FakeMarmotRuntimeError.unused
        }
        groups[index].pendingConfirmation = false
        if var details = groupDetailsById[groupIdHex] {
            details.group.pendingConfirmation = false
            groupDetailsById[groupIdHex] = details
            groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        }
        return groups[index]
    }

    func declineGroupInvite(accountRef: String, groupIdHex: String) async throws -> GroupInviteDeclineResultFfi {
        declineGroupInviteCallCount += 1
        await groupInviteGate.passIfArmed()
        declinedInviteGroupIds.append(groupIdHex)
        guard let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) else {
            throw FakeMarmotRuntimeError.unused
        }
        var group = groups.remove(at: index)
        group.pendingConfirmation = false
        groupDetailsById[groupIdHex] = nil
        groupManagementStateById[groupIdHex] = nil
        return GroupInviteDeclineResultFfi(
            group: group,
            summary: SendSummaryFfi(published: 1, messageIds: ["group-decline"])
        )
    }

    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi {
        recordedStateLock.withLock { _groupDetailsCallCounts[groupIdHex, default: 0] += 1 }
        if groupDetailsFailureGroupIds.contains(groupIdHex) {
            throw FakeMarmotRuntimeError.unused
        }
        // Snapshot the value *before* the gate so a held older load captures the older details and a
        // later mutation cannot retroactively change what it returns (issue #135 last-request-wins).
        let result: GroupDetailsFfi
        if let details = groupDetailsById[groupIdHex] {
            result = details
        } else if let group = groups.first(where: { $0.groupIdHex == groupIdHex }) {
            result = GroupDetailsFfi(group: group, members: [])
        } else {
            throw FakeMarmotRuntimeError.unused
        }
        await groupDetailsGate.passIfArmed()
        return result
    }

    func releaseGroupDetailsGate() {
        groupDetailsGate.release()
    }

    func groupManagementState(accountRef: String, groupIdHex: String) async throws -> GroupManagementStateFfi {
        await groupManagementStateGate.passIfArmed()
        if let state = groupManagementStateById[groupIdHex] {
            return state
        }
        let details = try await groupDetails(accountRef: accountRef, groupIdHex: groupIdHex)
        let state = defaultGroupManagementState(for: details)
        groupManagementStateById[groupIdHex] = state
        return state
    }

    func inviteMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    {
        inviteMembersDetailedCallCount += 1
        await groupMutationGate.passIfArmed()
        inviteMemberRefAttempts.append(memberRefs)
        await onMemberResolutionAttempt?()
        // Invites resolve every member's KeyPackage before committing anything and stop at the
        // first one they can't, exactly as `createGroup` does.
        if let refusedMemberRef = memberRefs.first(where: {
            missingKeyPackageAccountIdHexByMemberRef[$0] != nil || invalidKeyPackageMemberRefs.contains($0)
        }) {
            if let accountIdHex = missingKeyPackageAccountIdHexByMemberRef[refusedMemberRef] {
                throw MarmotKitError.MissingKeyPackage(account: accountIdHex)
            }
            throw MarmotKitError.InvalidKeyPackageEvent(details: "unusable key package event")
        }
        invitedMemberRefs = memberRefs
        guard var details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }

        for memberRef in memberRefs {
            let normalized = normalizedMembersByRef.values.first { member in
                member.memberRef == memberRef || member.npub == memberRef || member.accountIdHex == memberRef
            }
            let memberIdHex = normalized?.accountIdHex ?? memberRef
            guard !details.members.contains(where: { $0.memberIdHex == memberIdHex }) else { continue }
            details.members.append(
                GroupMemberDetailsFfi(
                    memberIdHex: memberIdHex,
                    account: nil,
                    local: false,
                    isAdmin: false,
                    isSelf: false,
                    npub: normalized?.npub ?? memberRef,
                    displayName: nil
                )
            )
        }
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-invite")
    }

    func leaveGroup(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        leaveGroupCallCount += 1
        groupMutationOrder.append("leave")
        await groupMutationGate.passIfArmed()
        if let leaveGroupError { throw leaveGroupError }
        leftGroupIdHex = groupIdHex
        // The core records a *departure*; it does not drop the conversation. `selfMembership`
        // becomes `Left` as soon as the SelfRemove publishes, and `leaveRequestPending` stays true
        // until a remaining member commits it — which for a group whose others never come back is
        // never. Deleting the row here modelled a state the core does not produce, and hid the fact
        // that a departed chat has to stay actionable so its local copy can be deleted.
        pendingLeaveGroupIds.insert(groupIdHex)
        if let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) {
            groups[index].selfMembership = .left
        }
        if var details = groupDetailsById[groupIdHex] {
            details.group.selfMembership = .left
            groupDetailsById[groupIdHex] = details
        }
        if var managementState = groupManagementStateById[groupIdHex] {
            managementState.canLeave = false
            managementState.leaveRequestPending = true
            managementState.leaveRequestedAtMs = 1_700_000_000_000
            groupManagementStateById[groupIdHex] = managementState
        }
        return SendSummaryFfi(published: 1, messageIds: ["group-leave"])
    }

    func promoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    {
        promoteAdminDetailedCallCount += 1
        await groupMutationGate.passIfArmed()
        if let promoteAdminError { throw promoteAdminError }
        groupMutationOrder.append("promote")
        promotedAdminRef = memberRef
        let managementStateBeforePromote = groupManagementStateById[groupIdHex]
        updateMember(groupIdHex: groupIdHex, matching: memberRef) { member in
            member.isAdmin = true
        }
        // `updateMember` recomputes the management state from the new admin set, so a second admin
        // clears both `isLastAdmin` and the leave block — which is exactly what the
        // hand-admin-over-then-leave flow depends on. This knob poses as a core that reports no
        // change at all, so the leave that follows still sees the sole-admin block.
        if keepsManagementStateAfterPromote, let managementStateBeforePromote {
            groupManagementStateById[groupIdHex] = managementStateBeforePromote
        }
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-promote")
    }

    func demoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws
        -> GroupMutationResultFfi
    {
        demoteAdminDetailedCallCount += 1
        await groupMutationGate.passIfArmed()
        demotedAdminRef = memberRef
        updateMember(groupIdHex: groupIdHex, matching: memberRef) { member in
            member.isAdmin = false
        }
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-demote")
    }

    func removeMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws
        -> GroupMutationResultFfi
    {
        removeMembersDetailedCallCount += 1
        await groupMutationGate.passIfArmed()
        removedMemberRefs = memberRefs
        guard var details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }
        details.members.removeAll { member in
            memberRefs.contains { memberMatches(member, ref: $0) }
        }
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-remove")
    }

    func selfDemoteAdminDetailed(accountRef: String, groupIdHex: String) async throws -> GroupMutationResultFfi {
        selfDemoteAdminDetailedCallCount += 1
        groupMutationOrder.append("selfDemote")
        await groupMutationGate.passIfArmed()
        selfDemotedGroupIdHex = groupIdHex
        guard var details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }
        if let index = details.members.firstIndex(where: \.isSelf) {
            details.members[index].isAdmin = false
        }
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
        return try groupMutationResult(groupIdHex: groupIdHex, messageId: "group-self-demote")
    }

    func setGroupArchived(accountRef: String, groupIdHex: String, archived: Bool) async throws -> AppGroupRecordFfi {
        setGroupArchivedCallCount += 1
        await groupMutationGate.passIfArmed()
        if let setGroupArchivedError { throw setGroupArchivedError }
        archivedGroup = ArchivedGroup(groupIdHex: groupIdHex, archived: archived)
        guard let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) else {
            throw FakeMarmotRuntimeError.unused
        }
        groups[index].archived = archived
        if var details = groupDetailsById[groupIdHex] {
            details.group.archived = archived
            groupDetailsById[groupIdHex] = details
        }
        return groups[index]
    }

    func updateGroupAvatarUrl(accountRef: String, groupIdHex: String, url: String?, dim: String?, thumbhash: String?)
        async throws -> SendSummaryFfi
    {
        updateGroupAvatarUrlCallCount += 1
        await groupAvatarUpdateGate.passIfArmed()

        updatedGroupAvatar = UpdatedGroupAvatar(groupIdHex: groupIdHex, url: url, dim: dim, thumbhash: thumbhash)

        if let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) {
            groups[index].avatarUrl = url
            groups[index].avatarDim = dim
            groups[index].avatarThumbhash = thumbhash
        }

        if var details = groupDetailsById[groupIdHex] {
            details.group.avatarUrl = url
            details.group.avatarDim = dim
            details.group.avatarThumbhash = thumbhash
            groupDetailsById[groupIdHex] = details
        }

        return SendSummaryFfi(published: 1, messageIds: ["group-avatar"])
    }

    func updateGroupImage(accountRef: String, groupIdHex: String, plaintext: Data, mediaType: String) async throws
        -> SendSummaryFfi
    {
        updateGroupImageCallCount += 1
        await groupAvatarUpdateGate.passIfArmed()
        updatedEncryptedGroupImage = plaintext
        updatedEncryptedGroupImageMediaType = mediaType
        if let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) {
            groups[index].imageHashHex = "encrypted-image-hash"
        }
        return SendSummaryFfi(published: 1, messageIds: ["group-image"])
    }

    func clearGroupImage(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        clearGroupImageCallCount += 1
        if let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) {
            groups[index].imageHashHex = nil
        }
        return SendSummaryFfi(published: 1, messageIds: ["group-image-clear"])
    }

    func downloadGroupBlossomImage(accountRef: String, groupIdHex: String) async throws -> Data {
        downloadGroupImageCallCount += 1
        return downloadedGroupImage
    }

    func releaseGroupAvatarUpdateGate() {
        groupAvatarUpdateGate.release()
    }

    func releaseGroupMutationGate() {
        groupMutationGate.release()
    }

    func releaseGroupManagementStateGate() {
        groupManagementStateGate.release()
    }

    func releaseGroupInviteGate() {
        groupInviteGate.release()
    }

    func updateGroupProfile(accountRef: String, groupIdHex: String, name: String?, description: String?) async throws
        -> SendSummaryFfi
    {
        updateGroupProfileCallCount += 1
        await groupMutationGate.passIfArmed()
        updatedGroupProfile = UpdatedGroupProfile(groupIdHex: groupIdHex, name: name, description: description)

        if let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) {
            if let name {
                groups[index].name = name
            }
            if let description {
                groups[index].description = description
            }
        }

        if var details = groupDetailsById[groupIdHex] {
            if let name {
                details.group.name = name
            }
            if let description {
                details.group.description = description
            }
            groupDetailsById[groupIdHex] = details
        }

        return SendSummaryFfi(published: 1, messageIds: ["group-profile"])
    }

    func setAccountInboxRelays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    {
        lastSetInboxBootstrapRelays = bootstrapRelays
        relayLists.inbox = RelayListFfi(kind: relayLists.inbox.kind, relays: relays)
        // Snapshot before the gate so a held older save returns its account's lists.
        let result = relayLists
        await setAccountRelaysGate.passIfArmed()
        return result
    }

    func setAccountNip65Relays(accountRef: String, relays: [String], bootstrapRelays: [String]) async throws
        -> AccountRelayListsFfi
    {
        lastSetNip65BootstrapRelays = bootstrapRelays
        relayLists.nip65 = RelayListFfi(kind: relayLists.nip65.kind, relays: relays)
        let result = relayLists
        await setAccountRelaysGate.passIfArmed()
        return result
    }

    func releaseSetAccountRelaysGate() {
        setAccountRelaysGate.release()
    }

    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription {
        recordedStateLock.withLock { _chatListSubscriptionCount += 1 }
        if chatListSubscriptionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: chatListSubscriptionDelayNanoseconds)
        }
        return FakeChatListSubscription(
            rows: chatListRows(includeArchived: includeArchived),
            updates: chatListUpdates,
            endsWhenExhausted: chatListStreamEndsAfterUpdates,
            recordSnapshot: { [weak self] in
                self?.recordSyncCall("chatListSubscription.snapshot")
            }
        )
    }

    private func chatListRows(includeArchived: Bool) -> [ChatListRowFfi] {
        groups
            .filter { includeArchived || !$0.archived }
            .map { chatListRow(for: $0) }
    }

    /// Per-account one-shot chat lists, for the accounts the app never subscribes to. An account
    /// with no entry answers from the shared `groups`, the way `subscribeChatList` does.
    var chatListRowsByAccountRef: [String: [ChatListRowFfi]] = [:]
    var chatListCallCount = 0
    var chatListAccountRefs: [String] = []
    var chatListError: Error?

    func chatList(accountRef: String, includeArchived: Bool) throws -> [ChatListRowFfi] {
        chatListCallCount += 1
        chatListAccountRefs.append(accountRef)
        if let chatListError { throw chatListError }
        guard let installed = chatListRowsByAccountRef[accountRef] else {
            return chatListRows(includeArchived: includeArchived)
        }
        return installed.filter { includeArchived || !$0.archived }
    }

    private func groupMutationResult(groupIdHex: String, messageId: String) throws -> GroupMutationResultFfi {
        guard let details = groupDetailsById[groupIdHex] else {
            throw FakeMarmotRuntimeError.unused
        }
        let managementState = groupManagementStateById[groupIdHex] ?? defaultGroupManagementState(for: details)
        return GroupMutationResultFfi(
            summary: SendSummaryFfi(published: 1, messageIds: [messageId]),
            details: details,
            managementState: managementState
        )
    }

    private func updateMember(
        groupIdHex: String,
        matching memberRef: String,
        update: (inout GroupMemberDetailsFfi) -> Void
    ) {
        guard var details = groupDetailsById[groupIdHex],
            let index = details.members.firstIndex(where: { memberMatches($0, ref: memberRef) })
        else { return }

        update(&details.members[index])
        groupDetailsById[groupIdHex] = details
        groupManagementStateById[groupIdHex] = defaultGroupManagementState(for: details)
    }

    private func memberMatches(_ member: GroupMemberDetailsFfi, ref: String) -> Bool {
        member.memberIdHex == ref || member.npub == ref || member.account == ref
    }

    private func defaultGroupManagementState(for details: GroupDetailsFfi) -> GroupManagementStateFfi {
        let selfMember = details.members.first(where: \.isSelf)
        let adminCount = details.members.filter(\.isAdmin).count
        let selfIsAdmin = selfMember?.isAdmin ?? true
        let memberActions = details.members.map { member in
            GroupMemberActionStateFfi(
                memberIdHex: member.memberIdHex,
                isSelf: member.isSelf,
                isAdmin: member.isAdmin,
                canRemove: selfIsAdmin && !member.isSelf,
                canPromote: selfIsAdmin && !member.isAdmin,
                canDemote: selfIsAdmin && member.isAdmin && (!member.isSelf || adminCount > 1)
            )
        }

        return GroupManagementStateFfi(
            myAccountIdHex: selfMember?.memberIdHex ?? storedAccounts.first?.accountIdHex ?? "",
            isSelfAdmin: selfIsAdmin,
            isLastAdmin: selfIsAdmin && adminCount <= 1,
            canInvite: selfIsAdmin,
            canLeave: !selfIsAdmin || adminCount > 1,
            requiresSelfDemoteBeforeLeave: selfIsAdmin,
            memberActions: memberActions
        )
    }

    func subscribeNotifications() async throws -> NotificationsSubscription {
        recordedStateLock.withLock { _notificationSubscriptionCount += 1 }
        if let subscribeNotificationsError {
            throw subscribeNotificationsError
        }
        return FakeNotificationsSubscription(endsImmediately: notificationStreamEndsImmediately)
    }

    func searchUsers(accountIdHex: String, query: String, radiusStart: UInt8, radiusEnd: UInt8) async throws
        -> UserSearchSubscription
    {
        recordedStateLock.withLock {
            _userSearchCalls.append(
                UserSearchCall(
                    accountIdHex: accountIdHex,
                    query: query,
                    radiusStart: radiusStart,
                    radiusEnd: radiusEnd
                )
            )
        }
        if let searchUsersError {
            throw searchUsersError
        }
        return FakeUserSearchSubscription(
            updates: userSearchUpdates,
            updateDelayNanoseconds: userSearchUpdateDelayNanoseconds,
            recordNextUpdate: { [weak self] in
                guard let self else { return }
                self.recordedStateLock.withLock { self._userSearchNextUpdateCount += 1 }
            }
        )
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        recordSyncCall("timelineMessages")
        timelineMessageQueries.append(query)
        if let timelineMessagesHandler {
            return try timelineMessagesHandler(query)
        }
        if let groupIdHex = query.groupIdHex {
            return pagedTimeline(from: timelinePagesByGroupId[groupIdHex]?.messages ?? [], query: query)
        }

        let messages = timelinePagesByGroupId.values.flatMap(\.messages).sorted { lhs, rhs in
            if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
            return lhs.messageIdHex < rhs.messageIdHex
        }
        return pagedTimeline(from: messages, query: query)
    }

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws
        -> TimelineMessagesSubscription
    {
        recordedStateLock.withLock {
            _timelineSubscriptionCount += 1
            _timelineSubscriptionAccountRefs.append(accountRef)
        }
        if timelineSubscriptionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: timelineSubscriptionDelayNanoseconds)
        }
        let ordered: [TimelineMessageRecordFfi]
        if let groupIdHex {
            ordered = timelinePagesByGroupId[groupIdHex]?.messages ?? []
        } else {
            ordered = timelinePagesByGroupId.values.flatMap(\.messages)
        }
        let subscription = FakeTimelineMessagesSubscription(
            messages: ordered,
            limit: Int(limit ?? 100),
            windowCap: 200,
            updates: groupIdHex.flatMap { timelineUpdatesByGroupId[$0] } ?? [],
            updateDelayNanoseconds: timelineUpdateDelayNanoseconds,
            endsWhenExhausted: timelineStreamEndsAfterUpdates,
            recordSnapshot: { [weak self] in
                self?.recordSyncCall("timelineMessagesSubscription.snapshot")
            }
        )
        recordedStateLock.withLock { _lastTimelineSubscription = subscription }
        return subscription
    }

    func initializeChatReadState(accountRef: String, groupIdHex: String) throws -> ChatListRowFfi? {
        recordSyncCall("initializeChatReadState")
        guard initializeChatReadStateReturnsRow else { return nil }
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func markTimelineMessageRead(accountRef: String, groupIdHex: String, messageIdHex: String) throws -> ChatListRowFfi?
    {
        recordSyncCall("markTimelineMessageRead")
        markedReadMessageIds.append(messageIdHex)
        markTimelineMessageReadGate.passIfArmed()
        if let markTimelineMessageReadError {
            throw markTimelineMessageReadError
        }
        return groups.first(where: { $0.groupIdHex == groupIdHex }).map(chatListRow(for:))
    }

    func releaseMarkTimelineMessageReadGate() {
        markTimelineMessageReadGate.release()
    }

    func messageDrafts(accountRef: String) throws -> [MessageDraftSummaryFfi] {
        recordSyncCall("messageDrafts")
        return recordedStateLock.withLock {
            (storedMessageDraftsByAccountRef[accountRef] ?? [:]).values
                .sorted {
                    if $0.updatedAtMs != $1.updatedAtMs { return $0.updatedAtMs > $1.updatedAtMs }
                    return $0.groupIdHex < $1.groupIdHex
                }
                .map { draft in
                    MessageDraftSummaryFfi(
                        groupIdHex: draft.groupIdHex,
                        content: draft.content,
                        replyToMessageIdHex: draft.replyToMessageIdHex,
                        mediaAttachments: draft.mediaAttachments.map { attachment in
                            MessageDraftAttachmentSummaryFfi(
                                id: attachment.id,
                                fileName: attachment.fileName,
                                mediaType: attachment.mediaType,
                                plaintextSize: UInt64(attachment.plaintext.count)
                            )
                        },
                        createdAtMs: draft.createdAtMs,
                        updatedAtMs: draft.updatedAtMs
                    )
                }
        }
    }

    func messageDraft(accountRef: String, groupIdHex: String) throws -> MessageDraftFfi? {
        recordSyncCall("messageDraft")
        let draft = recordedStateLock.withLock {
            storedMessageDraftsByAccountRef[accountRef]?[groupIdHex]
        }
        messageDraftReadGate.passIfArmed()
        return draft
    }

    func saveMessageDraft(
        accountRef: String,
        groupIdHex: String,
        content: String,
        replyToMessageIdHex: String?,
        mediaAttachments: [MessageDraftAttachmentFfi]
    ) throws -> MessageDraftFfi {
        recordSyncCall("saveMessageDraft")
        return recordedStateLock.withLock {
            messageDraftTimestamp += 1
            let stored = storedMessageDraftsByAccountRef[accountRef]?[groupIdHex]
            let draft = MessageDraftFfi(
                groupIdHex: groupIdHex,
                content: content,
                replyToMessageIdHex: replyToMessageIdHex,
                mediaAttachments: mediaAttachments,
                createdAtMs: stored?.createdAtMs ?? messageDraftTimestamp,
                updatedAtMs: messageDraftTimestamp
            )
            storedMessageDraftsByAccountRef[accountRef, default: [:]][groupIdHex] = draft
            return draft
        }
    }

    func deleteMessageDraft(accountRef: String, groupIdHex: String) throws {
        recordSyncCall("deleteMessageDraft")
        recordedStateLock.withLock {
            storedMessageDraftsByAccountRef[accountRef]?[groupIdHex] = nil
        }
    }

    func releaseMessageDraftReadGate() {
        messageDraftReadGate.release()
    }

    func listMedia(accountRef: String, groupIdHex: String, limit: UInt32?) throws -> [MediaRecordFfi] {
        recordedStateLock.withLock { _listMediaCallCount += 1 }
        listMediaGate.passIfArmed()
        let records = mediaRecordsByGroupId[groupIdHex] ?? []
        guard let limit else { return records }
        return Array(records.prefix(Int(limit)))
    }

    func releaseListMediaGate() {
        listMediaGate.release()
    }

    func downloadMedia(accountRef: String, groupIdHex: String, reference: MediaAttachmentReferenceFfi) async throws
        -> MediaDownloadResultFfi
    {
        recordedStateLock.withLock {
            _downloadMediaCallCount += 1
            _downloadedMediaReferences.append(reference)
        }
        guard let download = mediaDownloadsByPlaintextSha256[reference.plaintextSha256] else {
            throw FakeMarmotRuntimeError.unused
        }
        await mediaDownloadGate.passIfArmed()
        return download
    }

    func uploadMedia(accountRef: String, groupIdHex: String, request: MediaUploadRequestFfi) async throws
        -> MediaUploadResultFfi
    {
        recordedStateLock.withLock {
            _uploadMediaCallCount += 1
            _uploadedMedia = UploadedMedia(groupIdHex: groupIdHex, request: request)
            _uploadedMediaRequests.append(UploadedMedia(groupIdHex: groupIdHex, request: request))
        }
        await messageActionGate.passIfArmed()
        for attachment in request.attachments {
            await uploadReleaseGate.waitIfHeld(attachment.fileName)
        }
        // Claiming the failure inside the lock keeps two concurrent uploads of the same file name
        // from both consuming the one-shot entry and both throwing.
        let shouldFail = recordedStateLock.withLock { () -> Bool in
            guard
                let failing = request.attachments.first(where: {
                    _uploadMediaFailingFileNames.contains($0.fileName)
                })
            else { return false }
            _uploadMediaFailingFileNames.remove(failing.fileName)
            return true
        }
        if shouldFail {
            throw FakeMarmotRuntimeError.mediaUploadFailed
        }
        let returnsEmptyResult = recordedStateLock.withLock {
            request.attachments.contains { _uploadMediaEmptyResultFileNames.contains($0.fileName) }
        }
        if returnsEmptyResult {
            return MediaUploadResultFfi(attachments: [], sent: nil)
        }
        let attachments = request.attachments.map { attachment in
            let sequence = recordedStateLock.withLock { () -> Int in
                _uploadedAttachmentSequence += 1
                return _uploadedAttachmentSequence
            }
            return MediaUploadAttachmentResultFfi(
                // Real digests, like the core produces: the media disk cache verifies
                // `plaintextSha256` against the bytes it reads back, so a placeholder here would
                // make every cached outgoing attachment silently unreadable.
                reference: MediaAttachmentReferenceFfi(
                    locators: [MediaLocatorFfi(kind: "blossom", value: "https://example.com/media-\(sequence)")],
                    ciphertextSha256: hexSHA256(Data("ciphertext-\(sequence)".utf8)),
                    plaintextSha256: hexSHA256(attachment.plaintext),
                    nonceHex: String(format: "%024x", sequence),
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    version: .v1,
                    sourceEpoch: 1,
                    dim: attachment.dim,
                    thumbhash: attachment.thumbhash
                ),
                encryptedSizeBytes: UInt64(attachment.plaintext.count + 16)
            )
        }
        return MediaUploadResultFfi(
            attachments: attachments,
            sent: request.send ? SendSummaryFfi(published: 1, messageIds: ["media"]) : nil
        )
    }

    func sendMediaAttachments(
        accountRef: String,
        groupIdHex: String,
        attachments: [MediaAttachmentReferenceFfi],
        caption: String?
    ) async throws -> SendSummaryFfi {
        recordedStateLock.withLock {
            _sendMediaAttachmentsCallCount += 1
            _sentMediaAttachments.append(
                SentMediaAttachments(groupIdHex: groupIdHex, attachments: attachments, caption: caption)
            )
        }
        await messageActionGate.passIfArmed()
        if let sendMediaAttachmentsError {
            throw sendMediaAttachmentsError
        }
        return SendSummaryFfi(published: 1, messageIds: ["media"])
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        sendTextCallCount += 1
        sentText = SentText(groupIdHex: groupIdHex, text: text)
        await messageActionGate.passIfArmed()
        publishedTexts.append(SentText(groupIdHex: groupIdHex, text: text))
        if let sendTextError {
            throw sendTextError
        }
        return SendSummaryFfi(published: 1, messageIds: ["text"])
    }

    func retryGroupConvergence(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        retryGroupConvergenceCallCount += 1
        retriedGroupIdHex = groupIdHex
        await messageActionGate.passIfArmed()
        if let retryGroupConvergenceError {
            throw retryGroupConvergenceError
        }
        return SendSummaryFfi(published: 1, messageIds: ["retry"])
    }

    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws
        -> SendSummaryFfi
    {
        replyToMessageCallCount += 1
        repliedMessage = SentReply(groupIdHex: groupIdHex, targetMessageId: targetMessageId, text: text)
        await messageActionGate.passIfArmed()
        if let replyToMessageError {
            throw replyToMessageError
        }
        return SendSummaryFfi(published: 1, messageIds: ["reply"])
    }

    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws
        -> SendSummaryFfi
    {
        reactToMessageCallCount += 1
        reactedMessage = SentReaction(groupIdHex: groupIdHex, targetMessageId: targetMessageId, emoji: emoji)
        await messageActionGate.passIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["reaction"])
    }

    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        deleteMessageCallCount += 1
        deletedMessage = DeletedMessage(groupIdHex: groupIdHex, targetMessageId: targetMessageId)
        await messageActionGate.passIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["delete"])
    }

    func editMessage(accountRef: String, groupIdHex: String, targetMessageId: String, content: String) async throws
        -> SendSummaryFfi
    {
        editMessageCallCount += 1
        editedMessage = EditedMessage(groupIdHex: groupIdHex, targetMessageId: targetMessageId, content: content)
        await messageActionGate.passIfArmed()
        return SendSummaryFfi(published: 1, messageIds: ["edit"])
    }
    func releaseMessageActionGate() {
        messageActionGate.release()
    }

    func releaseMediaDownloadGate() {
        mediaDownloadGate.release()
    }

    // MARK: - darkmatter 745959e FFI additions

    var parseMarkdownCallCount = 0
    var signOutCallCount = 0
    var signedOutAccountRefs: [String] = []
    var signInAccountCallCount = 0
    var revealNsecCallCount = 0
    var exportEncryptedSecretKeyCallCount = 0
    var deleteGroupLocalCallCount = 0
    var locallyDeletedGroupIds: [String] = []
    var updateMessageRetentionCallCount = 0
    var lastRetentionSecs: UInt64?
    var secureDeleteExpiredCallCount = 0
    var sweepExpiredRetentionCallCount = 0
    var setChatManuallyUnreadCallCount = 0
    var lastManuallyUnreadValue: Bool?
    var setChatMutedCallCount = 0
    var clearChatMutedCallCount = 0
    var lastMutedUntilMs: Int64?
    var recordedHostPerformance: [(HostPerformanceOperationFfi, UInt64, HostPerformanceOutcomeFfi)] = []
    private let secureDeleteExpiredGate = AsyncFfiGate()
    var secureDeleteExpiredGateEnabled: Bool {
        get { secureDeleteExpiredGate.isEnabled }
        set { secureDeleteExpiredGate.isEnabled = newValue }
    }
    var didReachSecureDeleteExpiredGate: Bool {
        secureDeleteExpiredGate.didReach
    }
    var accountUnreadSummaryRows: [AccountUnreadFfi] = []
    var accountUnreadSummaryCallCount = 0
    /// Withholds the selected chat's read-state row, so a test can keep the timeline's off-main
    /// `applyChatRow` out of a window where it counts chat-list work.
    var initializeChatReadStateReturnsRow = true
    private let accountUnreadSummaryGate = BlockingFfiGate()
    /// Parks the first summary query off-main so a later one can overtake it.
    var accountUnreadSummaryGateEnabled: Bool {
        get { accountUnreadSummaryGate.isEnabled }
        set { accountUnreadSummaryGate.isEnabled = newValue }
    }
    var didReachAccountUnreadSummaryGate: Bool {
        accountUnreadSummaryGate.didReach
    }

    func releaseAccountUnreadSummaryGate() {
        accountUnreadSummaryGate.release()
    }

    func parseMarkdown(text: String) -> MarkdownDocumentFfi {
        parseMarkdownCallCount += 1
        return MarkdownDocumentFfi(blocks: [], truncated: false)
    }

    func accountUnreadSummary() throws -> [AccountUnreadFfi] {
        accountUnreadSummaryCallCount += 1
        // Snapshot before parking, the way the real query answers from the store as it stood when
        // the call was made: a gated call must come back with stale totals, not fresh ones.
        let rows = accountUnreadSummaryRows
        accountUnreadSummaryGate.passIfArmed()
        return rows
    }

    func signOut(accountRef: String, deleteKeyPackages: Bool) async throws -> SignOutOutcomeFfi {
        signOutCallCount += 1
        signedOutAccountRefs.append(accountRef)
        if let signOutError { throw signOutError }
        if let index = storedAccounts.firstIndex(where: { $0.label == accountRef }) {
            storedAccounts[index].signedOut = true
            storedAccounts[index].running = false
        }
        if let onSignOutAccountMidFlight {
            await onSignOutAccountMidFlight(accountRef)
        }
        return SignOutOutcomeFfi(
            keyPackagesDeleted: 0,
            keyPackageFailures: [],
            localCleanup: LocalCleanupReportFfi(completed: true, reason: nil)
        )
    }

    func signInAccount(accountRef: String) async throws -> AccountSummaryFfi {
        signInAccountCallCount += 1
        if let index = storedAccounts.firstIndex(where: { $0.label == accountRef }) {
            storedAccounts[index].signedOut = false
            storedAccounts[index].running = true
        }
        if let onSignInAccountMidFlight {
            await onSignInAccountMidFlight(accountRef)
        }
        let summary = storedAccounts.first(where: { $0.label == accountRef })
        return summary
            ?? AccountSummaryFfi(
                label: accountRef,
                accountIdHex: accountRef,
                localSigning: true,
                externalSigning: false,
                signedOut: false,
                running: true
            )
    }

    func revealNsec(accountRef: String) throws -> String {
        revealNsecCallCount += 1
        return "nsec1fake"
    }

    func exportEncryptedSecretKey(accountRef: String, passphrase: String) throws -> String {
        exportEncryptedSecretKeyCallCount += 1
        return "ncryptsec1fake"
    }

    func deleteGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool {
        deleteGroupLocalCallCount += 1
        locallyDeletedGroupIds.append(groupIdHex)
        guard let index = groups.firstIndex(where: { $0.groupIdHex == groupIdHex }) else { return false }
        groups.remove(at: index)
        groupDetailsById[groupIdHex] = nil
        groupManagementStateById[groupIdHex] = nil
        return true
    }

    func updateMessageRetention(accountRef: String, groupIdHex: String, disappearingMessageSecs: UInt64) async throws
        -> SendSummaryFfi
    {
        updateMessageRetentionCallCount += 1
        await groupMutationGate.passIfArmed()
        lastRetentionSecs = disappearingMessageSecs
        return SendSummaryFfi(published: 1, messageIds: ["retention"])
    }

    func secureDeleteExpired(accountRef: String, groupIdHex: String) async throws -> SecureDeleteExpiredResultFfi {
        secureDeleteExpiredCallCount += 1
        await secureDeleteExpiredGate.passIfArmed()
        return SecureDeleteExpiredResultFfi(
            prunedMessages: 0,
            secretsDeleted: 0,
            mediaCiphertextSha256: [],
            erasurePending: false
        )
    }

    func sweepExpiredRetention(accountRef: String, nowMs: UInt64) async throws -> RetentionSweepReportFfi {
        sweepExpiredRetentionCallCount += 1
        return RetentionSweepReportFfi(groups: [])
    }

    func setChatManuallyUnread(accountRef: String, groupIdHex: String, manuallyUnread: Bool) throws -> ChatListRowFfi? {
        setChatManuallyUnreadCallCount += 1
        lastManuallyUnreadValue = manuallyUnread
        return nil
    }

    func chatNotificationSettings(accountRef: String, groupIdHex: String) throws -> ChatNotificationSettingsFfi {
        ChatNotificationSettingsFfi(
            accountRef: accountRef,
            accountIdHex: accountRef,
            groupIdHex: groupIdHex,
            muted: false,
            mutedUntilMs: nil,
            updatedAtMs: 0
        )
    }

    func setChatMuted(accountRef: String, groupIdHex: String, mutedUntilMs: Int64?) throws
        -> ChatNotificationSettingsFfi
    {
        setChatMutedCallCount += 1
        lastMutedUntilMs = mutedUntilMs
        return ChatNotificationSettingsFfi(
            accountRef: accountRef,
            accountIdHex: accountRef,
            groupIdHex: groupIdHex,
            muted: true,
            mutedUntilMs: mutedUntilMs,
            updatedAtMs: 0
        )
    }

    func clearChatMuted(accountRef: String, groupIdHex: String) throws -> ChatNotificationSettingsFfi {
        clearChatMutedCallCount += 1
        return ChatNotificationSettingsFfi(
            accountRef: accountRef,
            accountIdHex: accountRef,
            groupIdHex: groupIdHex,
            muted: false,
            mutedUntilMs: nil,
            updatedAtMs: 0
        )
    }

    func recordHostPerformance(
        operation: HostPerformanceOperationFfi,
        durationMs: UInt64,
        outcome: HostPerformanceOutcomeFfi
    ) {
        recordedHostPerformance.append((operation, durationMs, outcome))
    }

    func releaseSecureDeleteExpiredGate() {
        secureDeleteExpiredGate.release()
    }

    private func chatListRow(for group: AppGroupRecordFfi) -> ChatListRowFfi {
        let latest = timelinePagesByGroupId[group.groupIdHex]?.messages.last(where: { $0.kind == 9 })
        return ChatListRowFfi(
            groupIdHex: group.groupIdHex,
            archived: group.archived,
            pendingConfirmation: group.pendingConfirmation,
            title: group.name.isEmpty ? DisplayText.short(group.groupIdHex) : group.name,
            groupName: group.name,
            avatarUrl: group.avatarUrl,
            avatar: group.imageHashHex.map {
                ChatListAvatarFfi(
                    imageHashHex: $0,
                    imageKeyHex: "key",
                    imageNonceHex: "nonce",
                    imageUploadKeyHex: "upload-key",
                    mediaType: "image/jpeg"
                )
            },
            lastMessage: latest.map { message in
                ChatListMessagePreviewFfi(
                    messageIdHex: message.messageIdHex,
                    sender: message.sender,
                    senderDisplayName: displayName(accountIdHex: message.sender),
                    plaintext: message.plaintext,
                    contentTokens: message.contentTokens,
                    kind: message.kind,
                    timelineAt: message.timelineAt,
                    deleted: message.deleted
                )
            },
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: latest?.timelineAt,
            updatedAt: latest?.timelineAt ?? 0,
            selfMembership: group.selfMembership,
            leaveRequestPending: pendingLeaveGroupIds.contains(group.groupIdHex)
        )
    }
}

enum FakeMarmotRuntimeError: Error, LocalizedError {
    case missingCreatedAccount
    case auditLogDeleteFailed
    case observabilityConfigurationFailed
    case mediaUploadFailed
    case followListReadFailed
    case profilePublishFailed
    case nativePushWriteFailed
    case unused

    var errorDescription: String? {
        switch self {
        case .profilePublishFailed:
            return "Profile publish failed."
        case .missingCreatedAccount:
            return "Missing created account."
        case .auditLogDeleteFailed:
            return "Audit log delete failed."
        case .observabilityConfigurationFailed:
            return "Observability configuration failed."
        case .mediaUploadFailed:
            return "Media upload failed."
        case .followListReadFailed:
            return "Follow list read failed."
        case .nativePushWriteFailed:
            return "Native push write failed."
        case .unused:
            return "Unused fake runtime error."
        }
    }
}

struct SentReply: Equatable {
    let groupIdHex: String
    let targetMessageId: String
    let text: String
}

struct FollowMutationCall: Equatable {
    let accountRef: String
    let userRef: String
    let isFollow: Bool
}

struct SentText: Equatable {
    let groupIdHex: String
    let text: String
}

struct UploadedMedia: Equatable {
    let groupIdHex: String
    let request: MediaUploadRequestFfi
}

struct SentMediaAttachments: Equatable {
    let groupIdHex: String
    let attachments: [MediaAttachmentReferenceFfi]
    let caption: String?

    var fileNames: [String] { attachments.map(\.fileName) }
}

/// Non-blocking release gate keyed by attachment file name, so a test can let uploads finish in a
/// chosen order (the composer must still publish them in composer order). Unlike `BlockingFfiGate`
/// this suspends rather than parking a cooperative thread, which matters when several stage-time
/// uploads are in flight at once.
actor UploadReleaseGate {
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var held: Set<String> = []

    func hold(_ fileNames: String...) {
        held.formUnion(fileNames)
    }

    func waitIfHeld(_ fileName: String) async {
        guard held.contains(fileName) else { return }
        await withCheckedContinuation { waiters[fileName] = $0 }
    }

    func release(_ fileName: String) {
        held.remove(fileName)
        waiters.removeValue(forKey: fileName)?.resume()
    }
}

struct SentReaction: Equatable {
    let groupIdHex: String
    let targetMessageId: String
    let emoji: String
}

struct DeletedMessage: Equatable {
    let groupIdHex: String
    let targetMessageId: String
}

struct EditedMessage: Equatable {
    let groupIdHex: String
    let targetMessageId: String
    let content: String
}

struct UpdatedGroupAvatar: Equatable {
    let groupIdHex: String
    let url: String?
    let dim: String?
    let thumbhash: String?
}

struct UpdatedGroupProfile: Equatable {
    let groupIdHex: String
    let name: String?
    let description: String?
}

struct ArchivedGroup: Equatable {
    let groupIdHex: String
    let archived: Bool
}
