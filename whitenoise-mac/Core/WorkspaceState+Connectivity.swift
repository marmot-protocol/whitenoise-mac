//
//  WorkspaceState+Connectivity.swift
//  whitenoise-mac
//
//  Keeps `isOffline` current so the "Waiting for internet connection" notice can
//  appear and disappear on its own.
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
        guard !endpoints.isEmpty else { return true }
        return await probe.canReachAnyHost(endpoints)
    }
}
