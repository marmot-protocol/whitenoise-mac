//
//  NetworkRemoteMediaConnection.swift
//  whitenoise-mac
//
//  Network.framework TLS connection to one already-admitted numeric endpoint.
//

import Foundation
import Network
import Security

nonisolated struct NetworkRemoteMediaConnectionFactory: RemoteMediaConnectionFactory {
    func makeConnection(to endpoint: RemoteMediaEndpoint) -> any RemoteMediaConnection {
        NetworkRemoteMediaConnection(endpoint: endpoint)
    }

    /// TLS over TCP with the system's default trust evaluation, which is never replaced or
    /// relaxed here: no verify block, no pinning override, no minimum below TLS 1.2.
    ///
    /// For a DNS origin, `sec_protocol_options_set_tls_server_name` sets both the SNI and the
    /// name the default evaluation verifies the certificate against, overriding the numeric
    /// endpoint we dial. For a literal origin no name is set, so the certificate must carry the
    /// literal address as an IP SAN, exactly as before.
    ///
    /// `preferNoProxies` asks Network.framework to ignore enabled system proxies, so the
    /// address admitted here is the address dialed rather than one a proxy resolves again. It
    /// is a preference; see docs/remote-media-transport.md for the native qualification gap.
    static func parameters(tlsServerName: String?) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        if let tlsServerName {
            sec_protocol_options_set_tls_server_name(security, tlsServerName)
        }
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(RemoteImageURLPolicy.downloadStallTimeout)

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        return parameters
    }

    /// Builds the endpoint host from address *bytes* through the typed initializers, so no
    /// string ever reaches `NWEndpoint.Host(_:)` (which would accept a hostname and resolve it).
    static func host(for address: RemoteMediaAddress) -> NWEndpoint.Host? {
        let dial = address.dialAddress
        switch dial.family {
        case .ipv4:
            return IPv4Address(Data(dial.bytes)).map { NWEndpoint.Host.ipv4($0) }
        case .ipv6:
            return IPv6Address(Data(dial.bytes)).map { NWEndpoint.Host.ipv6($0) }
        }
    }
}

/// `@unchecked Sendable`: `NWConnection` is driven from its own serial queue and is safe to
/// cancel from any thread; the only mutable state here is the one-shot start callback, which
/// the lock owns.
nonisolated final class NetworkRemoteMediaConnection: RemoteMediaConnection, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "chat.whitenoise.remote-media.connection", qos: .utility)

    private let connection: NWConnection?
    private let lock = NSLock()
    private var startCompletion: (@Sendable ((any Error)?) -> Void)?

    init(endpoint: RemoteMediaEndpoint) {
        if let host = NetworkRemoteMediaConnectionFactory.host(for: endpoint.address),
            let port = NWEndpoint.Port(rawValue: endpoint.port)
        {
            connection = NWConnection(
                host: host,
                port: port,
                using: NetworkRemoteMediaConnectionFactory.parameters(tlsServerName: endpoint.tlsServerName)
            )
        } else {
            connection = nil
        }
    }

    func start(_ completion: @escaping @Sendable ((any Error)?) -> Void) {
        lock.lock()
        startCompletion = completion
        lock.unlock()
        guard let connection else {
            finishStart(RemoteMediaTransportError.invalidRequest)
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.finishStart(nil)
            case .failed(let error):
                self?.finishStart(error)
            case .waiting(let error):
                // "No usable path yet, will retry" — for this fetch that is a failed attempt;
                // the next admitted address or the fetch deadline decides what happens next.
                self?.finishStart(error)
            case .cancelled:
                self?.finishStart(RemoteMediaTransportError.cancelled)
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: Self.queue)
    }

    func send(_ data: Data, _ completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard let connection else {
            completion(RemoteMediaTransportError.invalidRequest)
            return
        }
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                completion(error)
            })
    }

    func receive(maximumLength: Int, _ completion: @escaping @Sendable (RemoteMediaReceivedChunk) -> Void) {
        guard let connection else {
            completion(
                RemoteMediaReceivedChunk(
                    data: Data(), isComplete: true, error: RemoteMediaTransportError.invalidRequest))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion(RemoteMediaReceivedChunk(data: data ?? Data(), isComplete: isComplete, error: error))
        }
    }

    func cancel() {
        connection?.cancel()
    }

    private func finishStart(_ error: (any Error)?) {
        lock.lock()
        let completion = startCompletion
        startCompletion = nil
        lock.unlock()
        completion?(error)
    }
}
