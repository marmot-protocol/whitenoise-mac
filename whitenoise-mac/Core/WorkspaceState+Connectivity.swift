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

        let states = connectivityWatcher.offlineStates(
            probing: RelayHostEndpoint.endpoints(from: MarmotClient.seedRelays)
        )

        connectivityMonitorTask = Task { [weak self] in
            for await isOffline in states {
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
}
