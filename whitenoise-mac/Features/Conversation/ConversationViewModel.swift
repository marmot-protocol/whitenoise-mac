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
    private(set) var snapshot: ConversationWindowSnapshotFfi?
    private(set) var pendingSends: [String: PendingDurableSend] = [:]
    private(set) var isLoading = false
    private(set) var isPaging = false
    private(set) var error: ConversationFeatureError?
    /// In-flight votes keyed by poll message id, drawn over MDK's tally until a snapshot projects
    /// the same selection or the vote fails.
    private(set) var pendingPollSelections: [String: [String]] = [:]
    /// Every vote per poll message that has not failed or been confirmed by a snapshot, oldest
    /// first. A failed vote falls back to the newest survivor rather than to whatever it replaced,
    /// which may itself have failed in the meantime.
    @ObservationIgnored private var pollVoteAttempts: [String: [PollVoteAttempt]] = [:]

    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private let productAnalytics: ProductAnalyticsRecorder?
    @ObservationIgnored private var subscription: ConversationWindowSubscription?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    /// One deadline task is sufficient because every completed sweep causes the authoritative
    /// conversation subscription to replace the snapshot. Cancelling the model therefore fences
    /// both paging and expiry work without a separate staleness generation.
    @ObservationIgnored private var retentionExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotObserver: (@MainActor (ConversationWindowSnapshotFfi) async -> Void)?

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
    }

    func start(mode: ConversationOpenModeFfi = .latest, messageIdHex: String? = nil) {
        stop()
        isLoading = snapshot == nil
        let timing = productAnalytics?.beginTiming()
        subscriptionTask = Task { [weak self] in
            await self?.runSubscription(
                mode: mode,
                messageIdHex: messageIdHex,
                timing: timing
            )
        }
    }

    func stop() {
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
            await observer(snapshot)
        }
    }

    func page(_ direction: ConversationPageDirectionFfi, count: UInt32 = 50) async {
        guard !isPaging, let subscription, let revision = snapshot?.revision else { return }
        if direction == .older, snapshot?.hasMoreBefore != true { return }
        if direction == .newer, snapshot?.hasMoreAfter != true { return }
        isPaging = true
        defer { isPaging = false }
        do {
            let replacement = try await subscription.page(
                revision: revision,
                direction: direction,
                count: count,
                timeoutMs: 0
            )
            await install(replacement)
        } catch is CancellationError {
            return
        } catch MarmotKitError.ConversationWindowStale {
            self.error = .staleWindow
        } catch {
            self.error = .unavailable(error.localizedDescription)
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

    func returnToLatest() async {
        guard let subscription, let revision = snapshot?.revision else { return }
        do {
            await install(try await subscription.returnToLatest(revision: revision, timeoutMs: 0))
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
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

    private func install(_ replacement: ConversationWindowSnapshotFfi) async {
        if let current = snapshot {
            guard current.revision.generation == replacement.revision.generation,
                replacement.revision.sequence >= current.revision.sequence
            else { return }
        }
        snapshot = replacement
        scheduleRetentionExpiry(for: replacement)
        let projectedTokens = Set(replacement.messages.compactMap(\.timeline.clientToken))
        for token in projectedTokens {
            pendingSends[token] = nil
        }
        clearProjectedPollSelections(in: replacement)
        error = nil
        isLoading = false
        await snapshotObserver?(replacement)
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
