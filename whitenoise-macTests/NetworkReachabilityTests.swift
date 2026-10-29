//
//  NetworkReachabilityTests.swift
//  whitenoise-macTests
//
//  Guards on the offline detection behind the "Waiting for internet connection"
//  notice.
//
//  The mistake these exist to catch is a banner that lies in either direction: a
//  machine with Wi-Fi joined but no route to a relay reported as online (the
//  captive-portal case the OS is happy about), or a working connection reported
//  as offline because a relay list failed to parse. Neither is visible from the
//  interface state alone, which is why the check has two stages.
//

import Foundation
import Testing
import os

@testable import whitenoise_mac

@Suite(.serialized)
struct NetworkReachabilityTests {

    // MARK: - Relay endpoints

    @Test func relayURLsFallBackToTheSchemeDefaultPort() {
        // A relay URL almost never carries a port, so the fallback is the common path rather
        // than an edge case: getting it wrong points every probe at the wrong socket and the
        // app declares itself permanently offline.
        #expect(RelayHostEndpoint(relayURL: "wss://relay.example.com") == .init(host: "relay.example.com", port: 443))
        #expect(RelayHostEndpoint(relayURL: "ws://localhost") == .init(host: "localhost", port: 80))
        #expect(RelayHostEndpoint(relayURL: "WSS://relay.example.com") == .init(host: "relay.example.com", port: 443))
        #expect(RelayHostEndpoint(relayURL: "ws://localhost:7777") == .init(host: "localhost", port: 7777))
        #expect(RelayHostEndpoint(relayURL: "  wss://relay.example.com  ")?.host == "relay.example.com")
    }

