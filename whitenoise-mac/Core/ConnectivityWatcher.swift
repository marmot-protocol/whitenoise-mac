//
//  ConnectivityWatcher.swift
//  whitenoise-mac
//
//  Turns interface readings and relay probes into the offline answer behind the
//  "Waiting for internet connection" notice.
//

import Foundation
import os

/// The offline state over time, from the two-stage check: first whether macOS reports any
/// interface, then whether a relay answers a TCP handshake over it.
///
/// Three things the plain "probe once per path change" loop got wrong, and this owns:
///
/// - **Recovery.** While offline with an interface present, the relays are re-probed on
///   `offlineRecheckInterval` until one answers. A path change is not the only way a network
///   comes back, and waiting for one left the notice up over a working connection.
/// - **Patience.** Going offline needs the interface gone for `interfaceLossGrace`, or
///   `failedProbesBeforeOffline` failed probes in a row, so a momentary blip never flashes the
///   notice.
/// - **Staleness.** A new interface reading cancels the evaluation of the previous one, so a
///   probe that started before the network moved cannot report on a network that is gone.
nonisolated struct ConnectivityWatcher: Sendable {
    let interfaceMonitor: any NetworkInterfaceMonitoring
    let probe: any RelayHostReachabilityProbing
    let policy: ConnectivityPolicy

    /// `true` while offline, `false` while online. Yields only when the answer changes, and
    /// nothing at all until there is an answer — the consumer's own default (online) stands
    /// until the first evaluation settles. Finishes when the interface stream does, or when
    /// the consumer stops iterating.
    func offlineStates(probing endpoints: [RelayHostEndpoint]) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                await run(endpoints: endpoints, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(endpoints: [RelayHostEndpoint], continuation: AsyncStream<Bool>.Continuation) async {
        let reporter = OfflineReporter(continuation: continuation)
        var evaluation: Task<Void, Never>?

        for await hasInterface in interfaceMonitor.interfaceAvailability() {
            // Awaited, not just cancelled: evaluations never overlap, so the reporter only ever
            // hears from the one that describes the current interface reading. Cancellation
            // settles the old one promptly — its sleeps throw and the TCP probe's timeout child
            // cancels the socket.
            evaluation?.cancel()
            await evaluation?.value
            evaluation = Task {
                await evaluate(hasInterface: hasInterface, endpoints: endpoints, reporter: reporter)
            }
        }

        if Task.isCancelled {
            evaluation?.cancel()
        }
        // The interface stream only finishes on its own for a scripted monitor; the evaluation
        // of its last reading is still the answer, so it runs to the end rather than being cut.
        await evaluation?.value
    }

    private func evaluate(
        hasInterface: Bool,
        endpoints: [RelayHostEndpoint],
        reporter: OfflineReporter
    ) async {
        guard hasInterface else {
            if !reporter.isOffline {
                do {
                    try await policy.sleep(policy.interfaceLossGrace)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            reporter.report(offline: true)
            return
        }

        // Fails open: an unparseable relay list is not evidence about the user's network.
        guard !endpoints.isEmpty else {
            reporter.report(offline: false)
            return
        }

        var consecutiveFailures = 0
        while !Task.isCancelled {
            let isReachable = await probe.canReachAnyHost(endpoints)
            guard !Task.isCancelled else { return }

            if isReachable {
                reporter.report(offline: false)
                return
            }

            consecutiveFailures += 1
            if consecutiveFailures >= policy.failedProbesBeforeOffline {
                reporter.report(offline: true)
            }

            let pause = reporter.isOffline ? policy.offlineRecheckInterval : policy.confirmationRetryDelay
            do {
                try await policy.sleep(pause)
            } catch {
                return
            }
        }
    }
}

/// The last answer handed to the consumer, so repeats are swallowed and an evaluation can ask
/// whether the notice is already up. Evaluations never overlap, so the lock only has to make
/// the hand-off between successive tasks visible, not arbitrate a race.
private nonisolated final class OfflineReporter: Sendable {
    private let continuation: AsyncStream<Bool>.Continuation
    private let reported = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    init(continuation: AsyncStream<Bool>.Continuation) {
        self.continuation = continuation
    }

    var isOffline: Bool {
        reported.withLock { $0 == true }
    }

    func report(offline: Bool) {
        let changed = reported.withLock { reported in
            guard reported != offline else { return false }
            reported = offline
            return true
        }
        if changed {
            continuation.yield(offline)
        }
    }
}
