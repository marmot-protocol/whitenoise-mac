import Foundation
import MarmotKit
import Observation

/// Per-relay connection state for the Relays page, from MarmotKit 0.16.0's relay liveness.
///
/// `observe()` is the page's lifetime: it subscribes when the page appears and runs until the
/// page's task is cancelled, which cancels the MDK subscription. Cancelling stops the updates
/// only; it never disconnects a relay. Each list MDK sends is complete, so it replaces the last
/// one rather than merging into it.
@MainActor
@Observable
final class RelayLivenessViewModel {
    /// Keyed by `RelayURLValidator.identity`, so an MDK-canonicalized URL finds the row it
    /// belongs to.
    private(set) var connections: [String: RelayConnection] = [:]
    private(set) var reconnectingRelayIDs: Set<String> = []
    /// The last failed reconnect, by relay identity, until that relay is reconnected again.
    private(set) var reconnectErrors: [String: String] = [:]

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    /// The subscription whose lists `connections` shows. Compared by identity so an observer that
    /// ends after its replacement started (the page reappeared) neither applies nor clears
    /// anything; cancelling a task cannot do that, because the old task's cleanup still runs.
    @ObservationIgnored private var activeSubscription: RelayLivenessSubscription?

    init(accountRef: String, runtime: (any MarmotRuntime)?) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    func connection(for url: String) -> RelayConnection? {
        connections[RelayURLValidator.identity(url)]
    }

    func isReconnecting(_ url: String) -> Bool {
        reconnectingRelayIDs.contains(RelayURLValidator.identity(url))
    }

    func reconnectError(for url: String) -> String? {
        reconnectErrors[RelayURLValidator.identity(url)]
    }

    /// Follows the account's relay liveness until the calling task is cancelled.
    func observe() async {
        guard let runtime else { return }
        let subscription: RelayLivenessSubscription
        do {
            subscription = try await runtime.subscribeRelayLiveness(accountRef: accountRef)
        } catch {
            // Liveness is an enhancement to the page: without it rows show no connection state,
            // and the relay lists themselves still load and save.
            return
        }
        activeSubscription = subscription
        // MDK's `next()` keeps waiting after its Swift task is cancelled; `cancel()` is what
        // wakes it, with `nil`.
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            apply(runtime.relayLivenessSnapshot(subscription: subscription), from: subscription)
            while !Task.isCancelled {
                guard let rows = try? await runtime.nextRelayLiveness(subscription: subscription) else { return }
                guard !Task.isCancelled else { return }
                apply(rows, from: subscription)
            }
        } onCancel: {
            runtime.cancelRelayLiveness(subscription: subscription)
        }
        runtime.cancelRelayLiveness(subscription: subscription)
        // Nothing is following these relays any more, so their last state is not live state.
        if activeSubscription === subscription {
            activeSubscription = nil
            connections = [:]
        }
    }

    func reconnect(_ url: String) async {
        guard let runtime else { return }
        let key = RelayURLValidator.identity(url)
        guard !reconnectingRelayIDs.contains(key) else { return }
        reconnectingRelayIDs.insert(key)
        reconnectErrors[key] = nil
        defer { reconnectingRelayIDs.remove(key) }
        do {
            let row = try await runtime.reconnectRelay(accountRef: accountRef, url: url)
            // While observing, the subscription is the source of truth and reports the result
            // itself; this answer may already be older than its latest list.
            guard !Task.isCancelled, activeSubscription == nil else { return }
            connections[RelayURLValidator.identity(row.url)] = RelayConnection(liveness: row)
        } catch is CancellationError {
            return
        } catch {
            reconnectErrors[key] = UserFacingError.message(for: error)
        }
    }

    private func apply(_ rows: [RelayLivenessFfi], from subscription: RelayLivenessSubscription) {
        guard activeSubscription === subscription else { return }
        connections = Dictionary(
            rows.map { (RelayURLValidator.identity($0.url), RelayConnection(liveness: $0)) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    static func preview(_ connections: [String: RelayConnection] = [:]) -> RelayLivenessViewModel {
        let model = RelayLivenessViewModel(accountRef: "preview", runtime: nil)
        model.connections = Dictionary(
            connections.map { (RelayURLValidator.identity($0.key), $0.value) },
            uniquingKeysWith: { _, latest in latest })
        return model
    }
}
