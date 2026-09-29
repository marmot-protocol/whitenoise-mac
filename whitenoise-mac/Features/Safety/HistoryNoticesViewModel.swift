import Foundation
import MarmotKit
import Observation

/// Localized wording for MDK's "history may be incomplete" notices, shared with iOS.
///
/// Notices carry no relay, message or key identities; keep them out of analytics.
nonisolated enum HistoryNoticePresentation {
    static func message(for cause: HistoryNoticeCauseFfi) -> String {
        switch cause {
        case .deliveryLoss, .notificationLoss:
            L10n.string("Some messages may not have reached this device.")
        case .epochGap:
            L10n.string("Some messages in this chat may be missing.")
        case .incrementalHistory:
            L10n.string("Messages from while you were away may be incomplete.")
        case .explicitRepair:
            L10n.string("History repair couldn’t confirm that every message was restored.")
        case .knownEvent:
            L10n.string("A message couldn’t be retrieved.")
        case .maintenanceBoundary:
            L10n.string("Messages from around when you joined may be incomplete.")
        }
    }

    /// A group's recovery status lists notice ids without causes; one missing from the account
    /// list (not read yet, or already re-armed) is still a group-scoped epoch gap.
    static func groupMessage(noticeIds: [String], notices: [HistoryNoticeFfi]) -> String {
        let cause = notices.first { noticeIds.contains($0.noticeId) }?.cause ?? .epochGap
        return message(for: cause)
    }
}

/// The signed-in account's durable "history may be incomplete" notices.
///
/// MDK owns the state: a parked recovery keeps the account's transport cursor fenced until the
/// user dismisses its notice, so this mirrors the list and routes the user's dismissal back. It
/// never dismisses on the user's behalf and never stores a `noticeId`, which changes whenever
/// recovery re-arms. Owned by `AccountScope`, so an account switch discards it instead of
/// resetting it.
@MainActor
@Observable
final class HistoryNoticesViewModel {
    private(set) var notices: [HistoryNoticeFfi] = []
    private(set) var dismissing: Set<String> = []
    private(set) var error: String?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let accountIdHex: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readRequested = false

    init(accountRef: String, accountIdHex: String, runtime: (any MarmotRuntime)?) {
        self.accountRef = accountRef
        self.accountIdHex = accountIdHex.lowercased()
        self.runtime = runtime
    }

    static func preview(notices: [HistoryNoticeFfi]) -> HistoryNoticesViewModel {
        let model = HistoryNoticesViewModel(accountRef: "preview", accountIdHex: "preview", runtime: nil)
        model.notices = notices
        return model
    }

    var accountNotices: [HistoryNoticeFfi] {
        notices.filter { $0.groupIdHex == nil }
    }

    func notices(forGroup groupIdHex: String) -> [HistoryNoticeFfi] {
        notices.filter { $0.groupIdHex?.lowercased() == groupIdHex.lowercased() }
    }

    func isDismissing(_ noticeIds: [String]) -> Bool {
        !dismissing.isDisjoint(with: noticeIds)
    }

    /// Subscribes before the first read, so a notice that parks between the two still arrives.
    func start() {
        guard eventsTask == nil, let runtime else { return }
        let subscription = runtime.subscribeEvents()
        eventsTask = Task { [weak self] in
            await self?.refresh()
            await self?.observe(subscription)
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        readTask?.cancel()
        readTask = nil
    }

    /// Re-reads the list. Reads never overlap: a request made while one is in flight runs once
    /// more after it, so the last list installed is always the newest read.
    func refresh() async {
        readRequested = true
        while readRequested {
            if let readTask {
                await readTask.value
                continue
            }
            readRequested = false
            let task = Task { [weak self] in
                await self?.readOnce()
                self?.readTask = nil
            }
            readTask = task
            await task.value
        }
    }

    /// Dismisses each occurrence and re-reads. A `false` answer means the id went stale (the
    /// notice re-armed or was already dismissed); the re-read shows what is current.
    @discardableResult
    func dismiss(_ noticeIds: [String]) async -> Bool {
        guard let runtime, !noticeIds.isEmpty, dismissing.isDisjoint(with: noticeIds) else { return false }
        dismissing.formUnion(noticeIds)
        var allDismissed = true
        do {
            for noticeId in noticeIds {
                let dismissed = try await runtime.dismissHistoryNotice(accountRef: accountRef, noticeId: noticeId)
                allDismissed = allDismissed && dismissed
            }
            error = nil
        } catch is CancellationError {
            allDismissed = false
        } catch {
            allDismissed = false
            self.error = L10n.string("Couldn’t dismiss notice")
        }
        dismissing.subtract(noticeIds)
        await refresh()
        return allDismissed
    }

    private func readOnce() async {
        guard let runtime else { return }
        do {
            let next = try await runtime.historyNotices(accountRef: accountRef)
            try Task.checkCancellation()
            notices = next
        } catch is CancellationError {
            return
        } catch {
            // Keep the last list: an unreadable refresh is not evidence the notices went away.
        }
    }

    private func observe(_ subscription: EventsSubscription) async {
        guard let runtime else { return }
        while !Task.isCancelled {
            let event: MarmotEventFfi?
            do {
                event = try await runtime.nextEvent(subscription: subscription)
            } catch {
                return
            }
            guard let event else { return }
            if case .historyNoticesChanged(let changedAccountIdHex, _) = event,
                changedAccountIdHex.lowercased() == accountIdHex
            {
                await refresh()
            }
        }
    }
}
