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
        // The wording is lifted from the Flutter client's `waitingForInternet` so a user who
        // moves between clients reads the same sentence. Asserted through a translation rather
        // than the English key, which a lookup returns even when the catalog entry is missing.
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
            relayHostProbe: probe
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
            relayHostProbe: probe
        )

        state.startConnectivityMonitoring()
        await state.connectivityMonitorTask?.value

        #expect(state.isOffline)
        #expect(probe.recordedEndpoints == [RelayHostEndpoint.endpoints(from: MarmotClient.seedRelays)])
    }

    @MainActor
    @Test func aReachableRelayClearsTheNotice() async {
        // The banner has to come down on its own. A notice that needs a relaunch to clear is
        // worse than none, because it teaches the user to ignore it.
        let probe = RecordingRelayProbe(answers: [true])
        let state = WorkspaceState(
            clientFactory: { throw TestConnectivityError() },
            networkInterfaceMonitor: ScriptedInterfaceMonitor(availability: [false, true]),
            relayHostProbe: probe
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
            relayHostProbe: RecordingRelayProbe(answers: [true])
        )

        state.startConnectivityMonitoring()
        state.stopConnectivityMonitoring()

        #expect(state.connectivityMonitorTask == nil)
    }
}

// MARK: - Doubles

private struct TestConnectivityError: Error {}

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
