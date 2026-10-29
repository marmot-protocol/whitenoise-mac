//
//  ConnectivityPolicy.swift
//  whitenoise-mac
//
//  How patient the "Waiting for internet connection" notice is in each
//  direction: slow to claim the network is gone, quick to admit it is back.
//

import Foundation

/// Timing rules for `ConnectivityWatcher`.
///
/// The notice is asymmetric on purpose. Claiming "no internet" while the user is reading a
/// working chat is the worse lie, so going offline needs the failure to persist; coming back
/// online needs only one relay to answer.
nonisolated struct ConnectivityPolicy: Sendable {
    /// How long macOS may report no interface before the notice appears. Wi-Fi roaming, a
    /// network switch and wake from sleep all drop the path for a moment and bring it back;
    /// none of those is the user being offline.
    var interfaceLossGrace: Duration

    /// Consecutive failed relay probes, with an interface present, before the notice appears.
    /// One failure is not enough: right after a path change DNS and routes are often still
    /// settling, and a single relay handshake timing out says more about that than about the
    /// user's connection.
    var failedProbesBeforeOffline: Int

    /// Pause between probes while a failure is still being confirmed.
    var confirmationRetryDelay: Duration

    /// Pause between probes once the notice is showing. Without this the notice only came down
    /// on the next *path* change, so a captive portal signed into, an uplink restored behind
    /// the same Wi-Fi, or a probe that failed while the network was still coming up left the
    /// notice standing over a working connection.
    var offlineRecheckInterval: Duration

    /// Sleeps between probes. Injected so tests can run the policy without waiting it out.
    var sleep: @Sendable (Duration) async throws -> Void

    static let standard = ConnectivityPolicy(
        interfaceLossGrace: .seconds(3),
        failedProbesBeforeOffline: 2,
        confirmationRetryDelay: .seconds(2),
        offlineRecheckInterval: .seconds(5),
        sleep: { try await Task.sleep(for: $0) }
    )
}
