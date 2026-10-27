import Foundation
import MarmotKit
import Observation

enum AccountAttentionValue: Equatable {
    case ready(AccountAttentionTotalFfi)
    case unavailable(AccountAttentionUnavailableFfi)
}

@MainActor
@Observable
final class AccountAttentionViewModel {
    private(set) var valuesByAccountId: [String: AccountAttentionValue] = [:]
    private(set) var error: ChatListFeatureError?
    /// The app-icon badge across every signed-in account, or `nil` while it is not known:
    /// before the first snapshot, or while an account is unavailable with no earlier total.
    private(set) var applicationBadgeCount: Int?

    /// An account that turns unavailable keeps counting its last ready total, so a transient
    /// unavailability does not blank the Dock badge.
    @ObservationIgnored private var lastReadyTotalsByAccountId: [String: AccountAttentionTotalFfi] = [:]

    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?

    init(runtime: any MarmotRuntime) {
        self.runtime = runtime
    }

    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in
            await self?.runSubscription()
        }
    }

    func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    func unreadCount(accountIdHex: String) -> Int? {
        guard case .ready(let total) = valuesByAccountId[accountIdHex.lowercased()] else { return nil }
        return Int(clamping: ApplicationBadgeCountProjection.contribution(for: total))
    }

    func mentionCount(accountIdHex: String) -> Int? {
        guard case .ready(let total) = valuesByAccountId[accountIdHex.lowercased()] else { return nil }
        return Int(clamping: total.unreadMentionCount)
    }

    private func runSubscription() async {
        var retryNanoseconds: UInt64 = 250_000_000
        while !Task.isCancelled {
            do {
                let subscription = try await runtime.subscribeAccountAttention()
                try Task.checkCancellation()
                guard let initial = runtime.accountAttentionSnapshot(subscription: subscription) else {
                    throw CancellationError()
                }
                install(initial)
                let generation = initial.subscriptionGeneration
                var sequence = initial.sequence
                retryNanoseconds = 250_000_000

                while let update = try await runtime.nextAccountAttentionSnapshot(subscription: subscription) {
                    try Task.checkCancellation()
                    guard update.subscriptionGeneration == generation else { break }
                    guard update.sequence > sequence else { continue }
                    sequence = update.sequence
                    install(update)
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = .unavailable(error.localizedDescription)
            }

            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: retryNanoseconds)
            } catch {
                return
            }
            retryNanoseconds = min(retryNanoseconds * 2, 4_000_000_000)
        }
    }

    private func install(_ snapshot: AccountAttentionSnapshotFfi) {
        valuesByAccountId = Dictionary(
            uniqueKeysWithValues: snapshot.accounts.map { entry in
                let value: AccountAttentionValue
                switch entry.state {
                case .ready(let total):
                    value = .ready(total)
                case .unavailable(let reason):
                    value = .unavailable(reason)
                }
                return (entry.accountIdHex.lowercased(), value)
            }
        )
        lastReadyTotalsByAccountId = valuesByAccountId.reduce(into: [:]) { totals, entry in
            switch entry.value {
            case .ready(let total):
                totals[entry.key] = total
            case .unavailable:
                totals[entry.key] = lastReadyTotalsByAccountId[entry.key]
            }
        }
        error = nil
        applicationBadgeCount = projectApplicationBadgeCount()
    }

    private func projectApplicationBadgeCount() -> Int? {
        var totals: [AccountAttentionTotalFfi] = []
        for (accountIdHex, value) in valuesByAccountId {
            switch value {
            case .ready(let total):
                totals.append(total)
            case .unavailable:
                guard let lastReady = lastReadyTotalsByAccountId[accountIdHex] else { return nil }
                totals.append(lastReady)
            }
        }
        return ApplicationBadgeCountProjection.count(for: totals)
    }
}
