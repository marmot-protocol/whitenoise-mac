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
        // The page went away while the subscribe was pending (UniFFI does not forward Swift
        // cancellation into it). A visit that has ended never takes the screen: a newer one may
        // already own it.
        guard !Task.isCancelled else {
            runtime.cancelRelayLiveness(subscription: subscription)
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
