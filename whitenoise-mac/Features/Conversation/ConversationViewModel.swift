import Foundation
import MarmotKit
import Observation

enum ConversationFeatureError: Equatable {
    case unavailable(String)
    case staleWindow
    case draftConflict
}

private struct PollVoteAttempt {
    let id: UUID
    let selection: [String]
}

/// Where the "New messages" divider sits: the first row MarmotKit reported unread when the
/// conversation opened. Captured once per open and never moved, so marking rows read while the
/// user reads does not slide the divider down under them.
struct ConversationUnreadDivider: Equatable {
    let messageIdHex: String
    let unreadCount: UInt64
}

struct PendingDurableSend: Identifiable, Equatable {
    let id: String
    let text: String
    let replyToMessageIdHex: String?
    var acceptedMessageIdHex: String?
}

nonisolated enum BlockedConversationPresentation {
    /// Removes rows authored by blocked accounts and strips a blocked author's quoted content
    /// from otherwise-visible replies. The complete MarmotKit snapshot remains untouched so an
    /// unblock can immediately re-project the same window without another database read.
    static func timelineRecords(
        snapshot: ConversationWindowSnapshotFfi,
        blockedAccountIDs: Set<String>
    ) -> [TimelineMessageRecordFfi] {
        guard !blockedAccountIDs.isEmpty else { return snapshot.messages.map(\.timeline) }
        return snapshot.messages.compactMap { message in
            var timeline = message.timeline
            guard !blockedAccountIDs.contains(timeline.sender.lowercased()) else { return nil }
            if let replyAuthor = message.references.replyAuthor?.lowercased(),
                blockedAccountIDs.contains(replyAuthor)
            {
                timeline.replyPreview = nil
            }
            return timeline
        }
    }
}

/// One screen-scoped, complete conversation projection. Every accepted update replaces the
/// snapshot wholesale; the view never assembles a transcript from independently timed reads.
@MainActor
@Observable
final class ConversationViewModel {
    let account: AccountItem
    let groupIdHex: String
    /// Images for this conversation's NIP-30 custom emoji, in message text and reactions.
    let customEmojiImages: CustomEmojiImageStore
    private(set) var snapshot: ConversationWindowSnapshotFfi?
    private(set) var pendingSends: [String: PendingDurableSend] = [:]
    private(set) var isLoading = false
    /// True while a page or a return to the latest is in flight. Both quote the window's current
    /// revision, so the transcript starts neither while one is outstanding.
    var isPaging: Bool { windowCommandsInFlight > 0 }
    private var windowCommandsInFlight = 0
    private(set) var error: ConversationFeatureError?
    /// Set from the first snapshot of an open that MarmotKit anchored on the first unread row.
    private(set) var unreadDivider: ConversationUnreadDivider?
    /// True once a snapshot has been handed to the snapshot observer, i.e. the transcript renders
    /// this window's rows rather than whatever it showed before.
    private(set) var hasPresentedWindow = false
    /// The revision most recently handed to the snapshot observer. Presentations suspend (avatar
    /// reads, off-main mapping) and can overlap — the receive loop, a page reply, a block-list
    /// change — so an observer checks `isLatestPresentation` before it applies, and an older
    /// window that finishes last cannot replace a newer one.
    @ObservationIgnored private var presentedRevision: ConversationWindowRevisionFfi?
    /// The messages the transcript currently reports on screen, for paging. Ignored by
    /// observation: the transcript writes it as it scrolls and no view renders from it.
    @ObservationIgnored private(set) var visibleMessageIds: Set<String> = []
    /// The visible messages the reader has actually reached (`timelineReadableMessageIds`), empty
    /// until the open has landed. Read marking, including when the app regains focus, uses these.
    @ObservationIgnored private(set) var readableMessageIds: Set<String> = []
    /// In-flight votes keyed by poll message id, drawn over MDK's tally until a snapshot projects
    /// the same selection or the vote fails.
    private(set) var pendingPollSelections: [String: [String]] = [:]
    /// Every vote per poll message that has not failed or been confirmed by a snapshot, oldest
    /// first. A failed vote falls back to the newest survivor rather than to whatever it replaced,
    /// which may itself have failed in the meantime.
    @ObservationIgnored private var pollVoteAttempts: [String: [PollVoteAttempt]] = [:]
    /// The open "View votes" sheet's model, if any. Re-read from the start whenever a snapshot
    /// reprojects its poll's row.
    private(set) var pollVotes: PollVotesViewModel?
    /// The poll row as the last installed snapshot projected it, to tell a reprojection of that
    /// row from a snapshot that left it unchanged.
    @ObservationIgnored private var pollVotesRecord: TimelineMessageRecordFfi?

    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private let productAnalytics: ProductAnalyticsRecorder?
    @ObservationIgnored private var subscription: ConversationWindowSubscription?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    /// One deadline task is sufficient because every completed sweep causes the authoritative
    /// conversation subscription to replace the snapshot. Cancelling the model therefore fences
    /// both paging and expiry work without a separate staleness generation.
    @ObservationIgnored private var retentionExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotObserver: (@MainActor (ConversationWindowSnapshotFfi) async -> Void)?
    @ObservationIgnored private var capturesUnreadDivider = false

