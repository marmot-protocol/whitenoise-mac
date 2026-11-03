//
//  ElectrumXTransport.swift
//  whitenoise-mac
//
//  Namecoin ElectrumX one-shot JSON-RPC over WebSocket Secure.
//
//  Ported from whitenoise-linux `app/nc_shim.c` (commits 79447095f2 and
//  271f0a4a04). The C shim drove libcurl's raw socket and framed RFC 6455
//  by hand; the idiomatic Apple equivalent is `URLSessionWebSocketTask`,
//  which does the handshake and framing in-process. What does NOT come
//  from the platform is the trust decision: the pinned ElectrumX operators
//  serve self-signed certs by convention, so TLS trust here is leaf public
//  key SHA-256 equality (the exact semantics of `CURLOPT_PINNEDPUBLICKEY`),
//  enforced in the `URLSessionDelegate` server-trust challenge — never the
//  system CA chain.
//
//  One call = one RPC = one connection, same as the shim. The resolver
//  only issues a few calls per name (server.version,
//  blockchain.scripthash.get_history, blockchain.transaction.get, and
//  optionally blockchain.headers.subscribe), and short-lived connections
//  keep the per-server timeout the resolver's only fallback signal.
//
//  Cross-build note (upstream 271f0a4a04): that commit kept the hand-rolled
//  socket/clock code building on Windows LLP64 targets. The URLSession
//  transport has no analogous concern — it is the same framework code on
//  macOS device and simulator, arm64 included.
//

import CryptoKit
import Foundation

/// One pinned ElectrumX endpoint. `pinnedLeafKeyBase64` is the base64 SHA-256 of the leaf
/// certificate's public key (SPKI) — the same value libcurl's `CURLOPT_PINNEDPUBLICKEY`
/// `sha256//<base64>` form carries. When present, TLS trusts the leaf by key equality and the
/// CA chain is NOT walked; when absent, the default browser-trusted chain is required.
nonisolated struct NamecoinServer: Equatable, Sendable {
    let host: String
    let port: Int
    let path: String
    let pinnedLeafKeyBase64: String?
    /// Production endpoints are always WSS. The internal override exists for hermetic local
    /// socket tests; no resolver configuration can select an insecure remote transport.
    let scheme: String

    init(
        host: String,
        port: Int,
        path: String,
        pinnedLeafKeyBase64: String?,
        scheme: String = "wss"
    ) {
        self.host = host
        self.port = port
        self.path = path
        self.pinnedLeafKeyBase64 = pinnedLeafKeyBase64
        self.scheme = scheme
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
        return components.url
    }

    var pinnedLeafKeySHA256: Data? {
        pinnedLeafKeyBase64.flatMap { Data(base64Encoded: $0) }
    }
}

extension [NamecoinServer] {
    /// Amethyst main's current clearnet ElectrumX list, in the same order. Pins are SPKI
    /// SHA-256 values and belong to an individual endpoint's connection delegate, never to a
    /// process-wide trust store. The two testls.space endpoints use normal system-CA trust.
    ///
    /// Rotation runbook: when a pinned server rotates its cert, regenerate the pin with
    ///
    ///   echo | openssl s_client -servername <host> -connect <host>:<port> 2>/dev/null \
    ///     | openssl x509 -pubkey -noout \
    ///     | openssl pkey -pubin -outform der \
    ///     | openssl dgst -sha256 -binary | openssl enc -base64
    ///
    /// and update the entry. Removing a pin without replacing it opens the server to
    /// trivial MITM.
    static let namecoinDefaultPinned: [NamecoinServer] = [
        NamecoinServer(
            host: "electrumx.testls.space",
            port: 50002,
            path: "",
            pinnedLeafKeyBase64: nil
        ),
        // bitcoins.sk community ElectrumX peer (Slovakia). Self-signed; pinned leaf.
        NamecoinServer(
            host: "nmc2.bitcoins.sk",
            port: 57002,
            path: "",
            pinnedLeafKeyBase64: "tkCCQ6AZPqU4Te1poKHeS5l/CRWYHz5n7J4LH22/LxQ="
        ),
        // Same operator and SPKI pin, addressed directly by IP.
        NamecoinServer(
            host: "46.229.238.187",
            port: 57002,
            path: "",
            pinnedLeafKeyBase64: "tkCCQ6AZPqU4Te1poKHeS5l/CRWYHz5n7J4LH22/LxQ="
        ),
        // relay.testls.bit peer (Namecoin `.bit` resolved via a separate resolver on the
        // host). Reached only when the host's `.bit` DNS is available.
        NamecoinServer(
            host: "relay.testls.bit",
            port: 50012,
            path: "",
            pinnedLeafKeyBase64: "Y9Zu+VV8eoqOBanmpk5QzJtnHwqzxb0ynJGiMRKVJBw="
        ),
        NamecoinServer(
            host: "23.158.233.10",
            port: 50012,
            path: "",
            pinnedLeafKeyBase64: "Y9Zu+VV8eoqOBanmpk5QzJtnHwqzxb0ynJGiMRKVJBw="
        ),
        NamecoinServer(
            host: "electrumx2.testls.space",
            port: 50002,
            path: "",
            pinnedLeafKeyBase64: nil
        ),
    ]
}