    @Test func relayURLsWithoutAHostAreDropped() {
        // Dropped rather than substituted: an unparseable entry is not a network failure, and
        // letting one stand in for a host would have a bad relay line answer for the whole list.
        #expect(RelayHostEndpoint(relayURL: "") == nil)
        #expect(RelayHostEndpoint(relayURL: "not a url") == nil)
        #expect(RelayHostEndpoint(relayURL: "wss://") == nil)
        #expect(
            RelayHostEndpoint.endpoints(from: ["wss://", "wss://relay.example.com"])
                == [.init(host: "relay.example.com", port: 443)]
        )
    }

    @Test func theSeedRelaysAreWhatGetsProbed() {
        // The offline check probes the same hosts the app actually talks to. If the seed list
        // moves, this is the reminder that the reachability check moves with it.
        #expect(
            RelayHostEndpoint.endpoints(from: MarmotClient.seedRelays) == [
                .init(host: "relay.eu.whitenoise.chat", port: 443),
                .init(host: "relay.us.whitenoise.chat", port: 443),
            ]
        )
    }

    @Test func anEmptyEndpointListIsNotProbed() async {
        // No sockets are opened here — the guard returns before the probe would reach the
        // network, which is the only reason this assertion is safe to make in a unit test.
        #expect(await TCPRelayHostProbe(timeout: .milliseconds(1)).canReachAnyHost([]) == false)
    }

    // MARK: - Wording

    @Test func theOfflineNoticeSharesItsWordingWithTheOtherClients() {
        #expect(
            L10n.string("Waiting for internet connection", locale: Locale(identifier: "es"))
                == "Esperando conexión a internet"
        )
    }

    // MARK: - Offline state

    @MainActor
    @Test func noNetworkInterfaceIsOfflineWithoutProbingRelays() async {
        // The cheap question comes first. With no interface there is nothing to probe, and
        // spending three seconds on a socket that cannot leave the machine would delay the
        // banner past the point where it is useful.
        let probe = RecordingRelayProbe(answers: [true])
        let state = WorkspaceState(
            clientFactory: { throw TestConnectivityError() },
            networkInterfaceMonitor: ScriptedInterfaceMonitor(availability: [false]),
            relayHostProbe: probe,
            connectivityPolicy: ScriptedSleeper().policy
        )

        state.startConnectivityMonitoring()
        await state.connectivityMonitorTask?.value

        #expect(state.isOffline)
        #expect(probe.recordedEndpoints.isEmpty)
    }

    @MainActor
    @Test func anInterfaceWithNoReachableRelayIsStillOffline() async {
        // The case the OS cannot see and the whole second stage exists for: Wi-Fi joined, a
        // captive portal or a dead uplink behind it, and not one relay answering.
        let probe = RecordingRelayProbe(answers: [false])
        let state = WorkspaceState(
            clientFactory: { throw TestConnectivityError() },
            networkInterfaceMonitor: ScriptedInterfaceMonitor(availability: [true]),
            relayHostProbe: probe,
            // The relays never answer, so the re-check loop would run forever; the sleeper's
            // budget is what ends it.
            connectivityPolicy: ScriptedSleeper(budget: 2).policy
        )

        state.startConnectivityMonitoring()
        await state.connectivityMonitorTask?.value

        #expect(state.isOffline)
        let seedEndpoints = RelayHostEndpoint.endpoints(from: MarmotClient.seedRelays)
        #expect(probe.recordedEndpoints == Array(repeating: seedEndpoints, count: 3))
    }

    @MainActor
    @Test func aReachableRelayClearsTheNotice() async {
        // The banner has to come down on its own. A notice that needs a relaunch to clear is
        // worse than none, because it teaches the user to ignore it.
        let probe = RecordingRelayProbe(answers: [true])
        let state = WorkspaceState(
            clientFactory: { throw TestConnectivityError() },
            networkInterfaceMonitor: ScriptedInterfaceMonitor(availability: [false, true]),
            relayHostProbe: probe,
            connectivityPolicy: ScriptedSleeper().policy
        )

        state.startConnectivityMonitoring()
        await state.connectivityMonitorTask?.value

        #expect(!state.isOffline)
        // Probed once, not twice: the interface reading that came back `false` was answered
        // without opening anything, which is the short-circuit the first stage exists for.
        #expect(probe.recordedEndpoints.count == 1)
    }

    @MainActor
    @Test func aWorkspaceThatNeverStartsMonitoringNeverClaimsToBeOffline() async {
        // Construction is inert on purpose: the production monitor and probe are the defaults,
        // so every test that merely builds a workspace would otherwise open sockets.
        let state = WorkspaceState(clientFactory: { throw TestConnectivityError() })

        #expect(!state.isOffline)
        #expect(state.connectivityMonitorTask == nil)
    }

    @MainActor
    @Test func stopConnectivityMonitoringEndsTheWatch() async {
        let state = WorkspaceState(
            clientFactory: { throw TestConnectivityError() },
            networkInterfaceMonitor: ScriptedInterfaceMonitor(availability: [true], finishes: false),
            relayHostProbe: RecordingRelayProbe(answers: [true]),
            connectivityPolicy: ScriptedSleeper().policy
        )

        state.startConnectivityMonitoring()
        state.stopConnectivityMonitoring()

        #expect(state.connectivityMonitorTask == nil)
    }

    // MARK: - Patience and recovery

    @Test func oneFailedProbeDoesNotRaiseTheNotice() async {
        // Right after a path change a handshake can time out while DNS and routes settle. One
        // miss followed by an answer is a working connection, and the notice must not flash.
        let sleeper = ScriptedSleeper()
        let watcher = ConnectivityWatcher(
            interfaceMonitor: ScriptedInterfaceMonitor(availability: [true]),
            probe: RecordingRelayProbe(answers: [false, true]),
            policy: sleeper.policy
        )

        #expect(await watcher.collectedStates() == [false])
        #expect(sleeper.requestedPauses == [ConnectivityPolicy.standard.confirmationRetryDelay])
    }

    @Test func theNoticeComesDownWithoutAPathChange() async {
        // The reported bug: the path never moves (captive portal signed into, uplink restored
        // behind the same Wi-Fi), so a check that only ran on path changes left the notice up
        // over a working connection. Once offline, the relays are re-probed on a timer.
        let sleeper = ScriptedSleeper()
        let probe = RecordingRelayProbe(answers: [false, false, false, true])
        let watcher = ConnectivityWatcher(
            interfaceMonitor: ScriptedInterfaceMonitor(availability: [true]),
            probe: probe,
            policy: sleeper.policy
        )

        #expect(await watcher.collectedStates() == [true, false])
        #expect(probe.recordedEndpoints.count == 4)
        let policy = ConnectivityPolicy.standard
        #expect(
            sleeper.requestedPauses == [
                policy.confirmationRetryDelay,
                policy.offlineRecheckInterval,
                policy.offlineRecheckInterval,
            ]
        )
    }

    @Test func aPersistentInterfaceLossRaisesTheNoticeAfterTheGrace() async {
        let sleeper = ScriptedSleeper()
        let probe = RecordingRelayProbe(answers: [true])
        let watcher = ConnectivityWatcher(
            interfaceMonitor: ScriptedInterfaceMonitor(availability: [false]),
            probe: probe,
            policy: sleeper.policy
        )

        #expect(await watcher.collectedStates() == [true])
        #expect(sleeper.requestedPauses == [ConnectivityPolicy.standard.interfaceLossGrace])
        #expect(probe.recordedEndpoints.isEmpty)
    }

    @Test func anInterfaceThatReturnsInsideTheGraceNeverRaisesTheNotice() async {
        // Wi-Fi roaming and wake from sleep drop the path for a moment. The sleeper here never
        // wakes on its own, so the only way past the grace is the next reading cancelling it —
        // which is exactly the blip this guards against.
        let sleeper = ScriptedSleeper(wakes: false)
        let watcher = ConnectivityWatcher(
            interfaceMonitor: ScriptedInterfaceMonitor(availability: [false, true]),
            probe: RecordingRelayProbe(answers: [true]),
            policy: sleeper.policy
        )

        #expect(await watcher.collectedStates() == [false])
    }

    @Test func anUnparseableRelayListFailsOpen() async {
        // No endpoints is not evidence about the user's network, so it never reads as offline.
        let probe = RecordingRelayProbe(answers: [false])
        let watcher = ConnectivityWatcher(
            interfaceMonitor: ScriptedInterfaceMonitor(availability: [true]),
            probe: probe,
            policy: ScriptedSleeper().policy
        )

        #expect(await watcher.collectedStates(probing: []) == [false])
        #expect(probe.recordedEndpoints.isEmpty)
    }
}

