import AVFoundation
import AppKit
import Combine
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

private func uniquedLastWins<Value, Key: Hashable>(
    _ values: [Value],
    by key: (Value) -> Key
) -> [Value] {
    var seenKeys = Set<Key>()
    var result: [Value] = []
    result.reserveCapacity(values.count)

    for value in values.reversed() {
        guard seenKeys.insert(key(value)).inserted else { continue }
        result.append(value)
    }

    return Array(result.reversed())
}

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

private nonisolated final class OffMainCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
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

    static func sorted(_ chatItems: [ChatItem], pinnedChatIds: Set<String> = []) -> [ChatItem] {
        chatItems.sorted { lhs, rhs in
            areInDisplayOrder(lhs, rhs, pinnedChatIds: pinnedChatIds)
        }
    }

    static func upserting(
        _ chat: ChatItem,
        into chats: [ChatItem],
        pinnedChatIds: Set<String> = []
    ) -> [ChatItem] {
        upsertResult(
            chat,
            into: chats,
            existingIndex: chats.firstIndex(where: { $0.id == chat.id }),
            pinnedChatIds: pinnedChatIds
        ).chats
    }

    static func upserting(
        _ chat: ChatItem,
        into chats: [ChatItem],
        existingIndex: Int?,
        pinnedChatIds: Set<String> = []
    ) -> [ChatItem] {
        upsertResult(chat, into: chats, existingIndex: existingIndex, pinnedChatIds: pinnedChatIds).chats
    }

    static func upsertResult(
        _ chat: ChatItem,
        into chats: [ChatItem],
        existingIndex: Int?,
        pinnedChatIds: Set<String> = []
    ) -> UpsertResult {
        var result = chats
        if let index = existingIndex {
            if canReplaceInPlace(chat, at: index, in: result, pinnedChatIds: pinnedChatIds) {
                result[index] = chat
                return UpsertResult(chats: result, reindexStart: nil)
            }
            result.remove(at: index)
            let nextIndex = insertionIndex(for: chat, in: result, pinnedChatIds: pinnedChatIds)
            result.insert(chat, at: nextIndex)
            return UpsertResult(chats: result, reindexStart: min(index, nextIndex))
        }

        let nextIndex = insertionIndex(for: chat, in: result, pinnedChatIds: pinnedChatIds)
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
            groupImagePayload: current.groupImagePayload,
            groupImageHashHex: current.groupImageHashHex,
            unreadCount: chat.unreadCount,
            hasUnread: chat.hasUnread,
            manuallyMarkedUnread: chat.manuallyMarkedUnread,
            unreadMentionCount: chat.unreadMentionCount,
            isDirect: chat.hasAuthoritativeConversationKind ? chat.isDirect : current.isDirect,
            hasAuthoritativeConversationKind: chat.hasAuthoritativeConversationKind,
            muted: chat.muted,
            mutedUntilMs: chat.mutedUntilMs,
            leaveRequestPending: chat.leaveRequestPending,
            latestMessageDelivery: chat.latestMessageDelivery,
            pendingConfirmation: chat.pendingConfirmation,
            selfMembership: chat.selfMembership
        )
    }

    static func isOlder(_ candidate: ChatItem, than current: ChatItem) -> Bool {
        guard let currentUpdatedAt = current.updatedAt else { return false }
        guard let candidateUpdatedAt = candidate.updatedAt else { return true }
        return candidateUpdatedAt < currentUpdatedAt
    }

    private static func canReplaceInPlace(
        _ chat: ChatItem,
        at index: Int,
        in chats: [ChatItem],
        pinnedChatIds: Set<String>
    ) -> Bool {
        let previousStillBefore =
            index == chats.startIndex
            || !areInDisplayOrder(chat, chats[index - 1], pinnedChatIds: pinnedChatIds)
        let nextStillAfter: Bool
        if index == chats.index(before: chats.endIndex) {
            nextStillAfter = true
        } else {
            nextStillAfter = !areInDisplayOrder(chats[index + 1], chat, pinnedChatIds: pinnedChatIds)
        }
        return previousStillBefore && nextStillAfter
    }

    private static func insertionIndex(
        for chat: ChatItem,
        in chats: [ChatItem],
        pinnedChatIds: Set<String>
    ) -> Int {
        var lowerBound = chats.startIndex
        var upperBound = chats.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if areInDisplayOrder(chats[middle], chat, pinnedChatIds: pinnedChatIds) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func areInDisplayOrder(
        _ lhs: ChatItem,
        _ rhs: ChatItem,
        pinnedChatIds: Set<String> = []
    ) -> Bool {
        let lhsPinned = pinnedChatIds.contains(lhs.id)
        let rhsPinned = pinnedChatIds.contains(rhs.id)
        if lhsPinned != rhsPinned { return lhsPinned }

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
        let didRemoveMessages: Bool
        let didTrimOlderMessages: Bool
        let didChangeMediaAttachments: Bool
    }

    private(set) var messages: [MessageItem]
    private(set) var messageIDs: [String]
    /// Day-grouped rendering projection. Rebuilt only when the materialized message window or
    /// its day/locale context changes, never from an unrelated `ConversationView.body` pass.
    private(set) var displayItems: [TimelineMessageDisplayItem]
    @ObservationIgnored private var displayReferenceDate: Date
    @ObservationIgnored private var displayCalendar: Calendar
    @ObservationIgnored private var displayLocale: Locale
    /// O(1) id → message map for non-UI lookups (`timelineMessage(groupIdHex:messageId:)`).
    /// `@ObservationIgnored`: it is never read from a view body — only `messages`/`messageIDs`
    /// drive rendering — so it must not enlarge a view's observation set. The store owns this
    /// (and `messageIDs`) so callers don't maintain parallel per-chat dictionaries.
    @ObservationIgnored private(set) var lookup: [String: MessageItem]
    @ObservationIgnored private var indexById: [String: Int]
    /// Unedited chat targets keyed by message id. Rendered rows in `messages`/`lookup` are derived
    /// from these bases plus the newest valid kind-1009 candidate per materialized target.
    @ObservationIgnored private var baseMessagesById: [String: MessageItem] = [:]
    /// Active kind-1009 edit candidates keyed by edit-event id. Retained across trim and
    /// authoritative window replaces that omit edit records; bounded by `windowLimit`.
    @ObservationIgnored private var editCandidatesById: [String: MessageEditOverlay] = [:]
    /// The same candidates grouped by target id, rebuilt whenever the canonical id map changes.
    /// Rendering a full window therefore visits only each row's candidates instead of rescanning
    /// every retained edit for every row.
    @ObservationIgnored private var editCandidatesByTargetId: [String: [MessageEditOverlay]] = [:]
    /// Candidates inspected by the most recent full render pass. Diagnostic / test helper.
    @ObservationIgnored private(set) var lastRenderEditCandidateVisitCount = 0
    /// Earliest sort key of a media-changing upsert suppressed from a detached window.
    /// Consumed when an authoritative replace first retains media at/after this key.
    @ObservationIgnored private var pendingSuppressedMediaSortKey: TimelineSortKey?
    private(set) var isLoaded: Bool

    init(
        messages: [MessageItem] = [],
        isLoaded: Bool = false,
        displayReferenceDate: Date = Date(),
        displayCalendar: Calendar = .autoupdatingCurrent,
        displayLocale: Locale = AppLanguage.currentLocale
    ) {
        let messages = Self.deduplicatedMessages(messages)
        self.messages = messages
        self.messageIDs = messages.map(\.id)
        self.displayItems = TimelineMessageDisplayItem.make(
            from: messages,
            now: displayReferenceDate,
            calendar: displayCalendar,
            locale: displayLocale
        )
        self.displayReferenceDate = displayReferenceDate
        self.displayCalendar = displayCalendar
        self.displayLocale = displayLocale
        self.lookup = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        self.indexById = Dictionary(
            messages.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, new in new }
        )
        self.baseMessagesById = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        self.isLoaded = isLoaded
        #if DEBUG
            displayItemsBuildCount = 1
        #endif
    }

    private static func deduplicatedMessages(_ messages: [MessageItem]) -> [MessageItem] {
        uniquedLastWins(messages, by: \.id)
    }

    static func loaded(with messages: [MessageItem]) -> MessageTimelineStore {
        MessageTimelineStore(messages: messages, isLoaded: true)
    }

    @discardableResult
    func replace(
        with messages: [MessageItem],
        editMutations: [MessageEditMutation] = [],
        windowLimit: Int? = nil
    ) -> Bool {
        let priorLookup = lookup
        let bases = Self.deduplicatedMessages(messages)
        self.messages = bases
        baseMessagesById = Dictionary(bases.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        rebuildIndexes()
        // An authoritative replace swaps every base at once, so every row is dirty by
        // definition — unlike `applyProjection`, the full pass is the correct one here.
        _ = applyEditMutations(editMutations)
        _ = pruneInvalidSenderCandidatesForMaterializedTargets()
        _ = pruneEditCandidates(windowLimit: windowLimit ?? max(bases.count, 1))
        _ = recomputeAllRenderedMessages()
        rebuildDisplayItems()
        self.isLoaded = true
        return consumeMediaAttachmentInvalidation(afterAuthoritativeReplace: bases, priorLookup: priorLookup)
    }

    func clear() {
        messages = []
        messageIDs = []
        displayItems = []
        lookup = [:]
        indexById = [:]
        baseMessagesById = [:]
        replaceEditCandidates(with: [:])
        pendingSuppressedMediaSortKey = nil
        isLoaded = false
    }

    func containsMessage(id: String) -> Bool {
        lookup[id] != nil
    }

    func applyProjection(
        upserts: [MessageItem],
        removals removalIds: Set<String>,
        editMutations: [MessageEditMutation] = [],
        anchoredToNewest: Bool,
        windowLimit: Int
    ) -> ProjectionApplyResult {
        var didChange = false
        var didRemoveMessages = false

        // Compare media-relevant upserts with the final lookup after trimming so suppressed or
        // immediately-evicted rows do not trigger cache invalidation.
        var mediaAttachmentsBeforeUpserts: [String: [MessageMediaAttachment]] = [:]
        for item in upserts {
            guard mediaAttachmentsBeforeUpserts[item.id] == nil else { continue }
            let previous = lookup[item.id]?.mediaAttachments ?? []
            guard !previous.isEmpty || !item.mediaAttachments.isEmpty else { continue }
            mediaAttachmentsBeforeUpserts[item.id] = previous
        }

        // Rows whose rendered value may have changed. A rendered row is a pure function of its
        // base in `baseMessagesById` plus the edit candidates targeting its id, so the set is
        // closed over exactly those inputs: the upserted ids, plus every target whose candidate
        // set was mutated (by an explicit mutation or by one of the prunes below). Recomputing
        // only these keeps a delta O(changed rows) instead of O(window) — a send emits a burst of
        // delivery-state projections, and re-rendering all 200 rows per tick was the dominant
        // steady-state cost.
        var dirtyMessageIds = Set(upserts.map(\.id))

        if !removalIds.isEmpty {
            let originalCount = messages.count
            let removedMessageIds = Set(messages.filter { removalIds.contains($0.id) }.map(\.id))
            messages.removeAll { removalIds.contains($0.id) }
            didRemoveMessages = messages.count != originalCount
            for removedId in removedMessageIds {
                baseMessagesById.removeValue(forKey: removedId)
            }
            dirtyMessageIds.formUnion(purgeEditCandidates(forRemovalIds: removalIds))
            if didRemoveMessages {
                didChange = true
                rebuildIndexes()
            }
        }

        // Recompute the head *after* removals: a delta that drops the current newest row lowers
        // the detached window's real head, and an upsert newer than that post-removal head must
        // not grow a new head into a scrolled-back window.
        let newestKey = messages.last.map(TimelineSortKey.init)

        for item in upserts {
            if let existingIndex = indexById[item.id] {
                baseMessagesById[item.id] = item
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
            baseMessagesById[item.id] = item
            insertMessage(item, at: insertionIndex(for: item))
            didChange = true
        }

        dirtyMessageIds.formUnion(applyEditMutations(editMutations))

        var didTrimOlderMessages = false
        if messages.count > windowLimit {
            trimOldestMessages(count: messages.count - windowLimit)
            didTrimOlderMessages = true
            didChange = true
        }

        dirtyMessageIds.formUnion(pruneInvalidSenderCandidatesForMaterializedTargets())
        dirtyMessageIds.formUnion(pruneEditCandidates(windowLimit: windowLimit))
        if recomputeRenderedMessages(ids: dirtyMessageIds) {
            didChange = true
        }

        if didChange {
            rebuildDisplayItems()
            isLoaded = true
        }
        let didChangeMediaAttachments = mediaAttachmentsBeforeUpserts.contains { id, previous in
            guard let retained = lookup[id] else { return false }
            return previous != retained.mediaAttachments
        }
        if didChangeMediaAttachments {
            pendingSuppressedMediaSortKey = nil
        } else {
            for item in upserts {
                guard let previous = mediaAttachmentsBeforeUpserts[item.id] else { continue }
                guard lookup[item.id] == nil else { continue }
                guard !previous.isEmpty || !item.mediaAttachments.isEmpty else { continue }
                guard previous != item.mediaAttachments else { continue }
                recordPendingSuppressedMediaSortKey(for: item)
            }
        }
        return ProjectionApplyResult(
            didChange: didChange,
            didRemoveMessages: didRemoveMessages,
            didTrimOlderMessages: didTrimOlderMessages,
            didChangeMediaAttachments: didChangeMediaAttachments
        )
    }

    @discardableResult
    func relabelSender(accountIdHex: String, nickname: String?) -> Bool {
        var didChange = false
        for index in messages.indices {
            guard messages[index].senderAccountIdHex == accountIdHex,
                let relabeled = messages[index].applyingSenderNickname(nickname)
            else { continue }
            messages[index] = relabeled
            lookup[relabeled.id] = relabeled
            didChange = true
        }
        for (id, base) in baseMessagesById where base.senderAccountIdHex == accountIdHex {
            guard let relabeled = base.applyingSenderNickname(nickname) else { continue }
            baseMessagesById[id] = relabeled
            didChange = true
        }
        if relabelReplyQuotes(ofSender: accountIdHex) {
            didChange = true
        }
        guard didChange else { return false }
        rebuildDisplayItems()
        return true
    }

    private func relabelReplyQuotes(ofSender accountIdHex: String) -> Bool {
        var didChange = false
        for index in messages.indices {
            guard let targetId = messages[index].replyContext?.targetMessageId,
                let target = lookup[targetId],
                target.senderAccountIdHex == accountIdHex,
                let relabeled = messages[index].applyingReplyContextSenderName(target.senderName)
            else { continue }
            messages[index] = relabeled
            lookup[relabeled.id] = relabeled
            didChange = true
        }
        for (id, base) in baseMessagesById {
            guard let targetId = base.replyContext?.targetMessageId,
                let target = lookup[targetId],
                target.senderAccountIdHex == accountIdHex,
                let relabeled = base.applyingReplyContextSenderName(target.senderName)
            else { continue }
            baseMessagesById[id] = relabeled
            didChange = true
        }
        return didChange
    }

    /// Refreshes date-sensitive day labels after a calendar rollover or locale change. Calls made
    /// repeatedly within the same calendar day and locale are intentionally O(1).
    func refreshDisplayItems(
        referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = AppLanguage.currentLocale
    ) {
        let dayChanged = !calendar.isDate(displayReferenceDate, inSameDayAs: referenceDate)
        guard dayChanged || displayCalendar != calendar || displayLocale != locale else { return }

        displayReferenceDate = referenceDate
        displayCalendar = calendar
        displayLocale = locale
        rebuildDisplayItems()
    }

    private func rebuildDisplayItems() {
        displayItems = TimelineMessageDisplayItem.make(
            from: messages,
            now: displayReferenceDate,
            calendar: displayCalendar,
            locale: displayLocale
        )
        #if DEBUG
            displayItemsBuildCount += 1
        #endif
    }

    #if DEBUG
        /// Test-only instrumentation proving unrelated view reads do not re-derive day grouping.
        @ObservationIgnored private(set) var displayItemsBuildCount = 0
    #endif

    /// Applies edit-candidate mutations and returns every target id whose candidate set changed.
    /// A `.retract` must resolve its target *before* the candidate is dropped, otherwise the
    /// affected row would never be re-rendered when its id is not also in the delta's upserts.
    private func applyEditMutations(_ mutations: [MessageEditMutation]) -> Set<String> {
        guard !mutations.isEmpty else { return [] }
        var touchedTargetIds: Set<String> = []
        for mutation in mutations {
            switch mutation {
            case .upsert(let overlay):
                editCandidatesById[overlay.editMessageIdHex] = overlay
                touchedTargetIds.insert(overlay.targetMessageIdHex)
            case .retract(let editMessageIdHex):
                guard let removed = editCandidatesById.removeValue(forKey: editMessageIdHex) else { continue }
                touchedTargetIds.insert(removed.targetMessageIdHex)
            }
        }
        rebuildEditCandidateTargetIndex()
        return touchedTargetIds
    }

    @discardableResult
    private func recomputeAllRenderedMessages() -> Bool {
        recomputeRenderedMessages(indices: messages.indices)
    }

    /// Re-renders only the materialized rows named by `ids`. Ids that are not in the window
    /// (suppressed upserts, edits whose target has not been paged in) are skipped.
    @discardableResult
    private func recomputeRenderedMessages(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else {
            lastRenderEditCandidateVisitCount = 0
            return false
        }
        return recomputeRenderedMessages(indices: ids.compactMap { indexById[$0] })
    }

    private func recomputeRenderedMessages(indices: some Sequence<Int>) -> Bool {
        var didChange = false
        var candidateVisitCount = 0
        for index in indices {
            let messageId = messages[index].id
            guard let base = baseMessagesById[messageId] else { continue }
            let renderResult = renderedMessage(from: base)
            candidateVisitCount += renderResult.candidateVisitCount
            let rendered = renderResult.message
            guard messages[index] != rendered else { continue }
            messages[index] = rendered
            lookup[messageId] = rendered
            didChange = true
        }
        lastRenderEditCandidateVisitCount = candidateVisitCount
        return didChange
    }

    private func renderedMessage(from base: MessageItem) -> (message: MessageItem, candidateVisitCount: Int) {
        let result = effectiveEdit(for: base.id, base: base)
        guard let edit = result.edit else { return (base, result.candidateVisitCount) }
        return (base.applyingEdit(plaintext: edit.plaintext), result.candidateVisitCount)
    }

    private func effectiveEdit(
        for targetId: String,
        base: MessageItem
    ) -> (edit: MessageEditOverlay?, candidateVisitCount: Int) {
        guard isValidEditTarget(base, editSender: base.senderAccountIdHex),
            let candidates = editCandidatesByTargetId[targetId]
        else { return (nil, 0) }
        var winner: MessageEditOverlay?
        var candidateVisitCount = 0
        for candidate in candidates {
            candidateVisitCount += 1
            guard candidate.sender == base.senderAccountIdHex else { continue }
            if MessageEditOverlay.shouldPrefer(candidate, over: winner) {
                winner = candidate
            }
        }
        return (winner, candidateVisitCount)
    }

    /// The ordered edit history for `targetId` — oldest first: the original, then each accepted
    /// edit by the target's own author. Empty when the message was never edited.
    func editHistory(forTarget targetId: String) -> [MessageEditVersion] {
        guard let base = baseMessagesById[targetId],
            isValidEditTarget(base, editSender: base.senderAccountIdHex)
        else { return [] }
        let edits = (editCandidatesByTargetId[targetId] ?? [])
            .filter { $0.sender == base.senderAccountIdHex }
            .sorted { MessageEditOverlay.shouldPrefer($1, over: $0) }
        guard !edits.isEmpty else { return [] }
        var versions = [
            MessageEditVersion(
                id: base.id,
                text: MentionDisplayResolver.resolve(in: base.wireBody, mentionNames: base.mentionNames),
                date: Date(timeIntervalSince1970: TimeInterval(base.timelineAt)),
                isOriginal: true
            )
        ]
        versions += edits.map { edit in
            MessageEditVersion(
                id: edit.editMessageIdHex,
                text: MentionDisplayResolver.resolve(in: edit.plaintext, mentionNames: base.mentionNames),
                date: Date(timeIntervalSince1970: TimeInterval(edit.timelineAt)),
                isOriginal: false
            )
        }
        return versions
    }

    private func purgeEditCandidates(forRemovalIds removalIds: Set<String>) -> Set<String> {
        guard !removalIds.isEmpty, !editCandidatesById.isEmpty else { return [] }
        return replaceEditCandidates(
            with: editCandidatesById.filter { _, candidate in
                !removalIds.contains(candidate.editMessageIdHex)
                    && !removalIds.contains(candidate.targetMessageIdHex)
            }
        )
    }

    private func pruneInvalidSenderCandidatesForMaterializedTargets() -> Set<String> {
        guard !editCandidatesById.isEmpty else { return [] }
        return replaceEditCandidates(
            with: editCandidatesById.filter { _, candidate in
                guard let base = baseMessagesById[candidate.targetMessageIdHex] else { return true }
                return candidate.sender == base.senderAccountIdHex
            }
        )
    }

    private func pruneEditCandidates(windowLimit limit: Int) -> Set<String> {
        guard limit > 0, editCandidatesById.count > limit else { return [] }

        typealias CandidateEntry = (key: String, value: MessageEditOverlay)

        func sortNewestFirst(_ lhs: CandidateEntry, _ rhs: CandidateEntry) -> Bool {
            if lhs.value.timelineAt != rhs.value.timelineAt {
                return lhs.value.timelineAt > rhs.value.timelineAt
            }
            return lhs.value.editMessageIdHex > rhs.value.editMessageIdHex
        }

        // Preserve the current winner for each visible target. For unresolved targets,
        // also preserve one representative per target/sender pair before using spare
        // capacity for history. Repeated forged edits from one peer therefore cannot
        // evict a pending candidate from the target's actual author.
        var materializedWinnerIds = Set<String>()
        for (targetId, base) in baseMessagesById {
            if let winner = effectiveEdit(for: targetId, base: base).edit {
                materializedWinnerIds.insert(winner.editMessageIdHex)
            }
        }

        var pendingRepresentativesByTarget = [String: [String: MessageEditOverlay]]()
        for candidate in editCandidatesById.values where baseMessagesById[candidate.targetMessageIdHex] == nil {
            let existing = pendingRepresentativesByTarget[candidate.targetMessageIdHex]?[candidate.sender]
            if MessageEditOverlay.shouldPrefer(candidate, over: existing) {
                pendingRepresentativesByTarget[candidate.targetMessageIdHex, default: [:]][candidate.sender] = candidate
            }
        }
        let pendingRepresentativeIds = Set(
            pendingRepresentativesByTarget.values
                .flatMap(\.values)
                .map(\.editMessageIdHex)
        )

        let materializedWinners =
            editCandidatesById
            .filter { materializedWinnerIds.contains($0.key) }
            .sorted(by: sortNewestFirst)
            .prefix(limit)
        var kept = Dictionary(
            uniqueKeysWithValues: materializedWinners.map { ($0.key, $0.value) }
        )

        let pendingSlots = limit - kept.count
        if pendingSlots > 0 {
            let pendingRepresentatives =
                editCandidatesById
                .filter { pendingRepresentativeIds.contains($0.key) }
                .sorted(by: sortNewestFirst)
                .prefix(pendingSlots)
            for candidate in pendingRepresentatives {
                kept[candidate.key] = candidate.value
            }
        }

        let remainingSlots = limit - kept.count
        if remainingSlots > 0 {
            let remaining =
                editCandidatesById
                .filter { kept[$0.key] == nil }
                .sorted(by: sortNewestFirst)
                .prefix(remainingSlots)
            for candidate in remaining {
                kept[candidate.key] = candidate.value
            }
        }
        return replaceEditCandidates(with: kept)
    }

    /// Swaps the retained candidate set and returns every target id that gained or lost a
    /// candidate, so callers can widen the re-render set to rows the delta never mentioned.
    @discardableResult
    private func replaceEditCandidates(with candidates: [String: MessageEditOverlay]) -> Set<String> {
        var touchedTargetIds: Set<String> = []
        for (editMessageIdHex, candidate) in editCandidatesById where candidates[editMessageIdHex] == nil {
            touchedTargetIds.insert(candidate.targetMessageIdHex)
        }
        for (editMessageIdHex, candidate) in candidates where editCandidatesById[editMessageIdHex] == nil {
            touchedTargetIds.insert(candidate.targetMessageIdHex)
        }
        editCandidatesById = candidates
        rebuildEditCandidateTargetIndex()
        return touchedTargetIds
    }

    private func rebuildEditCandidateTargetIndex() {
        editCandidatesByTargetId = Dictionary(
            grouping: editCandidatesById.values,
            by: { $0.targetMessageIdHex }
        )
    }

    private func isValidEditTarget(_ message: MessageItem, editSender: String) -> Bool {
        message.timelineKind == 9
            && message.presentation == .chat
            && message.senderAccountIdHex == editSender
            && !message.isDeleted
            && message.invalidationStatus == nil
    }

    private func rebuildIndexes() {
        messages = Self.deduplicatedMessages(messages)
        messageIDs = messages.map(\.id)
        lookup = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        indexById = Dictionary(
            messages.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, new in new }
        )
    }

    private func trimOldestMessages(count trimCount: Int) {
        guard trimCount > 0 else { return }
        let trimmedIDs = messages.prefix(trimCount).map(\.id)
        messages.removeFirst(trimCount)
        messageIDs.removeFirst(trimCount)
        for id in trimmedIDs {
            lookup[id] = nil
            indexById[id] = nil
            baseMessagesById.removeValue(forKey: id)
        }
        reindexMessages(startingAt: 0)
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

    private func recordPendingSuppressedMediaSortKey(for item: MessageItem) {
        guard !item.mediaAttachments.isEmpty else { return }
        let key = TimelineSortKey(item)
        if let existing = pendingSuppressedMediaSortKey, key >= existing {
            return
        }
        pendingSuppressedMediaSortKey = key
    }

    private func consumeMediaAttachmentInvalidation(
        afterAuthoritativeReplace bases: [MessageItem],
        priorLookup: [String: MessageItem]
    ) -> Bool {
        let didChangeMediaAttachments = bases.contains { item in
            guard let previous = priorLookup[item.id] else { return false }
            let previousAttachments = previous.mediaAttachments
            let nextAttachments = item.mediaAttachments
            guard !previousAttachments.isEmpty || !nextAttachments.isEmpty else { return false }
            return previousAttachments != nextAttachments
        }
        if didChangeMediaAttachments {
            pendingSuppressedMediaSortKey = nil
            return true
        }
        guard let watermark = pendingSuppressedMediaSortKey else { return false }
        guard
            bases.contains(where: { item in
                !item.mediaAttachments.isEmpty && TimelineSortKey(item) >= watermark
            })
        else {
            return false
        }
        pendingSuppressedMediaSortKey = nil
        return true
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
    /// Observed invalidation token for `selectedChat`, whose actual lookup stays in the
    /// ignored O(1) indexes below. Live chat-list deltas mutate those indexes, so the selected
    /// conversation needs this tracked scalar to re-read fresh metadata without subscribing to
    /// the whole chat dictionary. It is intentionally coarse: any active-account chat-list
    /// mutation invalidates the selected conversation chrome, while transcript reads remain
    /// scoped through per-chat timeline stores.
    var selectedChatRevision = 0
    var archivedChatsByAccount: [String: [ChatItem]] = [:]
    var pinnedChatIdsByAccount: [String: Set<String>] = [:]
    @ObservationIgnored var chatLookupByAccount: [String: [String: ChatItem]] = [:]
    @ObservationIgnored var chatIndexByAccount: [String: [String: Int]] = [:]
    @ObservationIgnored var chatListGenerationByAccount: [String: Int] = [:]
    @ObservationIgnored var filteredChatsCache: FilteredChatsCache?
    @ObservationIgnored var archivedChatLookupByAccount: [String: [String: ChatItem]] = [:]
    @ObservationIgnored var archivedChatIndexByAccount: [String: [String: Int]] = [:]
    @ObservationIgnored var archivedChatListGenerationByAccount: [String: Int] = [:]
    @ObservationIgnored var filteredArchivedChatsCache: FilteredChatsCache?
    /// Ids of the chats whose transcript window is currently cached in `messageTimelineStores`.
    /// The message arrays themselves live only on the stores; tracking membership in a small set
    /// (rather than a parallel `[String: [MessageItem]]`) avoids copying the open conversation's
    /// window on every timeline delta while preserving the cached/not-cached distinction the
    /// prune and reseed paths rely on.
    @ObservationIgnored var cachedMessageChatIds: Set<String> = []
    @ObservationIgnored var messageTimelineStores: [String: MessageTimelineStore] = [:]
    /// Group ids in least-recently-rendered order (most recent last), bounding
    /// `messageTimelineStores` to `timelineStoreCacheLimit`. Retaining the last few rendered
    /// windows means returning to a recent conversation paints from cache instead of showing
    /// the initial-load spinner while the fresh subscription snapshot is fetched and re-mapped.
    @ObservationIgnored var timelineStoreRecency: [String] = []

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
    @ObservationIgnored var hiddenMessageStore: (any HiddenMessageStoring)?
    @ObservationIgnored var pinnedChatStore: (any PinnedChatStoring)?
    @ObservationIgnored var contactNicknameStore: (any ContactNicknameStoring)?
    var contactNicknamesByOwner: [String: [String: String]] = [:]
    @ObservationIgnored var contactNicknameRevision: UInt64 = 0
    @ObservationIgnored var cachedContactNicknames: CachedContactNicknames?
    @ObservationIgnored let chatRestorationStore: any ChatRestorationStoring
    @ObservationIgnored var shouldResolveStartupChatSelection = true
    @ObservationIgnored let quickReactionStore: any QuickReactionStoring
    @ObservationIgnored var mediaReferenceIndexes: [MediaReferenceCacheKey: MediaReferenceIndex] = [:]
    @ObservationIgnored var mediaReferenceIndexTasks: [MediaReferenceCacheKey: MediaReferenceIndexTask] = [:]
    @ObservationIgnored var mediaReferenceIndexGeneration: UInt64 = 0
    @ObservationIgnored var mediaDiskStoreTasks: [String: MediaDiskStoreTask] = [:]
    @ObservationIgnored var mediaAttachmentDownloadTasks: [String: MediaAttachmentDownloadTask] = [:]
    @ObservationIgnored var nextMediaAttachmentDownloadTaskToken: UInt64 = 0
    @ObservationIgnored var isMediaDiskStoreGloballySuppressed = false
    @ObservationIgnored var mediaDiskStoreSuppressedAccountIds = Set<String>()
    @ObservationIgnored var mediaDiskStoreAccountGenerations: [String: UInt64] = [:]
    @ObservationIgnored var mediaDiskStoreGlobalGeneration: UInt64 = 0
    @ObservationIgnored var nextMediaDiskStoreTaskToken: UInt64 = 0
    var mediaCacheFootprint = MessageMediaDiskCacheFootprint.zero
    var isLoadingMediaCacheFootprint = false
    var isClearingMediaCache = false
    var mediaCacheReclaimedByteCount: UInt64?
    /// Invalidates views that hold decrypted media projections outside `mediaDownloads` (which is
    /// observation-ignored for timeline performance). A manual clear bumps this once so visible
    /// attachments rebuild against fresh state stores and shared-media thumbnails re-request data.
    var mediaCacheGeneration: UInt64 = 0
    @ObservationIgnored var mediaCacheFootprintRefreshGeneration: UInt64 = 0
    /// Error for the user-initiated action on the *current* screen. Rendered by form
    /// surfaces (login, settings, new-chat composer). Must never be written by
    /// background tasks — see `backgroundStatus`.
    var lastError: String?
    /// Status for failures originating in background tasks (subscription listeners,
    /// observability refresh, read-marking). These are not tied to anything the user
    /// just did, so they are surfaced on a non-modal global banner instead of the
    /// per-screen error view, preventing misattribution and clobbering of `lastError`.
    var backgroundStatus: String?

    /// Profile reference from a marmot:// deep link that arrived before the workspace
    /// reached `.ready` (cold start or signed out). Never read by a view body; flushed
    /// by `flushPendingDeepLinkIfReady()` from `activateReadyState()`.
    @ObservationIgnored var pendingDeepLinkProfileReference: String?

    var activeAccountId: String?
    var selection: WorkspaceSelection? {
        didSet {
            // A pending delete-confirmation or edit-history sheet belongs to the conversation it
            // was opened in; drop both when the selection changes so a stale dialog can't act on a
            // different chat.
            if oldValue != selection {
                messagePendingDeletion = nil
                messagePendingEditHistory = nil
            }
            dismissGroupImagePickerIfSelectedChatUnavailable()
            ensureSelectedMessageTimelineStore()
            persistSelectedChatForRestorationIfEnabled()
        }
    }
    var restoreLastSelectedChat: Bool
    var searchText = ""
    var sidebarMessageSearchResultsByGroupId: [String: GlobalMessageSearchResult] = [:]
    var sidebarMessageSearchResultQuery = ""
    var isSearchingSidebarMessages = false
    @ObservationIgnored var sidebarMessageSearchTask: Task<Void, Never>?
    @ObservationIgnored var sidebarMessageSearchGeneration: UInt64 = 0
    var isGlobalMessageSearchPresented = false
    var globalMessageSearchQuery = ""
    var globalMessageSearchResults: [GlobalMessageSearchResult] = []
    var isSearchingAllMessages = false
    var globalMessageSearchError: String?
    var pendingMessageNavigation: GlobalMessageNavigationTarget?
    @ObservationIgnored var globalMessageSearchTask: Task<Void, Never>?
    @ObservationIgnored var globalMessageSearchGeneration: UInt64 = 0
    var chatListFilter: ChatListFilter = .active
    var archivingChatId: String?
    var mutatingChatPreferenceIds: Set<String> = []
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
                composerMentionSelectionsByConversation[selectedComposerDraftKey] = nil
            } else {
                draftTextByConversation[selectedComposerDraftKey] = newValue
            }
            composerDraftDidChange(for: selectedComposerDraftKey)
        }
    }
    var composerMentionSelections: [ComposerMentionSelection] {
        get {
            guard let selectedComposerDraftKey else { return [] }
            return composerMentionSelectionsByConversation[selectedComposerDraftKey] ?? []
        }
        set {
            guard let selectedComposerDraftKey else { return }
            composerMentionSelectionsByConversation[selectedComposerDraftKey] = newValue.isEmpty ? nil : newValue
            composerDraftDidChange(for: selectedComposerDraftKey)
        }
    }
    var pendingMediaAttachments: [PendingMediaAttachment] {
        guard let selectedComposerDraftKey else { return [] }
        return pendingMediaAttachmentsByConversation[selectedComposerDraftKey] ?? []
    }
    var pendingMediaUploadStates: [PendingMediaAttachment.ID: PendingMediaUploadState] {
        guard let selectedComposerDraftKey else { return [:] }
        return pendingMediaUploadStatesByConversation[selectedComposerDraftKey] ?? [:]
    }
    var isRefreshing = false
    var isSending = false
    var isRecordingVoiceMessage = false
    /// Synchronous guard for the mic-permission await in `startVoiceRecording()` so a second
    /// tap cannot interleave and orphan a hot recorder (#391).
    var isPreparingVoiceRecording = false
    /// Bumped by `cancelVoiceRecording()` so an in-flight mic-permission await cannot resume
    /// and create a recorder after navigation tears down the composer (#441).
    var voiceRecordingPreparationGeneration: UInt64 = 0
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
    var quickReactions: [String]
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
    /// True while an account remove, sign-out, sign-in, or full local-data wipe is in flight.
    var isAccountMutationInProgress: Bool {
        isRemovingAccount || isSigningOutAccount || isDeletingAllData
    }
    /// Per-account unread totals keyed by `accountIdHex`, for switcher avatar badges.
    var accountUnreadByIdHex: [String: Int] = [:]
    var isSavingRelays = false
    var isPublishingKeyPackage = false
    var isRepublishingKeyPackage = false
    var isSavingNotifications = false
    var isSavingPrivacySecurity = false
    var isLoadingAuditLogFiles = false
    @ObservationIgnored var shouldReloadAuditLogFilesAfterCurrentLoad = false
    var isDeletingAuditLogFiles = false
    var isUploadingAuditLogFiles = false
    var isDeletingAllData = false
    var deletingKeyPackageId: String?
    var isNewChatComposerVisible = false
    var composePane: ComposePane = .newChat
    var composeContacts: [ComposeContact] = []
    var isLoadingComposeContacts = false
    /// Peer hex of the contact row whose direct chat is currently being created, so only
    /// that row shows a spinner.
    var creatingDirectChatIdHex: String?
    /// Disappearing-message timer chosen on the name-group panel. Not a `createGroup`
    /// parameter, so it is applied right after creation.
    var groupDraftRetentionSecs: UInt64 = 0
    @ObservationIgnored var composeContactsGeneration: UInt64 = 0
    /// People the web-of-trust search found for the current compose query. Deliberately separate
    /// from `composeContacts`: a search result is not a relationship, so nothing here is ever
    /// promoted into the contact directory or the profile cache
    /// (see WorkspaceState+UserDiscovery.swift).
    var discoveredPeople: [DiscoveredPerson] = []
    var isSearchingPeople = false
    /// A radius timed out or hit its candidate cap. Partial, not failed — results stay on screen.
    var discoveryIsPartial = false
    var discoveryDidFail = false
    @ObservationIgnored var discoveryGeneration: UInt64 = 0
    @ObservationIgnored var discoveryTask: Task<Void, Never>?
    /// The query `discoveredPeople` belongs to, so results are never rendered under a newer query.
    @ObservationIgnored var discoveryResultsQuery = ""
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
            composerDraftDidChange(for: selectedComposerDraftKey)
        }
    }
    var editingMessageContext: MessageEditContext? {
        guard let selectedComposerDraftKey else { return nil }
        return editingMessageContextByConversation[selectedComposerDraftKey]
    }
    var isResolvingNewChat = false
    var isCreatingChat = false
    var isRefreshingAccountProfiles = false
    var isGroupImagePickerPresented = false
    var groupImageSearchQuery = ""
    var groupImageResults: [GroupImageSearchResult] = []
    var isSearchingGroupImages = false
    var isSavingGroupImage = false
    var isProfileImagePickerPresented = false
    var profileImageSearchQuery = ""
    var profileImageResults: [GroupImageSearchResult] = []
    var isSearchingProfileImages = false
    var isUploadingProfileImage = false
    /// Decrypted group avatars are account/group/content-addressed. Chat items retain the payload
    /// they render; this lookup avoids a Blossom fetch on every chat-list enrichment pass.
    @ObservationIgnored var groupImagePayloadCache: [String: DownloadedMediaPayload] = [:]
    var isGroupDetailsPresented = false
    var groupDetailsSnapshot: GroupDetailsSnapshot?
    /// Contact currently shown over the conversation/group-details pane. Unlike direct-chat
    /// details, this can represent any group member before a DM group exists.
    var contactDetailsTarget: NewChatRecipient?
    var isLoadingContactDetails = false
    @ObservationIgnored var contactDetailsLoadGeneration: UInt64 = 0
    /// Conversations whose current roster also contains the contact whose details are open.
    /// This deliberately includes the direct-message group between the two accounts.
    var commonGroupsForContact: [ChatItem] = []
    var isLoadingCommonGroups = false
    var commonGroupsLoadHadFailures = false
    @ObservationIgnored var commonGroupsLoadGeneration: UInt64 = 0
    /// Shared-media browser state for the group-details sheet.
    var sharedMediaProjection = GroupSharedMediaProjection.empty
    var sharedMediaGroupId: String?
    var sharedMediaError: String?
    var isLoadingSharedMedia = false
    /// Monotonic generation so a superseded `loadSharedMedia` can't clear the spinner or publish a
    /// stale result/error into a newer load's state.
    @ObservationIgnored var sharedMediaLoadGeneration: UInt64 = 0
    /// Decrypted shared-media bytes keyed by account+group+plaintext-hash, with an insertion-order
    /// list and running byte total bounding eviction. `@ObservationIgnored` — views read via the
    /// async loader, not by observing this.
    @ObservationIgnored var sharedMediaThumbnailCache: [String: Data] = [:]
    @ObservationIgnored var sharedMediaThumbnailCacheOrder: [String] = []
    @ObservationIgnored var sharedMediaThumbnailCacheBytes = 0
    var conversationMetadataByChat: [String: ConversationMetadata] = [:]
    @ObservationIgnored var conversationMetadataGenerationByChat: [String: UInt64] = [:]
    /// Process-wide source for per-chat metadata ownership tokens. Tokens never restart when a
    /// removed chat clears its dictionary entry, preventing an old request from matching a newly
    /// joined conversation that reuses the same group id.
    @ObservationIgnored var conversationMetadataGeneration: UInt64 = 0
    /// Survives cache clearing so a late pre-teardown refresh cannot regain ownership when the
    /// same account and group recreate an identical per-chat generation token.
    @ObservationIgnored var conversationMetadataEpoch: UInt64 = 0
    /// Message ids the local account hid via "Delete for me", stored in protected, backup-excluded
    /// per-chat files so a local hide survives reprojection and restart without exposing account /
    /// group associations in preferences or filenames.
    @ObservationIgnored var hiddenMessageIdsByChat: [HiddenMessageScope: Set<String>] = [:]
    var selectedTimelineMessageIds: Set<String> = []
    /// Account/group scopes currently re-driving a committed-but-undelivered message.
    /// The core retry is group-scoped, so one guard covers every pending bubble in that chat.
    @ObservationIgnored var inFlightMessageRetryScopes = Set<String>()
    /// Scoped message target whose unified delete-confirmation surface is open, or `nil`. Drives the adaptive
    /// dialog that offers only the scopes `messageDeletionCapability` permits.
    var messagePendingDeletion: MessageDeletionTarget?
    /// Message whose edit-history sheet is open, or `nil`. Cleared when the selection changes.
    var messagePendingEditHistory: MessageItem?
    var messageInfoTarget: MessageItem?
    var forwardingMessageIds: [String] = []
    var isForwardPickerPresented = false
    var isForwardingMessages = false
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
    var groupTranscriptExportTask: Task<Void, Never>?
    var groupTranscriptExportStatus: String?
    var mutatingGroupMemberId: String?
    var storageRootPath = MarmotClient.defaultStorageRootPath()
    var timelinePagingByChat: [String: TimelinePagingState] = [:]
    var timelineInitialLoadGroupId: String?
    var draftTextByConversation: [ComposerDraftKey: String] = [:]
    var composerMentionSelectionsByConversation: [ComposerDraftKey: [ComposerMentionSelection]] = [:]
    var replyDraftContextByConversation: [ComposerDraftKey: MessageReplyContext] = [:]
    var editingMessageContextByConversation: [ComposerDraftKey: MessageEditContext] = [:]
    var pendingMediaAttachmentsByConversation: [ComposerDraftKey: [PendingMediaAttachment]] = [:]
    var pendingMediaUploadStatesByConversation:
        [ComposerDraftKey: [PendingMediaAttachment.ID: PendingMediaUploadState]] = [:]
    /// In-flight stage-time Blossom uploads, so removing an attachment (or tearing the composer
    /// down) cancels the upload it started instead of letting it land on a tile that is gone.
    @ObservationIgnored var pendingMediaUploadTasks: [PendingMediaAttachment.ID: Task<Void, Never>] = [:]
    @ObservationIgnored var composerDraftPersistenceTasks: [ComposerDraftKey: Task<Void, Never>] = [:]
    @ObservationIgnored var composerDraftMutationGenerations: [ComposerDraftKey: UInt64] = [:]
    @ObservationIgnored var dirtyComposerDraftKeys: Set<ComposerDraftKey> = []
    @ObservationIgnored var restoredComposerDraftKeys: Set<ComposerDraftKey> = []
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
    let appActivationHandler: @MainActor (_ ignoringOtherApps: Bool) -> Void
    let conversationWindowVisibilityProvider: @MainActor () -> Bool
    let copyTextHandler: @MainActor (String, Bool) -> Void
    let transcriptExportDestinationPicker: @MainActor (String) -> URL?
    let telemetryBuildConfigProvider: @MainActor () -> TelemetryBuildConfig
    let groupImageSearchClient: any GroupImageSearchClient
    let groupImageSourceLoader: any GroupImageSourceLoading
    let nip05Resolver: any NIP05Resolving
    /// Injectable clock for peer-profile cache TTL decisions, so tests can drive cache
    /// expiry deterministically (whitenoise-mac#8). Defaults to the system clock.
    let nowProvider: @MainActor () -> Date
    let microphoneAccessProvider: @MainActor () async -> Bool
    var client: (any MarmotRuntime)?
    var observabilityRuntimeConfiguration: ObservabilityRuntimeConfiguration?
    /// Last-request-wins ownership for observability configuration across account switches.
    /// Blocking FFI can resume after cancellation, so the generation is checked before publishing.
    var observabilityRuntimeGeneration: UInt64 = 0
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
    /// Coalesces the privacy/security subset, which is also loaded during ready-state activation
    /// outside the aggregate settings task.
    var privacySecurityLoadTask: Task<Void, Never>?
    var privacySecurityLoadAccountId: String?
    var privacySecurityLoadGeneration: UInt64 = 0
    /// Monotonic token for notification-settings reads/writes. Unlike `activeAccountId`, this
    /// bumps on every active-account transition, so an older A request cannot commit after a rapid
    /// A→B→A re-entry or after a newer notification load/toggle for the same account.
    var notificationSettingsGeneration: UInt64 = 0
    /// Monotonic token for privacy/security settings writes. Each setter bumps it on entry, so a
    /// load whose FFI read resolved before the save committed abandons its stale snapshot instead
    /// of reverting the just-saved toggle.
    var privacySecuritySettingsGeneration: UInt64 = 0
    var timelineTask: Task<Void, Never>?
    var timelineTaskGroupId: String?
    /// Single-owner coalescing for initial timeline loads (issue #332). `loadMessages` can be
    /// reached from overlapping unstructured navigation tasks; concurrent requests for the same
    /// account+group should await the in-flight subscription/snapshot pass instead of opening a
    /// duplicate live subscription and immediately orphaning the first listener handle. Requests for
    /// a different account or group supersede the stale owner; the generation token prevents a stale
    /// task from applying rows, starting a listener, or clearing newer load state if it resumes later.
    var timelineLoadTask: Task<Void, Never>?
    var timelineLoadGroupId: String?
    var timelineLoadAccountId: String?
    var timelineLoadGeneration: UInt64 = 0
    /// Last-request-wins owner for point-in-time post-send timeline refreshes. A newer refresh or
    /// listener teardown invalidates older windows before they can replace the selected transcript.
    var timelinePostSendRefreshGeneration: UInt64 = 0
    /// The live timeline subscription for the open conversation. It owns the
    /// authoritative, bounded, materialized window; scroll-back/forward pagination and
    /// live updates all flow through it (`paginateBackwards` / `paginateForwards` / `next`).
    /// Kept alive for pagination independent of the listener task. The listener replaces
    /// it after a recoverable stream end/reconnect, and it is cleared only when the
    /// conversation is torn down.
    var activeTimelineSubscription: TimelineMessagesSubscription?
    var activeTimelineGroupId: String?
    /// Sends waiting for the live subscription to project their row. Resolved by the listener
    /// (`applyTimelineProjection`) or by their own deadline, whichever comes first.
    @ObservationIgnored var timelineSendAcknowledgements: [TimelineSendAcknowledgement] = []
    /// Overridable so tests can drive both the "delta landed" and "deadline elapsed" branches
    /// deterministically instead of waiting out the production deadline on every send.
    @ObservationIgnored var timelineSendProjectionDeadline: Duration = WorkspaceState
        .timelineSendProjectionDeadline
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
    var profileImageSearchGeneration: UInt64 = 0
    var profileImageUploadGeneration: UInt64 = 0
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
    /// Mention-picker projections derived from `groupMemberDetailsCache`. Kept outside Observation
    /// so reading or populating the cache from a view body does not schedule another render.
    @ObservationIgnored var mentionRosterCache: [String: [ComposerMentionCandidate]] = [:]
    /// Timeline Markdown mention projections share the same roster lifetime as the picker cache.
    /// Keeping this separate avoids rebuilding and sanitizing every member on each projection delta.
    @ObservationIgnored var mentionNamesCache: [String: MarkdownMentionNames] = [:]
    var groupMemberDetailsLookups: [String: GroupMemberDetailsLookup] = [:]
    var readStateMetadataEnrichmentAttempts = Set<String>()
    var nextGroupMemberDetailsLookupToken: UInt64 = 0

    #if DEBUG
        /// Test-only instrumentation for verifying mention roster projections are reused.
        @ObservationIgnored var mentionRosterBuildCount = 0
        /// Test-only instrumentation for verifying timeline mention-name projections are reused.
        @ObservationIgnored var mentionNamesBuildCount = 0

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

        /// Timeline ownership regression support: when armed, the first window or projection
        /// map pass suspends until `releaseTimelineApplyMapGate()` is invoked.
        var timelineApplyMapGateEnabled = false
        private(set) var didReachTimelineApplyMapGate = false
        private var timelineApplyMapGateContinuation: CheckedContinuation<Void, Never>?

        func releaseTimelineApplyMapGate() {
            timelineApplyMapGateContinuation?.resume()
            timelineApplyMapGateContinuation = nil
        }

        func passTimelineApplyMapGateIfArmed() async {
            guard timelineApplyMapGateEnabled,
                timelineApplyMapGateContinuation == nil,
                !didReachTimelineApplyMapGate
            else { return }
            didReachTimelineApplyMapGate = true
            await withCheckedContinuation { continuation in
                timelineApplyMapGateContinuation = continuation
            }
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
    /// How long a completed send waits for the live subscription to project its row before
    /// falling back to an authoritative re-window. Long enough that a healthy runtime always
    /// wins the race, short enough that a lagging one does not leave the sender staring at a
    /// transcript that has not moved.
    static let timelineSendProjectionDeadline: Duration = .milliseconds(250)
    /// Upper bound on the materialized live window, matching the runtime's
    /// `TIMELINE_WINDOW_LIMIT`. Live projection deltas grow the window up to this cap
    /// before the oldest rows are trimmed (and `hasMoreBefore` is re-flagged), mirroring
    /// `apply_projection_to_window` in the core so client-side delta application stays in
    /// lockstep with the runtime's windowing.
    static let timelineWindowLimit = 200
    /// How many rendered transcript windows are retained at once. Only the selected chat has a
    /// live subscription; the others are inert snapshots kept so switching back is instant.
    /// Each costs at most `timelineWindowLimit` mapped rows.
    static let timelineStoreCacheLimit = 3
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

    /// Runs the pure timeline record → view-model transformation off the main actor.
    /// This uses the same queue as blocking FFI work because `WorkspaceState` is
    /// `@MainActor` while Markdown/attributed-string/media-JSON mapping can be expensive.
    nonisolated static func mapTimelineOffMain(
        page: TimelinePageFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile],
        mentionNames: MarkdownMentionNames
    ) async -> [MessageItem] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[MessageItem], Never>) in
            Self.ffiQueue.async {
                continuation.resume(
                    returning: MessageItem.timeline(
                        from: page,
                        activeAccountIdHex: activeAccountIdHex,
                        senderProfiles: senderProfiles,
                        mentionNames: mentionNames
                    )
                )
            }
        }
    }

    struct CachedContactNicknames {
        let ownerAccountIdHex: String
        let revision: UInt64
        let value: ContactNicknames
    }

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

    struct MediaReferenceCacheKey: Hashable, Sendable {
        var accountId: String
        var groupIdHex: String
    }

    nonisolated struct MediaReferenceIndex: Sendable {
        private struct Entry: Sendable {
            var order: Int
            var reference: MediaAttachmentReferenceFfi
        }

        private let referencesBySHA: [String: Entry]

        init(records: [MediaRecordFfi]) {
            var referencesBySHA: [String: Entry] = [:]
            referencesBySHA.reserveCapacity(records.count * 2)
            for (order, record) in records.enumerated() {
                // Preserve `first(where:)` semantics from the old linear scan when duplicate
                // hashes appear: the oldest record in list order wins for either SHA key.
                if referencesBySHA[record.reference.plaintextSha256] == nil {
                    referencesBySHA[record.reference.plaintextSha256] = Entry(
                        order: order,
                        reference: record.reference
                    )
                }
                if referencesBySHA[record.reference.ciphertextSha256] == nil {
                    referencesBySHA[record.reference.ciphertextSha256] = Entry(
                        order: order,
                        reference: record.reference
                    )
                }
            }
            self.referencesBySHA = referencesBySHA
        }

        func resolvedReference(matching reference: MediaAttachmentReferenceFfi) -> MediaAttachmentReferenceFfi? {
            let plaintextEntry = referencesBySHA[reference.plaintextSha256]
            let ciphertextEntry = referencesBySHA[reference.ciphertextSha256]
            switch (plaintextEntry, ciphertextEntry) {
            case (let plaintext?, let ciphertext?):
                return plaintext.order <= ciphertext.order ? plaintext.reference : ciphertext.reference
            case (let plaintext?, nil):
                return plaintext.reference
            case (nil, let ciphertext?):
                return ciphertext.reference
            case (nil, nil):
                return nil
            }
        }
    }

    struct MediaReferenceIndexTask {
        var generation: UInt64
        var task: Task<MediaReferenceIndex, Error>
    }

    struct MediaDiskStoreTask {
        var accountId: String
        var token: UInt64
        var task: Task<Void, Never>
    }

    struct MediaAttachmentDownloadTask {
        var token: UInt64
        var task: Task<MessageMediaDownload, Error>
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
    nonisolated static func runFFI<T>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Self.ffiQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Runs a blocking FFI closure off the main thread and resumes on the caller's actor.
    nonisolated func runOffMain<T>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Self.runFFI(work)
    }

    /// Runs blocking FFI off the main thread while exposing cancellation to the GCD closure.
    /// `Task.checkCancellation()` is only task-local; inside `ffiQueue.async` there is no current
    /// Swift task, so long synchronous loops must call the supplied checker instead.
    nonisolated func runOffMainCancellable<T>(
        _ work: @escaping @Sendable (_ checkCancellation: @escaping @Sendable () throws -> Void) throws -> T
    ) async throws -> T {
        let cancellation = OffMainCancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                Self.ffiQueue.async {
                    let checkCancellation: @Sendable () throws -> Void = {
                        try cancellation.check()
                    }
                    continuation.resume(
                        with: Result {
                            try checkCancellation()
                            let value = try work(checkCancellation)
                            try checkCancellation()
                            return value
                        }
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
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
        appActivationHandler: @escaping @MainActor (_ ignoringOtherApps: Bool) -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: $0)
        },
        conversationWindowVisibilityProvider: @escaping @MainActor () -> Bool = {
            WorkspaceState.defaultConversationWindowVisibilityProvider()
        },
        copyTextHandler: @escaping @MainActor (String, Bool) -> Void = WorkspaceState.copyToGeneralPasteboard,
        transcriptExportDestinationPicker: @escaping @MainActor (String) -> URL? =
            WorkspaceState.chooseTranscriptExportDestination,
        telemetryBuildConfigProvider: @escaping @MainActor () -> TelemetryBuildConfig = {
            TelemetryBuildConfig.current()
        },
        groupImageSearchClient: (any GroupImageSearchClient)? = nil,
        groupImageSourceLoader: (any GroupImageSourceLoading)? = nil,
        nip05Resolver: (any NIP05Resolving)? = nil,
        nowProvider: @escaping @MainActor () -> Date = { Date() },
        microphoneAccessProvider: @escaping @MainActor () async -> Bool = {
            await WorkspaceState.requestSystemMicrophoneAccess()
        },
        mediaDiskCache: MessageMediaDiskCache = .shared,
        hiddenMessageStore: (any HiddenMessageStoring)? = nil,
        pinnedChatStore: (any PinnedChatStoring)? = nil,
        contactNicknameStore: (any ContactNicknameStoring)? = nil,
        chatRestorationStore: (any ChatRestorationStoring)? = nil,
        quickReactionStore: (any QuickReactionStoring)? = nil,
        clientFactory: @escaping @MainActor () throws -> any MarmotRuntime = { try MarmotClient() }
    ) {
        self.accounts = accounts
        self.chatsByAccount = chatsByAccount.mapValues { Self.deduplicatedChats($0) }
        self.messageTimelineStores = messagesByChat.mapValues { MessageTimelineStore.loaded(with: $0) }
        self.cachedMessageChatIds = Set(messagesByChat.keys)
        self.localNotificationCenter = localNotificationCenter ?? MacLocalNotificationCenter()
        self.appActivityProvider = appActivityProvider
        self.appActivationHandler = appActivationHandler
        self.conversationWindowVisibilityProvider = conversationWindowVisibilityProvider
        self.copyTextHandler = copyTextHandler
        self.transcriptExportDestinationPicker = transcriptExportDestinationPicker
        self.telemetryBuildConfigProvider = telemetryBuildConfigProvider
        self.groupImageSearchClient = groupImageSearchClient ?? OpenverseGroupImageSearchClient()
        self.groupImageSourceLoader = groupImageSourceLoader ?? SecureGroupImageSourceLoader()
        self.nip05Resolver = nip05Resolver ?? NIP05Resolver()
        self.nowProvider = nowProvider
        self.microphoneAccessProvider = microphoneAccessProvider
        self.mediaDiskCache = mediaDiskCache
        self.hiddenMessageStore = hiddenMessageStore
        self.pinnedChatStore = pinnedChatStore
        self.contactNicknameStore = contactNicknameStore
        let resolvedChatRestorationStore =
            chatRestorationStore ?? UserDefaultsChatRestorationStore()
        self.chatRestorationStore = resolvedChatRestorationStore
        self.restoreLastSelectedChat = resolvedChatRestorationStore.isEnabled
        let resolvedQuickReactionStore =
            quickReactionStore ?? UserDefaultsQuickReactionStore()
        self.quickReactionStore = resolvedQuickReactionStore
        self.quickReactions = QuickReactionSet.normalized(resolvedQuickReactionStore.load())
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

    private static func deduplicatedChats(_ chats: [ChatItem]) -> [ChatItem] {
        uniquedLastWins(chats, by: \.id)
    }

    var activeAccount: AccountItem? {
        guard let activeAccountId else { return nil }
        return accounts.first { $0.id == activeAccountId }
    }

    var activeChats: [ChatItem] {
        guard let activeAccountId else { return [] }
        return chatsByAccount[activeAccountId] ?? []
    }

    var archivedChats: [ChatItem] {
        guard let activeAccountId else { return [] }
        return archivedChatsByAccount[activeAccountId] ?? []
    }

    var filteredChats: [ChatItem] {
        filteredChats(matching: searchText)
    }

    var filteredArchivedChats: [ChatItem] {
        filteredArchivedChats(matching: searchText)
    }

    func filteredChats(matching query: String) -> [ChatItem] {
        guard let activeAccountId else { return [] }
        // Read the observed list before a cache-hit return so SwiftUI keeps invalidating the
        // sidebar on incoming chat updates even when filtering work is memoized.
        let chats = chatsByAccount[activeAccountId] ?? []
        let generation = chatListGenerationByAccount[activeAccountId] ?? 0
        if let cache = filteredChatsCache,
            cache.accountId == activeAccountId,
            cache.generation == generation,
            cache.query == query
        {
            return cache.result
        }

        let result = ChatFilter.filtered(chats, query: query)
        filteredChatsCache = FilteredChatsCache(
            accountId: activeAccountId,
            generation: generation,
            query: query,
            result: result
        )
        return result
    }

    func filteredArchivedChats(matching query: String) -> [ChatItem] {
        guard let activeAccountId else { return [] }
        // Read the observed list before a cache-hit return so each SwiftUI evaluation keeps the
        // archived section subscribed to live archive and metadata updates.
        let chats = archivedChatsByAccount[activeAccountId] ?? []
        let generation = archivedChatListGenerationByAccount[activeAccountId] ?? 0
        if let cache = filteredArchivedChatsCache,
            cache.accountId == activeAccountId,
            cache.generation == generation,
            cache.query == query
        {
            return cache.result
        }

        let result = ChatFilter.filtered(chats, query: query)
        filteredArchivedChatsCache = FilteredChatsCache(
            accountId: activeAccountId,
            generation: generation,
            query: query,
            result: result
        )
        return result
    }

    var selectedChat: ChatItem? {
        guard case .chat(let chatId) = selection else { return nil }
        _ = selectedChatRevision
        return activeAccountId.flatMap { chatItem(accountId: $0, chatId: chatId) }
    }

    var resolvedNewChatRecipient: NewChatRecipient? {
        guard let newChatRecipient,
            newChatRecipient.matches(query: newChatQuery)
        else { return nil }

        return newChatRecipient
    }

    func setChats(_ chats: [ChatItem], forAccountId accountId: String) {
        chatsByAccount[accountId] = Self.deduplicatedChats(chats)
        rebuildChatIndexes(forAccountId: accountId)
    }

    func upsertChat(_ chat: ChatItem, forAccountId accountId: String) {
        let chats = chatsByAccount[accountId] ?? []
        let result = ChatListOrdering.upsertResult(
            chat,
            into: chats,
            existingIndex: chatIndex(accountId: accountId, chatId: chat.id),
            pinnedChatIds: pinnedChatIds(forAccountId: accountId)
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
        archivedChatsByAccount[accountId] = nil
        archivedChatLookupByAccount[accountId] = nil
        archivedChatIndexByAccount[accountId] = nil
        bumpArchivedChatListGeneration(forAccountId: accountId)
    }

    func resetChats() {
        // Currently used only by `resetToNewInstallState`, which clears `activeAccountId` and
        // `selection` in the same synchronous reset path. A future caller that keeps a selected
        // chat alive while clearing these ignored indexes must also bump `selectedChatRevision`.
        chatsByAccount = [:]
        chatLookupByAccount = [:]
        chatIndexByAccount = [:]
        chatListGenerationByAccount = [:]
        filteredChatsCache = nil
        archivedChatsByAccount = [:]
        archivedChatLookupByAccount = [:]
        archivedChatIndexByAccount = [:]
        archivedChatListGenerationByAccount = [:]
        filteredArchivedChatsCache = nil
    }

    func rebuildChatIndexes() {
        chatLookupByAccount = [:]
        chatIndexByAccount = [:]
        for accountId in Array(chatsByAccount.keys) {
            rebuildChatIndexes(forAccountId: accountId)
        }
        archivedChatLookupByAccount = [:]
        archivedChatIndexByAccount = [:]
        for accountId in Array(archivedChatsByAccount.keys) {
            rebuildArchivedChatIndexes(forAccountId: accountId)
        }
    }

    func rebuildChatIndexes(forAccountId accountId: String) {
        let chats = Self.deduplicatedChats(chatsByAccount[accountId] ?? [])
        if chatsByAccount[accountId] != nil {
            chatsByAccount[accountId] = chats
        }
        chatLookupByAccount[accountId] = Dictionary(
            chats.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )
        chatIndexByAccount[accountId] = Dictionary(
            chats.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, new in new }
        )
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

    func rebuildArchivedChatIndexes(forAccountId accountId: String) {
        let chats = Self.deduplicatedChats(archivedChatsByAccount[accountId] ?? [])
        if archivedChatsByAccount[accountId] != nil {
            archivedChatsByAccount[accountId] = chats
        }
        archivedChatLookupByAccount[accountId] = Dictionary(
            chats.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )
        archivedChatIndexByAccount[accountId] = Dictionary(
            chats.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, new in new }
        )
        bumpArchivedChatListGeneration(forAccountId: accountId)
    }

    func reindexArchivedChats(forAccountId accountId: String, startingAt startIndex: Int) {
        let chats = archivedChatsByAccount[accountId] ?? []
        guard startIndex < chats.endIndex else { return }

        var lookup = archivedChatLookupByAccount[accountId] ?? [:]
        var indexes = archivedChatIndexByAccount[accountId] ?? [:]
        for index in max(0, startIndex)..<chats.endIndex {
            let chat = chats[index]
            lookup[chat.id] = chat
            indexes[chat.id] = index
        }
        archivedChatLookupByAccount[accountId] = lookup
        archivedChatIndexByAccount[accountId] = indexes
    }

    func chatItem(accountId: String, chatId: String) -> ChatItem? {
        chatLookupByAccount[accountId]?[chatId] ?? archivedChatLookupByAccount[accountId]?[chatId]
    }

    func chatIndex(accountId: String, chatId: String) -> Int? {
        chatIndexByAccount[accountId]?[chatId]
    }

    func archivedChatItem(accountId: String, chatId: String) -> ChatItem? {
        archivedChatLookupByAccount[accountId]?[chatId]
    }

    func archivedChatIndex(accountId: String, chatId: String) -> Int? {
        archivedChatIndexByAccount[accountId]?[chatId]
    }

    func setArchivedChats(_ chats: [ChatItem], forAccountId accountId: String) {
        archivedChatsByAccount[accountId] = Self.deduplicatedChats(chats)
        rebuildArchivedChatIndexes(forAccountId: accountId)
    }

    func upsertArchivedChat(_ chat: ChatItem, forAccountId accountId: String) {
        let chats = archivedChatsByAccount[accountId] ?? []
        let result = ChatListOrdering.upsertResult(
            chat,
            into: chats,
            existingIndex: archivedChatIndex(accountId: accountId, chatId: chat.id)
        )
        archivedChatsByAccount[accountId] = result.chats

        if let reindexStart = result.reindexStart {
            reindexArchivedChats(forAccountId: accountId, startingAt: reindexStart)
        } else {
            var lookup = archivedChatLookupByAccount[accountId] ?? [:]
            lookup[chat.id] = chat
            archivedChatLookupByAccount[accountId] = lookup
        }
        bumpArchivedChatListGeneration(forAccountId: accountId)
    }

    @discardableResult
    func removeArchivedChatFromList(chatId: String, forAccountId accountId: String) -> [ChatItem] {
        var chats = archivedChatsByAccount[accountId] ?? []
        if let index = archivedChatIndex(accountId: accountId, chatId: chatId) {
            chats.remove(at: index)
            archivedChatsByAccount[accountId] = chats

            var lookup = archivedChatLookupByAccount[accountId] ?? [:]
            lookup[chatId] = nil
            archivedChatLookupByAccount[accountId] = lookup

            var indexes = archivedChatIndexByAccount[accountId] ?? [:]
            indexes[chatId] = nil
            archivedChatIndexByAccount[accountId] = indexes

            reindexArchivedChats(forAccountId: accountId, startingAt: index)
            bumpArchivedChatListGeneration(forAccountId: accountId)
            return chats
        }

        let originalCount = chats.count
        chats.removeAll { $0.id == chatId }
        guard chats.count != originalCount else { return chats }
        setArchivedChats(chats, forAccountId: accountId)
        return chats
    }

    private func bumpChatListGeneration(forAccountId accountId: String) {
        chatListGenerationByAccount[accountId, default: 0] += 1
        if activeAccountId == accountId {
            selectedChatRevision += 1
        }
        if filteredChatsCache?.accountId == accountId {
            filteredChatsCache = nil
        }
    }

    private func bumpArchivedChatListGeneration(forAccountId accountId: String) {
        archivedChatListGenerationByAccount[accountId, default: 0] += 1
        if activeAccountId == accountId {
            selectedChatRevision += 1
        }
        if filteredArchivedChatsCache?.accountId == accountId {
            filteredArchivedChatsCache = nil
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

    var selectedTimelineDisplayItems: [TimelineMessageDisplayItem] {
        guard let selectedChat else { return [] }
        return messageTimelineStores[selectedChat.id]?.displayItems ?? []
    }

    func refreshTimelineDisplayItems(referenceDate: Date, locale: Locale) {
        for store in messageTimelineStores.values {
            store.refreshDisplayItems(referenceDate: referenceDate, locale: locale)
        }
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
        "\(MarmotKitVersion.mdkSHA) / \(MarmotKitVersion.builtAt)"
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
        // The core rejects sends while an invite is pending, or once the local
        // account left/was removed (`invalid_transition`), so those readable
        // states do not expose outbound composer actions.
        client != nil
            && selectedChat?.canUseComposer == true
            && (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingMediaAttachments.isEmpty)
            // Attachments upload as they are staged, so the composer refuses to send until every
            // one carries a Blossom reference. Text-only drafts are unaffected.
            && composerMediaUploadStatus == nil
            && !isSending
    }

    /// Why the selected composer is not sendable yet, or `nil` once every staged attachment
    /// carries a reference. Drives both the `canSend` gate and the send button's tooltip, so
    /// "the button is off" and "here is why" can never disagree.
    var composerMediaUploadStatus: ComposerMediaUploadStatus? {
        let attachments = pendingMediaAttachments
        guard !attachments.isEmpty else { return nil }
        let states = pendingMediaUploadStates
        if attachments.contains(where: { states[$0.id] == .failed }) { return .failed }
        return attachments.allSatisfy { states[$0.id]?.isUploaded == true } ? nil : .uploading
    }

    var showsMessengerChrome: Bool {
        phase == .ready && activeAccount != nil
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
            managementState.memberActions.map { ($0.memberIdHex, $0) },
            uniquingKeysWith: { _, new in new }
        )
        let nicknames = activeContactNicknames
        let members = details.members
            .map { member in
                let action = actionByMemberId[member.memberIdHex]
                let published =
                    firstNonBlank([
                        PeerDisplayText.sanitize(member.displayName),
                        PeerDisplayText.sanitize(member.account),
                    ]) ?? DisplayText.short(member.npub, head: 12, tail: 8)
                // You cannot nickname yourself, so `isSelf` rows always read the published name.
                let nickname =
                    member.isSelf
                    ? nil : nicknames.nickname(forContactAccountIdHex: member.memberIdHex)
                let displayName = nickname ?? published
                return GroupMemberItem(
                    id: member.memberIdHex,
                    displayName: displayName,
                    publishedDisplayName: nickname == nil ? nil : published,
                    npub: member.npub,
                    accountLabel: PeerDisplayText.sanitize(member.account),
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
            name: PeerDisplayText.sanitize(details.group.name) ?? L10n.string("Unnamed group"),
            description: details.group.description,
            avatarURL: avatarURL,
            sanitizedAvatarURL: RemoteImageURLPolicy.sanitizedURL(from: avatarURL),
            avatarDimension: firstNonBlank([details.group.avatarDim]),
            nostrGroupIdHex: details.group.nostrGroupIdHex,
            relays: details.group.relays,
            adminIds: details.group.admins,
            archived: details.group.archived,
            pendingConfirmation: details.group.pendingConfirmation,
            selfMembership: ChatSelfMembership(details.group.selfMembership),
            members: members,
            isSelfAdmin: managementState.isSelfAdmin,
            isLastAdmin: managementState.isLastAdmin,
            canInvite: managementState.canInvite,
            canLeave: managementState.canLeave,
            requiresSelfDemoteBeforeLeave: managementState.requiresSelfDemoteBeforeLeave,
            leaveRequestPending: managementState.leaveRequestPending,
            leaveRequestedAtMs: managementState.leaveRequestedAtMs,
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
            await self?.configureObservabilityRuntimeBestEffort()
        }
    }

    func configureObservabilityRuntimeBestEffort() async {
        do {
            try await configureObservabilityRuntime()
        } catch {
            setBackgroundStatus(error.localizedDescription)
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
        let accountId = activeAccountId
        let accountLabel = activeAccount?.displayName
        if let cached = observabilityRuntimeConfiguration,
            cached.buildConfig == config,
            cached.accountLabel == accountLabel
        {
            privacySecuritySettings.telemetryCredentialsAvailable = config.telemetryCredentialsAvailable
            privacySecuritySettings.auditLogCredentialsAvailable = config.auditLogCredentialsAvailable
            return
        }

        observabilityRuntimeGeneration &+= 1
        let generation = observabilityRuntimeGeneration

        let relayRuntimeConfig: RelayTelemetryRuntimeConfigFfi
        if let cached = observabilityRuntimeConfiguration,
            cached.buildConfig == config
        {
            relayRuntimeConfig = cached.relayTelemetryRuntimeConfig
        } else {
            let installId = try await runOffMain {
                try client.telemetryInstallId()
            }
            guard !Task.isCancelled, observabilityRuntimeGeneration == generation,
                activeAccountId == accountId
            else { return }
            relayRuntimeConfig = config.runtimeConfig(installId: installId)
        }
        let auditTrackerConfig = config.auditTrackerConfig()

        if observabilityRuntimeConfiguration?.relayTelemetryRuntimeConfig != relayRuntimeConfig {
            try await client.setRelayTelemetryRuntimeConfig(config: relayRuntimeConfig)
            guard !Task.isCancelled, observabilityRuntimeGeneration == generation,
                activeAccountId == accountId
            else { return }
        }
        if observabilityRuntimeConfiguration?.auditLogTrackerConfig != auditTrackerConfig {
            _ = try await runOffMain {
                try client.setAuditLogTrackerConfig(config: auditTrackerConfig)
            }
            guard !Task.isCancelled, observabilityRuntimeGeneration == generation,
                activeAccountId == accountId
            else { return }
        }

        guard observabilityRuntimeGeneration == generation, activeAccountId == accountId else { return }
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

    /// The URL used to render the search-result thumbnail. Only the
    /// Openverse-proxied `thumbnailURL` is used; the arbitrary origin
    /// `imageURL` is never fetched for previews (whitenoise-mac#315), so a
    /// result without a usable thumbnail renders the placeholder instead.
    var previewURL: URL? {
        guard let thumbnailURL = thumbnailURL?.nilIfBlank else { return nil }
        return URL(string: thumbnailURL)
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

protocol GroupImageSourceLoading {
    func data(for url: URL) async -> Data?
}

struct SecureGroupImageSourceLoader: GroupImageSourceLoading {
    func data(for url: URL) async -> Data? {
        await RemoteImageLoader.shared.data(for: url)
    }
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
        self.init(name: "", displayName: fallbackName, about: "", picture: "", banner: "", nip05: "", lud16: "")
    }

    init(profile: UserProfileMetadataFfi?, fallbackName: String) {
        self.init(
            name: profile?.name ?? "",
            displayName: profile?.displayName ?? fallbackName,
            about: profile?.about ?? "",
            picture: profile?.picture ?? "",
            banner: profile?.banner ?? "",
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
            banner: banner.nilIfBlank,
            nip05: nip05.nilIfBlank,
            lud16: lud16.nilIfBlank
        )
    }

    func primaryDisplayName(fallback: String) -> String {
        firstNonBlank([displayName, fallback]) ?? fallback
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
        case .inbox: return L10n.string("Inbox")
        @unknown default: return L10n.string("Unknown")
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
