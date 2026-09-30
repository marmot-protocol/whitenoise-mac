import Foundation
import MarmotKit
import Observation

enum ConversationFeatureError: Equatable {
    case unavailable(String)
    case staleWindow
    case draftConflict
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
    private(set) var snapshot: ConversationWindowSnapshotFfi?
    private(set) var pendingSends: [String: PendingDurableSend] = [:]
    private(set) var isLoading = false
    private(set) var isPaging = false
    private(set) var error: ConversationFeatureError?
    /// Set from the first snapshot of an open that MarmotKit anchored on the first unread row.
    private(set) var unreadDivider: ConversationUnreadDivider?
    /// True once a snapshot has been handed to the snapshot observer, i.e. the host transcript
    /// renders this window's rows rather than whatever it showed before. The transcript waits
    /// for this before positioning at the divider or treating its scroll position as reading.
    private(set) var hasPresentedWindow = false
    /// Whether the transcript is scrolled to the foot of the rendered window. The snapshot host
    /// reads it to decide whether a replacement may advance the read marker. Ignored by
    /// observation: the transcript writes it on scroll-edge crossings and no view renders it.
    @ObservationIgnored private(set) var isAtWindowBottom = false

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
    }

    func start(mode: ConversationOpenModeFfi = .automatic, messageIdHex: String? = nil) {
        stop()
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
            hasPresentedWindow = true
        }
    }

    func setAtWindowBottom(_ isAtWindowBottom: Bool) {
        self.isAtWindowBottom = isAtWindowBottom
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
        if capturesUnreadDivider {
            capturesUnreadDivider = false
            unreadDivider = Self.unreadDivider(in: replacement)
        }
        scheduleRetentionExpiry(for: replacement)
        let projectedTokens = Set(replacement.messages.compactMap(\.timeline.clientToken))
        for token in projectedTokens {
            pendingSends[token] = nil
        }
        error = nil
        isLoading = false
        if let snapshotObserver {
            await snapshotObserver(replacement)
            hasPresentedWindow = true
        }
    }

    private static func unreadDivider(in snapshot: ConversationWindowSnapshotFfi) -> ConversationUnreadDivider? {
        guard snapshot.anchor.kind == .firstUnread,
            snapshot.readState.unreadCount > 0,
            let messageIdHex = snapshot.readState.firstUnreadMessageIdHex
        else { return nil }
        return ConversationUnreadDivider(messageIdHex: messageIdHex, unreadCount: snapshot.readState.unreadCount)
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