// MARK: - Doubles

private struct TestConnectivityError: Error {}

private extension ConnectivityWatcher {
    func collectedStates(
        probing endpoints: [RelayHostEndpoint] = RelayHostEndpoint.endpoints(from: MarmotClient.seedRelays)
    ) async -> [Bool] {
        var states: [Bool] = []
        for await isOffline in offlineStates(probing: endpoints) {
            states.append(isOffline)
        }
        return states
    }
}

/// Stands in for `Task.sleep` in the policy: records each requested pause and returns at once,
/// so a test walks the whole policy without waiting it out. `budget` caps how many pauses are
/// granted before it throws, which is what ends a re-check loop that would otherwise never
/// stop; `wakes: false` suspends until cancelled, for proving that a new reading cuts a grace
/// short.
private nonisolated final class ScriptedSleeper: Sendable {
    private let pauses = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    private let budget: Int
    private let wakes: Bool

    init(budget: Int = .max, wakes: Bool = true) {
        self.budget = budget
        self.wakes = wakes
    }

    var requestedPauses: [Duration] {
        pauses.withLock { $0 }
    }

    var policy: ConnectivityPolicy {
        var policy = ConnectivityPolicy.standard
        policy.sleep = { [self] duration in try await self.sleep(for: duration) }
        return policy
    }

    private func sleep(for duration: Duration) async throws {
        let granted = pauses.withLock { pauses in
            guard pauses.count < budget else { return false }
            pauses.append(duration)
            return true
        }
        guard granted else { throw CancellationError() }
        if wakes {
            try Task.checkCancellation()
        } else {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

/// Replays a fixed list of interface readings. Finishing the stream is what lets a test await
/// the monitoring task instead of polling `isOffline` and hoping.
private struct ScriptedInterfaceMonitor: NetworkInterfaceMonitoring {
    let availability: [Bool]
    var finishes = true

    func interfaceAvailability() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            for isAvailable in availability {
                continuation.yield(isAvailable)
            }
            if finishes {
                continuation.finish()
            }
        }
    }
}

/// Answers from a script and records what it was asked about. The answers are consumed in
/// order and the last one repeats, so a test only has to state the readings it cares about.
private final class RecordingRelayProbe: RelayHostReachabilityProbing {
    private let answers: OSAllocatedUnfairLock<[Bool]>
    private let requests = OSAllocatedUnfairLock<[[RelayHostEndpoint]]>(initialState: [])

    init(answers: [Bool]) {
        self.answers = OSAllocatedUnfairLock(initialState: answers)
    }

    var recordedEndpoints: [[RelayHostEndpoint]] {
        requests.withLock { $0 }
    }

    func canReachAnyHost(_ endpoints: [RelayHostEndpoint]) async -> Bool {
        requests.withLock { $0.append(endpoints) }
        return answers.withLock { remaining in
            guard let next = remaining.first else { return false }
            if remaining.count > 1 {
                remaining.removeFirst()
            }
            return next
        }
    }
}
