import Foundation
import MarmotKit
import Observation

/// What MDK's recovery runner is still fetching for the signed-in account (MarmotKit 0.15).
///
/// After time offline the runner catches each group up in order, and a group's newer live messages
/// wait until its fetched backlog is admitted. `accountRecoveryStatus` says which groups and whether
/// the account inbox (invitations, new chats) are still catching up; the views show that as
/// "Catching up" so a quiet chat does not read as an empty one. Re-read on `RecoveryStatusChanged`.
///
/// The notices `accountRecoveryStatus` also returns stay with `HistoryNoticesViewModel`, which owns
/// their dismissal. Owned by `AccountScope`, so an account switch discards it.
@MainActor
@Observable
final class AccountRecoveryStatusViewModel {
    private(set) var catchingUpGroupIds: Set<String> = []
    private(set) var inboxCatchingUp = false

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

    static func preview(catchingUpGroupIds: Set<String> = [], inboxCatchingUp: Bool = false)
        -> AccountRecoveryStatusViewModel
    {
        let model = AccountRecoveryStatusViewModel(accountRef: "preview", accountIdHex: "preview", runtime: nil)
        model.catchingUpGroupIds = catchingUpGroupIds
        model.inboxCatchingUp = inboxCatchingUp
        return model
    }

    /// Whether anything for this account is still being fetched.
    var isCatchingUp: Bool {
        inboxCatchingUp || !catchingUpGroupIds.isEmpty
    }

    func isCatchingUp(groupIdHex: String) -> Bool {
        catchingUpGroupIds.contains(groupIdHex.lowercased())
    }

    /// Subscribes before the first read, so a change between the two still arrives.
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

    /// Re-reads the status. Reads never overlap: a request made while one is in flight runs once
    /// more after it, so the last status installed is always the newest read.
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

    private func readOnce() async {
        guard let runtime else { return }
        do {
            let status = try await runtime.accountRecoveryStatus(accountRef: accountRef)
            try Task.checkCancellation()
            catchingUpGroupIds = Set(status.catchingUpGroupIdsHex.map { $0.lowercased() })
            inboxCatchingUp = status.inboxCatchingUp
        } catch is CancellationError {
            return
        } catch {
            // Keep the last status: an unreadable refresh says nothing about whether catch-up ended.
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
            if case .recoveryStatusChanged(let changedAccountIdHex, _) = event,
                changedAccountIdHex.lowercased() == accountIdHex
            {
                await refresh()
            }
        }
    }
}
