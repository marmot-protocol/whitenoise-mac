//
//  RelayHostReachabilityProbing.swift
//  whitenoise-mac
//
//  Second half of the offline check: a network interface exists, but does
//  anything actually answer at the other end? Ported from the Flutter client's
//  `_reachAnyRelayHost` (`lib/providers/offline_provider.dart`), which races a
//  three-second TCP connect against every default relay and takes the first
//  host that answers.
//

import Foundation
import Network
import os

/// Answers whether at least one relay host is reachable.
///
/// A protocol so the offline banner can be driven from a stub in tests: the real probe opens
/// sockets, which no unit test should do.
nonisolated protocol RelayHostReachabilityProbing: Sendable {
    /// `true` as soon as *any* endpoint completes a TCP handshake. Never throws — an
    /// unreachable host is an answer, not an error.
    func canReachAnyHost(_ endpoints: [RelayHostEndpoint]) async -> Bool
}

/// Reachability by TCP handshake, raced across the endpoints.
///
/// A handshake is the whole test: no relay traffic is sent and nothing is read back. The
/// question being asked is "can packets leave this machine and come back", which a captive
/// portal or a dead Wi-Fi association fails even though the OS still reports an interface.
nonisolated struct TCPRelayHostProbe: RelayHostReachabilityProbing {
    /// The Flutter client's `Socket.connect` timeout, kept verbatim so both clients decide
    /// they are offline after the same wait.
    static let defaultTimeout: Duration = .seconds(3)

    let timeout: Duration

    init(timeout: Duration = Self.defaultTimeout) {
        self.timeout = timeout
    }

    func canReachAnyHost(_ endpoints: [RelayHostEndpoint]) async -> Bool {
        guard !endpoints.isEmpty else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            for endpoint in endpoints {
                group.addTask { await handshakeSucceeds(with: endpoint) }
            }
            // First host to answer wins; the rest are abandoned rather than waited out, so a
            // reachable relay is not held up by a sibling that will sit out the full timeout.
            while let isReachable = await group.next() {
                if isReachable {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
    }

    private func handshakeSucceeds(with endpoint: RelayHostEndpoint) async -> Bool {
        let connection = RelayProbeConnection(endpoint: endpoint)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await connection.awaitHandshake() }
            group.addTask {
                // Cancelling the connection is what settles the handshake child above, so the
                // timeout has to reach into it rather than just reporting `false` on its own.
                try? await Task.sleep(for: timeout)
                connection.cancel()
                return false
            }
            let outcome = await group.next() ?? false
            connection.cancel()
            group.cancelAll()
            return outcome
        }
    }
}

/// One in-flight TCP probe.
///
/// A class because the timeout and the handshake are separate children racing over the same
/// socket, and `@unchecked Sendable` because `NWConnection`'s callbacks arrive on its own
/// serial queue — the only mutable state here is the resume claim, which the lock owns.
///
/// `nonisolated` is load-bearing: this module defaults to main-actor isolation, so without it
/// every socket call here would hop to the main actor — the one thread a three-second connect
/// must never be scheduled behind. It shows up only as a Release-build warning ("this is an
/// error in the Swift 6 language mode"), not in Debug.
private nonisolated final class RelayProbeConnection: @unchecked Sendable {
    private static let probeQueue = DispatchQueue(label: "chat.whitenoise.relay-reachability-probe")

    private let connection: NWConnection
    private let hasResumed = OSAllocatedUnfairLock(initialState: false)

    init(endpoint: RelayHostEndpoint) {
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) ?? .https,
            using: .tcp
        )
    }

    func awaitHandshake() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    settle(continuation, isReachable: true)
                case .failed, .cancelled:
                    settle(continuation, isReachable: false)
                case .waiting:
                    // "No route yet, will retry." For a reachability question that is already
                    // the answer, and waiting out the timeout would only make an unplugged
                    // machine take three seconds to admit what it knows now.
                    settle(continuation, isReachable: false)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: Self.probeQueue)
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func settle(_ continuation: CheckedContinuation<Bool, Never>, isReachable: Bool) {
        let claimed = hasResumed.withLock { hasResumed in
            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
        guard claimed else { return }
        // Nothing is sent over this socket, so it is closed the moment it has answered —
        // the Flutter probe's `socket.destroy()`.
        connection.cancel()
        continuation.resume(returning: isReachable)
    }
}
