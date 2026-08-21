//
//  NetworkInterfaceMonitoring.swift
//  whitenoise-mac
//
//  First half of the offline check: whether the OS believes there is a network
//  interface to send anything over. The macOS twin of `connectivity_plus` on the
//  Flutter client (`lib/providers/offline_provider.dart`).
//

import Foundation
import Network

/// A source of "does this machine have a usable network interface right now" answers.
///
/// A protocol rather than the concrete monitor so the offline banner can be driven from a
/// scripted sequence in tests. Nothing starts until `interfaceAvailability()` is called, which
/// is what lets `WorkspaceState` hold the production monitor without any test that merely
/// builds a workspace reaching the network.
nonisolated protocol NetworkInterfaceMonitoring: Sendable {
    /// Interface availability over time. Yields the current answer immediately, then once per
    /// path change, and finishes only when the consumer stops iterating.
    func interfaceAvailability() -> AsyncStream<Bool>
}

/// `NWPathMonitor`-backed availability.
///
/// Reports availability for anything other than `.unsatisfied` — including `.requiresConnection`,
/// where a VPN has to be dialled before traffic flows. That case is deliberately *not* called
/// offline here: the relay probe that runs next is the authority on whether packets actually
/// reach a relay, and this stage only exists to answer the cheap question without opening a
/// socket. Mirrors the Flutter rule "any result other than `ConnectivityResult.none`".
nonisolated struct NWPathInterfaceMonitor: NetworkInterfaceMonitoring {
    func interfaceAvailability() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status != .unsatisfied)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            // `NWPathMonitor` is a callback API and requires a dispatch queue; it has no
            // async-native form. Its own serial queue keeps path callbacks off the main
            // thread, where a stall would show up as dropped frames in the transcript.
            monitor.start(queue: DispatchQueue(label: "chat.whitenoise.network-path-monitor"))
        }
    }
}