nonisolated enum ElectrumXTransportError: Error, Equatable {
    /// Bad URL, handshake failure, socket close, or TLS pin mismatch. The resolver treats
    /// every one of these as "server unavailable" and falls through to the next server.
    case connectionFailed
    /// The per-call deadline (connect + handshake + one round trip) elapsed.
    case timeout
    /// A single reply message exceeded the receive cap.
    case responseTooLarge
}

/// One-shot ElectrumX JSON-RPC client. `Sendable` and stateless: every `roundTrip` opens
/// its own connection with its own pinning delegate, so concurrent resolves never share
/// mutable state.
nonisolated protocol ElectrumXTransporting: Sendable {
    /// Connect to `server`, send `request` as one text frame, and return the body of the
    /// first reply envelope whose top-level `"id"` equals `wantID`. Server notifications
    /// (no top-level `id`, or an `id` we did not ask for) are skipped. Throws
    /// `ElectrumXTransportError` on any transport failure.
    func roundTrip(to server: NamecoinServer, request: String, wantID: Int) async throws -> String
}

nonisolated struct ElectrumXTransport: ElectrumXTransporting {
    /// Per-server I/O budget. URLSession has no separate TCP-connect timeout knob; its request
    /// timeout covers connect/TLS and read inactivity, while the resolver owns the overall 20s
    /// deadline. Keep this configured before the task (and therefore its socket/TLS) starts.
    static let requestTimeout: Duration = .seconds(15)
    let requestTimeout: Duration

    init(requestTimeout: Duration = ElectrumXTransport.requestTimeout) {
        self.requestTimeout = requestTimeout
    }
    /// Reply body cap. Mirrors `NC_REPLY_MAX` upstream: the resolver never asks for more
    /// than a single verbose transaction, so anything larger is hostile. The C shim applied
    /// this bound while framing so a hostile server could neither overflow the buffer nor
    /// pin the reader; `URLSessionWebSocketTask` delivers already-framed messages, so the
    /// cap is enforced on the delivered message instead.
    static let maxReplyBytes = 128 * 1024

    func roundTrip(to server: NamecoinServer, request: String, wantID: Int) async throws -> String {
        guard let url = server.url else { throw ElectrumXTransportError.connectionFailed }
        return try await Self.withTimeout(requestTimeout) {
            try await self.performRoundTrip(url: url, server: server, request: request, wantID: wantID)
        }
    }

    private func performRoundTrip(
        url: URL,
        server: NamecoinServer,
        request: String,
        wantID: Int
    ) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        let delegate = LeafKeyPinningDelegate(pinnedLeafKeySHA256: server.pinnedLeafKeySHA256)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        // One call = one connection: nothing may linger after the round trip, success or not.
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: url)
        return try await withTaskCancellationHandler {
            task.resume()
            do {
                try await task.send(.string(request))
                while true {
                    let message = try await task.receive()
                    let body: String
                    switch message {
                    case .string(let string):
                        body = string
                    case .data(let data):
                        body = String(decoding: data, as: UTF8.self)
                    @unknown default:
                        continue
                    }
                    guard body.utf8.count <= Self.maxReplyBytes else {
                        throw ElectrumXTransportError.responseTooLarge
                    }
                    // The upstream shim pre-filters envelopes with a byte-level `"id"`-at-
                    // depth-1 walker and the Odin side re-parses with a real JSON parser
                    // before trusting any payload. Parsing every envelope here with
                    // JSONSerialization IS that re-parse: a reply is accepted only when it
                    // is a JSON object whose top-level `id` matches the request, and every
                    // payload consumer downstream re-parses the body for its own fields.
                    guard let id = Self.topLevelID(of: body) else { continue }
                    if id == wantID {
                        return body
                    }
                    // Notification (subscription push) or an id we did not ask for; keep
                    // reading for the real reply.
                }
            } catch let error as ElectrumXTransportError {
                throw error
            } catch {
                throw ElectrumXTransportError.connectionFailed
            }
        } onCancel: {
            // A graceful WebSocket close can wait for a peer that is already stalled. Cancel
            // the URLSession task and its session so the underlying socket is torn down and a
            // real blocked receive/send is interrupted immediately.
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    /// The integer value of the key `"id"` at the top level of a JSON-RPC 2.0 reply
    /// envelope, or `nil` when the envelope is not an object, has no top-level `id`, or its
    /// `id` is not an integer. Nested `{"result":{"id":99},"id":2}` yields 2 — the parse
    /// makes the depth-1 match structural rather than a byte-walk heuristic.
    static func topLevelID(of body: String) -> Int? {
        guard let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = root["id"] as? NSNumber
        else { return nil }
        // JSONSerialization bridges booleans to NSNumber too; a JSON `true` is not an id.
        guard CFGetTypeID(id) != CFBooleanGetTypeID() else { return nil }
        return id.intValue
    }

    /// Race `operation` against the per-call deadline; whichever lands first wins and the
    /// loser is cancelled. `Task.sleep` is not a timer that fires early, so the operation
    /// always gets the full budget.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ElectrumXTransportError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ElectrumXTransportError.connectionFailed
            }
            return first
        }
    }
}