    init(
        account: AccountItem,
        groupIdHex: String,
        runtime: any MarmotRuntime,
        productAnalytics: ProductAnalyticsRecorder? = nil
    ) {
        self.account = account
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.productAnalytics = productAnalytics
        self.customEmojiImages = CustomEmojiImageStore(
            accountId: account.id,
            accountRef: account.accountRef,
            groupIdHex: groupIdHex,
            runtime: runtime
        )
    }

    func start(mode: ConversationOpenModeFfi = .automatic, messageIdHex: String? = nil) {
        stopWindow()
        isLoading = snapshot == nil
        unreadDivider = nil
        capturesUnreadDivider = true
        let timing = productAnalytics?.beginTiming()
        subscriptionTask = Task { [weak self] in
            await self?.runSubscription(
                mode: mode,
                messageIdHex: messageIdHex,
                timing: timing
            )
        }
    }

    /// The conversation is going away: its window, and the custom emoji images still loading.
    func stop() {
        stopWindow()
        customEmojiImages.cancelAll()
    }

    /// Ends the window subscription only, so `start` can reopen it without restarting emoji loads.
    private func stopWindow() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        retentionExpiryTask?.cancel()
        retentionExpiryTask = nil
        if let subscription {
            self.subscription = nil
            let runtime = runtime
            Task { await runtime.cancelConversationWindow(subscription: subscription) }
        }
    }

    func setSnapshotObserver(
        _ observer: (@MainActor (ConversationWindowSnapshotFfi) async -> Void)?
    ) async {
        snapshotObserver = observer
        if let snapshot, let observer {
            await present(snapshot, to: observer)
        }
    }

    /// Hands the installed snapshot to the observer again, for a change the host projects over
    /// it, such as a block-list update.
    func representSnapshot() async {
        guard let snapshot, let snapshotObserver else { return }
        await present(snapshot, to: snapshotObserver)
    }

    /// Whether `revision` is still the newest one handed to the observer.
    func isLatestPresentation(_ revision: ConversationWindowRevisionFfi) -> Bool {
        presentedRevision == revision
    }

    private func present(
        _ snapshot: ConversationWindowSnapshotFfi,
        to observer: @MainActor (ConversationWindowSnapshotFfi) async -> Void
    ) async {
        presentedRevision = snapshot.revision
        await observer(snapshot)
        hasPresentedWindow = true
    }

    func setVisibleMessageIds(_ ids: Set<String>) {
        visibleMessageIds = ids
    }

    /// Whether MarmotKit's window follows the tail. An unread open, a jump and any page that
    /// reported a visible anchor retain their anchor instead, and a retained window can stop
    /// taking arrivals even when its newest row is the conversation's newest message; the
    /// transcript re-attaches it with `returnToLatest` once the reader reaches that foot.
    var isFollowingTail: Bool {
        snapshot?.anchor.kind == .latest
    }

    func setReadableMessageIds(_ ids: Set<String>) {
        readableMessageIds = ids
    }

    /// Pages the window. `visibleAnchorMessageIdHex`, a message the reader can see, is reported
    /// first with `set_visible_anchor`: MarmotKit keeps the window around that row when a page
    /// passes its 200-row cap, and without it a capped page keeps the opening anchor and stops
    /// advancing while the has-more flag stays true. The transcript keeps the reader's place
    /// itself, by message identity, so nothing here depends on how the window grew.
    func page(
        _ direction: ConversationPageDirectionFfi,
        count: UInt32 = 50,
        visibleAnchorMessageIdHex: String? = nil
    ) async {
        guard !isPaging, let subscription, snapshot != nil else { return }
        if direction == .older, snapshot?.hasMoreBefore != true { return }
        if direction == .newer, snapshot?.hasMoreAfter != true { return }
        windowCommandsInFlight += 1
        defer { windowCommandsInFlight -= 1 }
        // Commands run while the subscription's receive loop keeps installing replacements, so
        // each step quotes the newest installed revision rather than the reply it awaited: a
        // background update that landed in between supersedes that reply. One stale reply is
        // retried from the current snapshot, unless the window was re-anchored meanwhile (the
        // reader returned to the latest): paging that window would undo the move.
        let anchorKind = snapshot?.anchor.kind
        var remainingStaleRetries = 1
        while true {
            do {
                if let visibleAnchorMessageIdHex, let revision = snapshot?.revision {
                    // A viewport move over the same rows: install it for its revision, but do not
                    // re-present 200 unchanged rows — the page reply right after carries the rows.
                    await install(
                        try await subscription.setVisibleAnchor(
                            revision: revision,
                            messageIdHex: visibleAnchorMessageIdHex,
                            timeoutMs: 0
                        ),
                        presents: false
                    )
                }
                guard let revision = snapshot?.revision else { return }
                await install(
                    try await subscription.page(
                        revision: revision,
                        direction: direction,
                        count: count,
                        timeoutMs: 0
                    ))
                return
            } catch is CancellationError {
                return
            } catch MarmotKitError.ConversationWindowStale {
                guard snapshot?.anchor.kind == anchorKind else { return }
                guard remainingStaleRetries > 0 else {
                    self.error = .staleWindow
                    return
                }
                remainingStaleRetries -= 1
            } catch {
                self.error = .unavailable(error.localizedDescription)
                return
            }
        }
    }

    func jump(to messageIdHex: String) async {
        guard let subscription, let revision = snapshot?.revision else { return }
        do {
            await install(
                try await subscription.jumpToMessage(
                    revision: revision,
                    messageIdHex: messageIdHex,
                    timeoutMs: 0
                ))
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    /// Re-attaches the window to the tail. Not gated on `isPaging`: it is the reader's explicit
    /// move (a send, the jump-to-latest button), and a page racing it will not retry over it. A
    /// stale reply is retried once from the current snapshot, as a page's is.
    func returnToLatest() async {
        guard let subscription else { return }
        windowCommandsInFlight += 1
        defer { windowCommandsInFlight -= 1 }
        var remainingStaleRetries = 1
        while let revision = snapshot?.revision {
            do {
                await install(try await subscription.returnToLatest(revision: revision, timeoutMs: 0))
                return
            } catch is CancellationError {
                return
            } catch MarmotKitError.ConversationWindowStale {
                guard remainingStaleRetries > 0 else {
                    self.error = .staleWindow
                    return
                }
                remainingStaleRetries -= 1
            } catch {
                self.error = .unavailable(error.localizedDescription)
                return
            }
        }
    }

    func setVisibleAnchor(messageIdHex: String) async {
        guard let subscription, let revision = snapshot?.revision else { return }
        do {
            await install(
                try await subscription.setVisibleAnchor(
                    revision: revision,
                    messageIdHex: messageIdHex,
                    timeoutMs: 0
                ))
        } catch is CancellationError {
            return
        } catch MarmotKitError.ConversationWindowStale {
            error = .staleWindow
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    @discardableResult
    func sendText(_ text: String, replyingTo replyToMessageIdHex: String? = nil) async throws
        -> LocalSendAcceptanceFfi
    {
        let clientToken = UUID().uuidString.lowercased()
        pendingSends[clientToken] = PendingDurableSend(
            id: clientToken,
            text: text,
            replyToMessageIdHex: replyToMessageIdHex,
            acceptedMessageIdHex: nil
        )
        do {
            let accepted: LocalSendAcceptanceFfi
            if let replyToMessageIdHex {
                accepted = try await runtime.replyToMessageWithClientToken(
                    accountRef: account.accountRef,
                    groupIdHex: groupIdHex,
                    targetMessageId: replyToMessageIdHex,
                    text: text,
                    clientToken: clientToken
                )
            } else {
                accepted = try await runtime.sendTextWithClientToken(
                    accountRef: account.accountRef,
                    groupIdHex: groupIdHex,
                    text: text,
                    clientToken: clientToken
                )
            }
            pendingSends[clientToken]?.acceptedMessageIdHex = accepted.messageIdHex
            return accepted
        } catch {
            pendingSends[clientToken] = nil
            throw error
        }
    }

    /// Sends a new poll. MDK accepts polls only in group conversations; the caller decides
    /// whether this conversation is one.
    func createPoll(_ submission: PollDraft.Submission) async throws {
        _ = try await runtime.createPoll(
            accountRef: account.accountRef,
            groupIdHex: groupIdHex,
            question: submission.question,
            options: submission.options,
            pollType: submission.pollType,
            endsAt: submission.endsAt
        )
    }

    /// The poll with any in-flight local vote applied.
    func displayedPoll(_ poll: MessagePoll, messageIdHex: String) -> MessagePoll {
        guard let pending = pendingPollSelections[messageIdHex] else { return poll }
        return PollPresentation.applyingLocalSelection(pending, to: poll)
    }

    /// Toggles `optionId` in this account's selection and publishes the whole new selection. The
    /// click shows immediately; a failed vote restores whatever was showing before it and rethrows.
    func votePoll(option optionId: String, messageIdHex: String, poll: MessagePoll, now: Date = .now) async throws {
        guard !messageIdHex.isEmpty, PollPresentation.isOpen(poll, now: now) else { return }
        let shown = displayedPoll(poll, messageIdHex: messageIdHex)
        guard
            let selection = PollPresentation.toggledSelection(
                current: shown.localSelection,
                option: optionId,
                kind: poll.kind,
                optionOrder: poll.options.map(\.id)
            )
        else { return }
        let attempt = PollVoteAttempt(id: UUID(), selection: selection)
        pollVoteAttempts[messageIdHex, default: []].append(attempt)
        pendingPollSelections[messageIdHex] = selection
        do {
            _ = try await runtime.castPollVote(
                accountRef: account.accountRef,
                groupIdHex: groupIdHex,
                pollEventId: messageIdHex,
                optionIds: selection
            )
        } catch {
            discardFailedPollVote(attempt, messageIdHex: messageIdHex)
            throw error
        }
    }

    /// Opens the "View votes" sheet for one poll. `poll` is MDK's tally for the row, without any
    /// in-flight local vote drawn over it: the sheet lists what MDK has projected.
    func showPollVotes(messageIdHex: String, poll: MessagePoll) {
        pollVotes?.cancel()
        pollVotesRecord = snapshot?.messages.first { $0.timeline.messageIdHex == messageIdHex }?.timeline
        let model = PollVotesViewModel(
            accountRef: account.accountRef,
            groupIdHex: groupIdHex,
            pollEventId: messageIdHex,
            poll: poll,
            runtime: runtime
        )
        // Started before the sheet is presented, so its first frame shows the read in flight
        // rather than an empty list.
        model.start()
        pollVotes = model
    }

    func dismissPollVotes() {
        pollVotes?.cancel()
        pollVotes = nil
        pollVotesRecord = nil
    }

    func localSendStatus(clientToken: String) async throws -> LocalSendStatusFfi? {
        try await FFIExecutor.run { [runtime, account, groupIdHex] in
            try runtime.localSendStatus(
                accountRef: account.accountRef,
                groupIdHex: groupIdHex,
                clientToken: clientToken
            )
        }
    }

    /// Loads accepted edit versions from the durable projection. The cursor is the oldest
    /// version already shown, matching MarmotKit's stable `(edited_at, message_id)` ordering.
    func editHistory(
        messageIdHex: String,
        before: TimelineEditVersionFfi?,
        limit: UInt32 = 100
    ) async throws -> TimelineEditHistoryPageFfi {
        try await FFIExecutor.run { [runtime, account, groupIdHex] in
            try runtime.messageEditHistory(
                accountRef: account.accountRef,
                groupIdHex: groupIdHex,
                targetMessageIdHex: messageIdHex,
                beforeEditedAt: before?.editedAt,
                beforeMessageIdHex: before?.messageIdHex,
                limit: limit
            )
        }
    }

    func saveDraft(
        content: String,
        replyToMessageIdHex: String?,
        attachments: [MessageDraftAttachmentFfi]
    ) async throws {
        guard let revision = snapshot?.draft.revision else { return }
        do {
            let selected = try await FFIExecutor.run { [runtime, account] in
                try runtime.saveMessageDraftIfRevision(
                    accountRef: account.accountRef,
                    revision: revision,
                    content: content,
                    replyToMessageIdHex: replyToMessageIdHex,
                    mediaAttachments: attachments
                )
            }
            snapshot?.draft = selected
        } catch MarmotKitError.MessageDraftRevisionConflict {
            error = .draftConflict
            throw MarmotKitError.MessageDraftRevisionConflict
        }
    }

    func clearDraft() async throws {
        guard let revision = snapshot?.draft.revision else { return }
        do {
            let selected = try await FFIExecutor.run { [runtime, account] in
                try runtime.clearMessageDraftIfRevision(accountRef: account.accountRef, revision: revision)
            }
            snapshot?.draft = selected
        } catch MarmotKitError.MessageDraftRevisionConflict {
            error = .draftConflict
            throw MarmotKitError.MessageDraftRevisionConflict
        }
    }

    private func runSubscription(
        mode: ConversationOpenModeFfi,
        messageIdHex: String?,
        timing: ProductAnalyticsRecorder.Timing?
    ) async {
        do {
            let subscription = try await runtime.openConversationWindow(
                accountRef: account.accountRef,
                groupIdHex: groupIdHex,
                mode: mode,
                messageIdHex: messageIdHex,
                initialRows: 50,
                timeoutMs: 0
            )
            try Task.checkCancellation()
            self.subscription = subscription
            guard let initial = runtime.conversationWindowSnapshot(subscription: subscription) else {
                throw CancellationError()
            }
            await install(initial)
            productAnalytics?.recordTiming(.timelineWindow, since: timing)
            let generation = initial.revision.generation

            while let replacement = try await runtime.nextConversationWindowSnapshot(subscription: subscription) {
                try Task.checkCancellation()
                guard replacement.revision.generation == generation else { break }
                await install(replacement)
            }
        } catch is CancellationError {
            return
        } catch {
            productAnalytics?.recordTiming(.timelineWindow, since: timing, outcome: .failure)
            self.error = .unavailable(error.localizedDescription)
            isLoading = false
        }
    }

    private func install(_ replacement: ConversationWindowSnapshotFfi, presents: Bool = true) async {
        // MarmotKit delivers a command's result both as its reply and as a stream echo, in either
        // order; ignore an equal or older sequence within the generation, so each window is
        // mapped and presented once rather than twice.
        if let current = snapshot {
            guard current.revision.generation == replacement.revision.generation,
                replacement.revision.sequence > current.revision.sequence
            else { return }
        }
        snapshot = replacement
        if capturesUnreadDivider {
            capturesUnreadDivider = false
            unreadDivider = Self.unreadDivider(in: replacement)
        }
        scheduleRetentionExpiry(for: replacement)
        let projectedTokens = Set(replacement.messages.compactMap(\.timeline.clientToken))
        for token in projectedTokens {
            pendingSends[token] = nil
        }
        clearProjectedPollSelections(in: replacement)
        reprojectPollVotes(in: replacement)
        error = nil
        isLoading = false
        if presents, let snapshotObserver {
            await present(replacement, to: snapshotObserver)
        }
    }

    private static func unreadDivider(in snapshot: ConversationWindowSnapshotFfi) -> ConversationUnreadDivider? {
        guard snapshot.anchor.kind == .firstUnread,
            snapshot.readState.unreadCount > 0,
            let messageIdHex = snapshot.readState.firstUnreadMessageIdHex
        else { return nil }
        return ConversationUnreadDivider(messageIdHex: messageIdHex, unreadCount: snapshot.readState.unreadCount)
    }

    /// Forgets one failed vote. Only the newest vote owns the overlay, so an older failure leaves
    /// it alone; the newest failing hands the overlay to the latest vote still standing, or clears
    /// it so MDK's own tally shows.
    private func discardFailedPollVote(_ attempt: PollVoteAttempt, messageIdHex: String) {
        guard var attempts = pollVoteAttempts[messageIdHex],
            let index = attempts.firstIndex(where: { $0.id == attempt.id })
        else { return }
        let wasCurrent = index == attempts.index(before: attempts.endIndex)
        attempts.remove(at: index)
        pollVoteAttempts[messageIdHex] = attempts.isEmpty ? nil : attempts
        if wasCurrent {
            pendingPollSelections[messageIdHex] = attempts.last?.selection
        }
    }

    /// Drops each in-flight vote once MDK projects the same selection, so the overlay never
    /// outlives the vote it stands in for.
    private func clearProjectedPollSelections(in snapshot: ConversationWindowSnapshotFfi) {
        guard !pendingPollSelections.isEmpty else { return }
        for message in snapshot.messages {
            let id = message.timeline.messageIdHex
            guard let pending = pendingPollSelections[id], let poll = message.timeline.poll,
                Set(poll.localSelection) == Set(pending)
            else { continue }
            pendingPollSelections[id] = nil
            pollVoteAttempts[id] = nil
        }
    }

    /// Refreshes the open "View votes" list when this snapshot carries its poll's row and the row
    /// changed. A snapshot whose window no longer holds the row says nothing about it, so the list
    /// stays as it is. An unchanged row can still hide a change in who voted for what (two voters
    /// swapping options), which the model's own poll-response observation covers.
    private func reprojectPollVotes(in snapshot: ConversationWindowSnapshotFfi) {
        guard let pollVotes,
            let record = snapshot.messages.first(where: { $0.timeline.messageIdHex == pollVotes.pollEventId })?
                .timeline,
            record != pollVotesRecord
        else { return }
        pollVotesRecord = record
        pollVotes.reproject(poll: record.deleted ? nil : record.poll.map(MessagePoll.init(projection:)))
    }

    private func scheduleRetentionExpiry(for snapshot: ConversationWindowSnapshotFfi) {
        retentionExpiryTask?.cancel()
        retentionExpiryTask = nil
        guard
            let expiresAt = snapshot.messages.compactMap(\.timeline.retentionExpiresAt).filter({ $0 > 0 }).min()
        else { return }

        let deadlineMilliseconds = expiresAt.multipliedReportingOverflow(by: 1_000)
        guard !deadlineMilliseconds.overflow else { return }
        let runtime = runtime
        let accountRef = account.accountRef
        retentionExpiryTask = Task { [weak self] in
            let nowMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
            if deadlineMilliseconds.partialValue > nowMilliseconds {
                let delayMilliseconds = deadlineMilliseconds.partialValue - nowMilliseconds
                do {
                    try await Task.sleep(for: .milliseconds(Int64(clamping: delayMilliseconds)))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let sweepNowMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
            _ = try? await runtime.sweepExpiredRetention(
                accountRef: accountRef,
                nowMs: sweepNowMilliseconds
            )
            guard !Task.isCancelled else { return }
            self?.retentionExpiryTask = nil
        }
    }
}
