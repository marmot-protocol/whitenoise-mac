//
//  WorkspaceState+Connectivity.swift
//  whitenoise-mac
//
//  Keeps `isOffline` current so the "Waiting for internet connection" notice can
//  appear and disappear on its own. Ported from the Flutter client's
//  `offlineProvider` (`lib/providers/offline_provider.dart`): every interface
//  change re-asks the cheap question first, and only re-probes the relays when
//  the answer is "there is an interface".
//

import Foundation

@MainActor
extension WorkspaceState {
    /// Begins watching connectivity and keeps `isOffline` in step with it.
    ///
    /// Idempotent, and deliberately *not* called from `bootstrap()`: the notice belongs on the
    /// login and onboarding screens too, and a workspace built for tests or a UI fixture should
    /// never open a socket just because it was constructed.
    func startConnectivityMonitoring() {
        guard connectivityMonitorTask == nil else { return }

        let endpoints = RelayHostEndpoint.endpoints(from: MarmotClient.seedRelays)
        let monitor = networkInterfaceMonitor
        let probe = relayHostProbe

        connectivityMonitorTask = Task { [weak self] in
            // The stream yields the current path before any change, so the first pass through
            // this loop is the initial reading rather than a wait for the network to move.
            for await hasInterface in monitor.interfaceAvailability() {
                let isOffline: Bool
                if hasInterface {
                    isOffline = await !Self.canReachAnyRelay(using: probe, endpoints: endpoints)
                } else {
                    isOffline = true
                }
                guard let self else { return }
                self.isOffline = isOffline
            }
        }
    }

    /// Stops watching. Terminating the stream is what cancels the underlying path monitor.
    func stopConnectivityMonitoring() {
        connectivityMonitorTask?.cancel()
        connectivityMonitorTask = nil
    }

    private static func canReachAnyRelay(
        using probe: any RelayHostReachabilityProbing,
        endpoints: [RelayHostEndpoint]
    ) async -> Bool {
        // Fail open when there is nothing to probe. The Flutter client reaches the same place
        // from the opposite direction — it treats an unreadable relay list as reachable — and the
        // reasoning is the same either way: a banner claiming the user has no internet on the
        // strength of a relay list we could not parse is a lie about their network.
        guard !endpoints.isEmpty else { return true }
        return await probe.canReachAnyHost(endpoints)
    }
}
