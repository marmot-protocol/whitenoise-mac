//
//  RemoteMediaRequestTarget.swift
//  whitenoise-mac
//
//  The addressing half of the pinned remote-media transport: which numeric address a request
//  may dial, what it says in `Host`, and which name TLS must authenticate. See
//  docs/remote-media-transport.md for the threat model.
//

import Foundation

/// Every way a pinned remote-media fetch can fail. Callers only ever see "no bytes"; the cases
/// exist so tests can assert *which* guard fired rather than merely that something did.
nonisolated enum RemoteMediaTransportError: Error, Equatable, Sendable {
    // Admission.
    case disallowedURL
    case invalidRequest
    // Resolution.
    case dnsUnavailable
    case resolutionFailed
    case malformedResolution
    case tooManyAnswers
    case unsafeResolution
    // Transport.
    case connectionFailed
    case idleTimeout
    case deadlineExceeded
    case cancelled
    // HTTP.
    case httpStatus(Int)
    case tooManyRedirects
    case invalidRedirect
    case malformedResponse
    case headersTooLarge
    case framingTooLarge
    case bodyTooLarge
    case prematureEOF
    case ambiguousFraming
    case unsupportedFraming
    case unsupportedContentEncoding
    case unsupportedUpgrade
}

/// A validated numeric IP address, held as network-order bytes.
///
/// The connection layer builds `IPv4Address`/`IPv6Address` from `bytes`, never from text, so an
/// answer string can never be re-read as a hostname (and re-resolved) below the admission check.
nonisolated struct RemoteMediaAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    enum Family: Equatable, Hashable, Sendable {
        case ipv4
        case ipv6
    }

    let family: Family
    let bytes: [UInt8]

    init?(ipv4 bytes: [UInt8]) {
        guard bytes.count == 4 else { return nil }
        self.family = .ipv4
        self.bytes = bytes
    }

    init?(ipv6 bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.family = .ipv6
        self.bytes = bytes
    }

    /// Parses a *canonical* numeric address: dotted-decimal IPv4 with exactly four parts and no
    /// leading zeros, or RFC 4291 IPv6 text with no zone id and (if present) a canonical
    /// dotted-decimal tail. The BSD `inet_aton` spellings (`127.1`, `0x7f000001`, `0177.0.0.1`)
    /// that `IPAddress.parseIPv4` deliberately recognises for *classification* are rejected
    /// here: something that is neither canonical nor a hostname is malformed, not dialable.
    init?(canonical text: String) {
        if let v4 = Self.canonicalIPv4Bytes(text) {
            self.init(ipv4: v4)
        } else if let v6 = Self.strictIPv6Bytes(text) {
            self.init(ipv6: v6)
        } else {
            return nil
        }
    }

    /// An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) dials as the IPv4 address it carries.
    var dialAddress: RemoteMediaAddress {
        guard family == .ipv6,
            bytes[0..<10].allSatisfy({ $0 == 0 }),
            bytes[10] == 0xFF, bytes[11] == 0xFF,
            let v4 = RemoteMediaAddress(ipv4: Array(bytes[12..<16]))
        else { return self }
        return v4
    }

    var description: String {
        switch family {
        case .ipv4:
            return bytes.map(String.init).joined(separator: ".")
        case .ipv6:
            return stride(from: 0, to: 16, by: 2)
                .map { String((UInt16(bytes[$0]) << 8) | UInt16(bytes[$0 + 1]), radix: 16) }
                .joined(separator: ":")
        }
    }

    static func canonicalIPv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(4)
        for part in parts {
            let utf8 = Array(part.utf8)
            guard (1...3).contains(utf8.count),
                utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                utf8.count == 1 || utf8[0] != 0x30,
                let value = UInt8(part, radix: 10)
            else { return nil }
            out.append(value)
        }
        return out
    }

    static func strictIPv6Bytes(_ text: String) -> [UInt8]? {
        guard !text.isEmpty, text.utf8.count <= 45,
            text.utf8.allSatisfy({ isHexDigit($0) || $0 == 0x3A || $0 == 0x2E })
        else { return nil }

        func groups(_ part: Substring, allowIPv4Tail: Bool) -> [UInt16]? {
            if part.isEmpty { return [] }
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            var out: [UInt16] = []
            for (index, piece) in pieces.enumerated() {
                if piece.contains(".") {
                    guard allowIPv4Tail, index == pieces.count - 1,
                        let v4 = canonicalIPv4Bytes(String(piece))
                    else { return nil }
                    out.append((UInt16(v4[0]) << 8) | UInt16(v4[1]))
                    out.append((UInt16(v4[2]) << 8) | UInt16(v4[3]))
                } else {
                    guard (1...4).contains(piece.utf8.count), let value = UInt16(piece, radix: 16) else { return nil }
                    out.append(value)
                }
            }
            return out
        }

        let halves = text.components(separatedBy: "::")
        let all: [UInt16]
        switch halves.count {
        case 1:
            guard let parsed = groups(Substring(text), allowIPv4Tail: true), parsed.count == 8 else { return nil }
            all = parsed
        case 2:
            guard let head = groups(Substring(halves[0]), allowIPv4Tail: false),
                let tail = groups(Substring(halves[1]), allowIPv4Tail: true),
                head.count + tail.count <= 7
            else { return nil }
            all = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        default:
            return nil
        }
        return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

/// One numeric dial target for one request hop.
nonisolated struct RemoteMediaEndpoint: Equatable, Sendable {
    let address: RemoteMediaAddress
    let port: UInt16
    /// The original origin name TLS must authenticate (and send as SNI). `nil` for an IP-literal
    /// origin, whose certificate is verified against the literal address itself (an IP SAN).
    let tlsServerName: String?
}

/// What a single request hop needs, derived from an already-admitted URL: the origin to dial,
/// the `Host` header, and the origin-form request target.
nonisolated struct RemoteMediaRequestTarget: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// A DNS name; must be resolved and every answer re-admitted before dialing.
        case name(String)
        /// A canonical numeric literal; dials directly with no DNS.
        case address(RemoteMediaAddress)
    }

    static let defaultPort: UInt16 = 443
    static let maximumHostnameLength = 253

    let origin: Origin
    let port: UInt16
    let hostHeader: String
    let path: String

    var tlsServerName: String? {
        if case .name(let name) = origin { return name }
        return nil
    }

    /// Fails closed for anything the pinned transport cannot represent exactly: non-https,
    /// userinfo, ports outside `1...65535`, zone ids, non-canonical numeric hosts (which would
    /// otherwise reach `getaddrinfo`'s `inet_aton` parser), non-ASCII or malformed DNS names,
    /// and request targets containing anything but visible ASCII.
    init(url: URL) throws {
        guard url.scheme?.lowercased() == "https",
            url.user == nil, url.password == nil,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            var host = url.host, !host.isEmpty
        else { throw RemoteMediaTransportError.invalidRequest }

        let rawPort = url.port ?? Int(Self.defaultPort)
        guard (1...65_535).contains(rawPort), let port = UInt16(exactly: rawPort) else {
            throw RemoteMediaTransportError.invalidRequest
        }

        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        host = host.lowercased()

        let origin: Origin
        let hostText: String
        if host.contains(":") {
            guard let v6 = RemoteMediaAddress.strictIPv6Bytes(host), let address = RemoteMediaAddress(ipv6: v6) else {
                throw RemoteMediaTransportError.invalidRequest
            }
            origin = .address(address)
            hostText = "[\(host)]"
        } else if let v4 = RemoteMediaAddress.canonicalIPv4Bytes(host), let address = RemoteMediaAddress(ipv4: v4) {
            origin = .address(address)
            hostText = host
        } else {
            if host.hasSuffix(".") { host.removeLast() }
            guard Self.isDialableHostname(host) else { throw RemoteMediaTransportError.invalidRequest }
            origin = .name(host)
            hostText = host
        }

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        guard path.hasPrefix("/") else { throw RemoteMediaTransportError.invalidRequest }
        if let query = components.percentEncodedQuery {
            path += "?" + query
        }
        guard path.utf8.allSatisfy({ (0x21...0x7E).contains($0) && $0 != 0x23 }) else {
            throw RemoteMediaTransportError.invalidRequest
        }

        self.origin = origin
        self.port = port
        self.hostHeader = port == Self.defaultPort ? hostText : "\(hostText):\(port)"
        self.path = path
    }

    /// ASCII letters, digits, `-` and `_` in 1...63-byte labels, at most 253 bytes, and a final
    /// label that is not purely numeric or `0x`-prefixed — those are IPv4 spellings in disguise
    /// (`1.2.3.08`, `foo.0x10`) and must never be handed to a resolver that would parse them.
    static func isDialableHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= maximumHostnameLength else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count),
                label.utf8.allSatisfy({ byte in
                    (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
                })
            else { return false }
        }
        guard let last = labels.last else { return false }
        if last.utf8.allSatisfy({ (0x30...0x39).contains($0) }) { return false }
        if last.hasPrefix("0x") { return false }
        return true
    }
}
