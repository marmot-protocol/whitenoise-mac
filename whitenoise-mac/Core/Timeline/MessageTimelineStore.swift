import Foundation
import Observation

/// Owns one conversation's materialized transcript: the loaded message window, the edit and
/// deletion overlays applied to it, and the day-grouped `displayItems` projection the transcript
/// renders from.
///
/// It is a **store**, not a view model. It holds materialized state and its rendering projection,
/// is driven by the session rather than by a screen, and deliberately owns no drafts, no in-flight
/// flags, and no navigation — those belong to whatever presents it. One instance exists per cached
/// chat, so `@ObservationIgnored` is used to keep bookkeeping out of a view's observation set;
/// each such property documents what it would cost to observe.
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
    /// The day/locale context `displayItems` was last grouped against, kept only to detect that a
    /// regrouping is needed. `@ObservationIgnored`: they are written in the same pass that rebuilds
    /// `displayItems`, so observing them would invalidate every view reading this store a second
    /// time for one change that `displayItems` already publishes.
    @ObservationIgnored private var displayReferenceDate: Date
    @ObservationIgnored private var displayCalendar: Calendar
    @ObservationIgnored private var displayLocale: Locale
    /// O(1) id → message map for non-UI lookups (`timelineMessage(groupIdHex:messageId:)`).
    /// `@ObservationIgnored`: it is never read from a view body — only `messages`/`messageIDs`
    /// drive rendering — so it must not enlarge a view's observation set. The store owns this
    /// (and `messageIDs`) so callers don't maintain parallel per-chat dictionaries.
    @ObservationIgnored private(set) var lookup: [String: MessageItem]
    /// id → index into `messages`, maintained alongside `lookup` for O(1) in-place row updates.
    /// `@ObservationIgnored` for the same reason as `lookup`: no view body reads it, so observing it
    /// would make every window mutation invalidate views that only render `messages`.
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
        messages.uniquedLastWins(by: \.id)
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
        applyEditMutations(editMutations)
        pruneInvalidSenderCandidatesForMaterializedTargets()
        pruneEditCandidates(windowLimit: windowLimit ?? max(bases.count, 1))
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

        if !removalIds.isEmpty {
            let originalCount = messages.count
            let removedMessageIds = Set(messages.filter { removalIds.contains($0.id) }.map(\.id))
            messages.removeAll { removalIds.contains($0.id) }
            didRemoveMessages = messages.count != originalCount
            for removedId in removedMessageIds {
                baseMessagesById.removeValue(forKey: removedId)
            }
            purgeEditCandidates(forRemovalIds: removalIds)
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

        applyEditMutations(editMutations)

        var didTrimOlderMessages = false
        if messages.count > windowLimit {
            trimOldestMessages(count: messages.count - windowLimit)
            didTrimOlderMessages = true
            didChange = true
        }

        pruneInvalidSenderCandidatesForMaterializedTargets()
        pruneEditCandidates(windowLimit: windowLimit)
        if recomputeAllRenderedMessages() {
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

    /// Rewrites every mention of one person in this materialized window, the counterpart of
    /// `relabelSender` for the labels baked into a bubble's body. Rows that do not mention them
    /// are skipped without allocating, so the cost is proportional to the mentions actually on
    /// screen rather than to the window size.
    ///
    /// Both the rendered rows and the pre-edit bases are relabeled: an edited row renders from its
    /// base, and a base left with the stale label would resurface it on the next recompute.
    ///
    /// An edited row cannot be relabeled directly — it carries no Markdown (`applyingEdit` drops
    /// it) and resolves its mentions into plain text from the base's `mentionNames` — so the rows
    /// whose base changed are re-rendered through the ordinary edit-overlay path afterwards.
    /// Without that, an edited bubble kept the old label until the next full recomputation.
    @discardableResult
    func relabelMention(bech32: String, name: String?) -> Bool {
        var didChange = false
        for index in messages.indices {
            guard let relabeled = messages[index].applyingMentionLabel(bech32: bech32, name: name) else { continue }
            messages[index] = relabeled
            lookup[relabeled.id] = relabeled
            didChange = true
        }
        var relabeledBaseIds: Set<String> = []
        for (id, base) in baseMessagesById {
            guard let relabeled = base.applyingMentionLabel(bech32: bech32, name: name) else { continue }
            baseMessagesById[id] = relabeled
            relabeledBaseIds.insert(id)
            didChange = true
        }
        if recomputeRenderedMessages(withIds: relabeledBaseIds) {
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

    private func applyEditMutations(_ mutations: [MessageEditMutation]) {
        guard !mutations.isEmpty else { return }
        for mutation in mutations {
            switch mutation {
            case .upsert(let overlay):
                editCandidatesById[overlay.editMessageIdHex] = overlay
            case .retract(let editMessageIdHex):
                editCandidatesById.removeValue(forKey: editMessageIdHex)
            }
        }
        rebuildEditCandidateTargetIndex()
    }

    @discardableResult
    private func recomputeAllRenderedMessages() -> Bool {
        var didChange = false
        var candidateVisitCount = 0
        for index in messages.indices {
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

    /// Re-renders only the rows whose base was just mutated, through the same edit-overlay path
    /// `recomputeAllRenderedMessages` uses, so a targeted base mutation can never leave a rendered
    /// row derived from the old base. Visiting only the changed ids keeps the cost proportional to
    /// the mutation instead of to the window, and rows that render identically are left untouched.
    ///
    /// `lastRenderEditCandidateVisitCount` is deliberately not written here: it reports the most
    /// recent *full* render pass, and a partial count would misreport it.
    private func recomputeRenderedMessages(withIds ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        var didChange = false
        for id in ids {
            guard let index = indexById[id], let base = baseMessagesById[id] else { continue }
            let rendered = renderedMessage(from: base).message
            guard messages[index] != rendered else { continue }
            messages[index] = rendered
            lookup[id] = rendered
            didChange = true
        }
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

    private func purgeEditCandidates(forRemovalIds removalIds: Set<String>) {
        guard !removalIds.isEmpty, !editCandidatesById.isEmpty else { return }
        replaceEditCandidates(
            with: editCandidatesById.filter { _, candidate in
                !removalIds.contains(candidate.editMessageIdHex)
                    && !removalIds.contains(candidate.targetMessageIdHex)
            }
        )
    }

    private func pruneInvalidSenderCandidatesForMaterializedTargets() {
        guard !editCandidatesById.isEmpty else { return }
        replaceEditCandidates(
            with: editCandidatesById.filter { _, candidate in
                guard let base = baseMessagesById[candidate.targetMessageIdHex] else { return true }
                return candidate.sender == base.senderAccountIdHex
            }
        )
    }

    private func pruneEditCandidates(windowLimit limit: Int) {
        guard limit > 0, editCandidatesById.count > limit else { return }

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
        replaceEditCandidates(with: kept)
    }

    private func replaceEditCandidates(with candidates: [String: MessageEditOverlay]) {
        editCandidatesById = candidates
        rebuildEditCandidateTargetIndex()
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
