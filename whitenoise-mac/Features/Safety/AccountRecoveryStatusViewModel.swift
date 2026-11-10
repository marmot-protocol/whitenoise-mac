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
/// The runner also makes short routine fetches, and MDK reports each survey change, even one the
/// next survey undoes. So a chat or the inbox shows as catching up only once it has stayed so for
/// `showDelay` without a break, and stops showing as soon as MDK says it is done.
///
/// The notices `accountRecoveryStatus` also returns stay with `HistoryNoticesViewModel`, which owns
/// their dismissal. Owned by `AccountScope`, so an account switch discards it.
@MainActor
@Observable
final class AccountRecoveryStatusViewModel {
    /// How long a chat or the inbox must stay catching up before it shows.
    static let defaultShowDelay: Duration = .seconds(2)

    /// MDK's last status, as read.
    private(set) var catchingUpGroupIds: Set<String> = []
    private(set) var inboxCatchingUp = false
    /// What the views show: the part of MDK's status that has lasted `showDelay`.
    private var shownGroupIds: Set<String> = []
    private var showsInbox = false

    private enum Unit: Hashable {
        case inbox
        case group(String)
    }

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let accountIdHex: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let showDelay: Duration
    @ObservationIgnored private let clock = ContinuousClock()
    /// When each unit MDK reports began its current unbroken stretch of catching up.
    @ObservationIgnored private var catchingUpSince: [Unit: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readRequested = false

    init(
        accountRef: String, accountIdHex: String, runtime: (any MarmotRuntime)?,
        showDelay: Duration = defaultShowDelay
    ) {
        self.accountRef = accountRef
        self.accountIdHex = accountIdHex.lowercased()
        self.runtime = runtime
        self.showDelay = showDelay
    }

    static func preview(catchingUpGroupIds: Set<String> = [], inboxCatchingUp: Bool = false)
        -> AccountRecoveryStatusViewModel
    {
        let model = AccountRecoveryStatusViewModel(
            accountRef: "preview", accountIdHex: "preview", runtime: nil, showDelay: .zero)
        model.install(groupIds: catchingUpGroupIds, inbox: inboxCatchingUp)
        return model
    }

    /// Whether anything for this account has been catching up for a while.
    var isCatchingUp: Bool {
        showsInbox || !shownGroupIds.isEmpty
    }

    func isCatchingUp(groupIdHex: String) -> Bool {
        shownGroupIds.contains(groupIdHex.lowercased())
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
        settleTask?.cancel()
        settleTask = nil
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
            install(groupIds: Set(status.catchingUpGroupIdsHex.map { $0.lowercased() }), inbox: status.inboxCatchingUp)
        } catch is CancellationError {
            return
        } catch {
            // Keep the last status: an unreadable refresh says nothing about whether catch-up ended.
        }
    }

    private func install(groupIds: Set<String>, inbox: Bool) {
        catchingUpGroupIds = groupIds
        inboxCatchingUp = inbox
        let units = Set(groupIds.map(Unit.group)).union(inbox ? [.inbox] : [])
        let now = clock.now
        // A unit MDK stopped reporting loses its stretch, so a later report starts the wait over.
        catchingUpSince = catchingUpSince.filter { units.contains($0.key) }
        for unit in units where catchingUpSince[unit] == nil {
            catchingUpSince[unit] = now
        }
        settle()
    }

    /// Shows every unit whose stretch has lasted `showDelay`, then waits for the next one due.
    private func settle() {
        let now = clock.now
        var shownGroups: Set<String> = []
        var inbox = false
        var nextDue: ContinuousClock.Instant?
        for (unit, since) in catchingUpSince {
            let due = since + showDelay
            guard due <= now else {
                nextDue = min(nextDue ?? due, due)
                continue
            }
            switch unit {
            case .inbox: inbox = true
            case .group(let id): shownGroups.insert(id)
            }
        }
        if shownGroupIds != shownGroups { shownGroupIds = shownGroups }
        if showsInbox != inbox { showsInbox = inbox }

        settleTask?.cancel()
        settleTask = nil
        guard let nextDue else { return }
        settleTask = Task { [weak self, clock] in
            try? await clock.sleep(until: nextDue)
            guard !Task.isCancelled else { return }
            self?.settle()
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