/// Enforces the TLS trust model: when a pin is configured, the handshake succeeds only when
/// the server's leaf public key SHA-256 equals the pin — a wrong pin (rotated cert, MITM)
/// fails before any data flows, and the CA chain is deliberately not consulted (the pinned
/// operators serve self-signed certs by convention). When no pin is configured, the default
/// browser-trusted chain evaluation is required.
nonisolated final class LeafKeyPinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let pinnedLeafKeySHA256: Data?

    init(pinnedLeafKeySHA256: Data?) {
        self.pinnedLeafKeySHA256 = pinnedLeafKeySHA256
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let pin = pinnedLeafKeySHA256 else {
            var evaluationError: CFError?
            if SecTrustEvaluateWithError(trust, &evaluationError) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first,
            let keyData = Self.subjectPublicKeyInfo(from: SecCertificateCopyData(leaf) as Data)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = Data(SHA256.hash(data: keyData))
        if digest == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Extract the exact DER `SubjectPublicKeyInfo` element from an X.509 certificate. Hashing
    /// `SecKeyCopyExternalRepresentation` instead would hash PKCS#1 for RSA (or raw X9.63 for
    /// EC), which is not the SPKI digest produced by OpenSSL/curl and would reject the pins.
    static func subjectPublicKeyInfo(from certificate: Data) -> Data? {
        let bytes = [UInt8](certificate)
        guard let outer = derElement(in: bytes, at: 0, limit: bytes.count),
            outer.tag == 0x30,
            let tbs = derElement(in: bytes, at: outer.content.lowerBound, limit: outer.content.upperBound),
            tbs.tag == 0x30
        else { return nil }

        var cursor = tbs.content.lowerBound
        guard var element = derElement(in: bytes, at: cursor, limit: tbs.content.upperBound) else {
            return nil
        }
        // Explicit [0] Version is optional; it precedes the six mandatory fields below.
        if element.tag == 0xA0 {
            cursor = element.full.upperBound
            guard let next = derElement(in: bytes, at: cursor, limit: tbs.content.upperBound) else {
                return nil
            }
            element = next
        }

        // SerialNumber, signature, issuer, validity, subject, SubjectPublicKeyInfo.
        for field in 0...5 {
            if field == 5 {
                return Data(bytes[element.full])
            }
            cursor = element.full.upperBound
            guard let next = derElement(in: bytes, at: cursor, limit: tbs.content.upperBound) else {
                return nil
            }
            element = next
        }
        return nil
    }

    private static func derElement(
        in bytes: [UInt8],
        at offset: Int,
        limit: Int
    ) -> (tag: UInt8, full: Range<Int>, content: Range<Int>)? {
        guard offset >= 0, offset + 2 <= limit, limit <= bytes.count else { return nil }
        let firstLength = bytes[offset + 1]
        let headerLength: Int
        let contentLength: Int
        if firstLength < 0x80 {
            headerLength = 2
            contentLength = Int(firstLength)
        } else {
            let lengthBytes = Int(firstLength & 0x7F)
            guard lengthBytes > 0, lengthBytes <= 4, offset + 2 + lengthBytes <= limit else {
                return nil
            }
            headerLength = 2 + lengthBytes
            var value = 0
            for byte in bytes[(offset + 2)..<(offset + headerLength)] {
                value = value << 8 | Int(byte)
            }
            contentLength = value
        }
        let contentStart = offset + headerLength
        let contentEnd = contentStart + contentLength
        guard contentEnd >= contentStart, contentEnd <= limit else { return nil }
        return (bytes[offset], offset..<contentEnd, contentStart..<contentEnd)
    }
}
