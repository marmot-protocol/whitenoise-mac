import Foundation

/// Validates relay WebSocket URLs with a security-first policy.
///
/// In a privacy-focused E2EE messenger, relay transport carries connection
/// metadata, subscription filters, timing, and the client IP. Cleartext
/// `ws://` relays expose all of that to passive observers and allow active
/// tampering of the relay stream, even though MLS message *contents* stay
/// encrypted. So:
///
/// - `wss://` (TLS) relays are always accepted and considered secure.
/// - `ws://` (cleartext) relays are accepted **only** when they point at a
///   loopback host (`localhost`, `127.0.0.0/8`, `::1`), to keep local/dev
///   relays usable. They are still flagged as insecure for the UI.
/// - Any other `ws://` relay, or any other scheme, is rejected.
enum RelayURLValidator {
    enum Classification: Equatable {
        /// `wss://` relay — encrypted transport.
        case secure
        /// `ws://` relay on a loopback host — accepted for local/dev, but cleartext.
        case insecureLoopback
        /// `ws://` relay on a non-loopback host — rejected (would leak metadata over the network).
        case insecureRejected
        /// Not a relay URL at all (wrong scheme / malformed).
        case invalid

        /// Whether a relay with this classification may be saved.
        var isAcceptable: Bool {
            switch self {
            case .secure, .insecureLoopback:
                return true
            case .insecureRejected, .invalid:
                return false
            }
        }

        /// Whether a relay with this classification should be surfaced as insecure in the UI.
        var isInsecure: Bool {
            self == .insecureLoopback
        }

        /// Whether a relay with this classification uses cleartext `ws://`
        /// transport of any kind — loopback dev relays *and* rejected public
        /// relays. The UI uses this to mark every non-`wss://` relay as
        /// insecure, including pre-existing public `ws://` entries that loaded
        /// from a saved relay list and would be rejected on the next save.
        var isCleartext: Bool {
            switch self {
            case .insecureLoopback, .insecureRejected:
                return true
            case .secure, .invalid:
                return false
            }
        }
    }

    /// Classifies a trimmed relay URL string.
    static func classify(_ value: String) -> Classification {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        // Parse with URLComponents (rather than a bare prefix check) so a
        // schemeless or hostless input — e.g. `wss://` with no host — is
        // treated as malformed instead of being silently accepted as secure.
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host,
            !host.isEmpty
        else {
            return .invalid
        }

        switch scheme {
        case "wss":
            return .secure
        case "ws":
            // Cleartext ws:// — only acceptable for loopback hosts.
            return isLoopbackHost(host) ? .insecureLoopback : .insecureRejected
        default:
            return .invalid
        }
    }

    /// Whether the relay URL may be saved (secure, or loopback dev relay).
    static func isAcceptable(_ value: String) -> Bool {
        classify(value).isAcceptable
    }

    /// Whether the relay URL is cleartext and should be flagged as insecure in the UI.
    static func isInsecure(_ value: String) -> Bool {
        classify(value).isInsecure
    }

    /// Whether the relay URL uses cleartext `ws://` transport (loopback dev
    /// relay or a non-loopback public relay). The UI flags all of these as
    /// insecure so pre-existing public `ws://` entries are visibly marked.
    static func isCleartext(_ value: String) -> Bool {
        classify(value).isCleartext
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
            // URLComponents.host strips brackets from IPv6 literals, but be defensive.
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if normalized == "localhost" {
            return true
        }

        // Parse the host as a literal IP and test loopback membership on the
        // parsed bytes, rather than string-matching a couple of canonical
        // spellings. This accepts every equivalent spelling of the same
        // loopback address — e.g. the compressed `::1`, the expanded
        // `0:0:0:0:0:0:0:1`, and the IPv4-mapped `::ffff:127.0.0.1` — while
        // still rejecting non-loopback addresses and hostnames that merely
        // *contain* a loopback token (`127.0.0.1.evil.com`, `localhost.evil`).
        if let v4 = parseIPv4(normalized) {
            // 127.0.0.0/8 is the IPv4 loopback range.
            return v4.0 == 127
        }

        if let v6 = parseIPv6(normalized) {
            return isLoopbackIPv6(v6)
        }

        return false
    }

    /// Parses a strict dotted-decimal IPv4 literal into its four octets.
    ///
    /// Uses `inet_pton`, which accepts *only* canonical dotted-decimal form
    /// (e.g. `127.0.0.1`). Non-decimal IPv4 spellings — octal, hexadecimal, or
    /// abbreviated forms like `127.1` — are intentionally **not** accepted:
    /// they are an SSRF/parsing-ambiguity footgun, and a relay URL has no
    /// legitimate need for them.
    private static func parseIPv4(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else {
            return nil
        }
        // s_addr is in network byte order (big-endian): the first octet is the
        // least-significant byte of the network-order value.
        let raw = addr.s_addr
        return (
            UInt8(truncatingIfNeeded: raw),
            UInt8(truncatingIfNeeded: raw >> 8),
            UInt8(truncatingIfNeeded: raw >> 16),
            UInt8(truncatingIfNeeded: raw >> 24)
        )
    }

    /// Parses an IPv6 literal into its 16 bytes. `inet_pton` normalizes every
    /// valid spelling (compressed, expanded, IPv4-mapped) to the same bytes.
    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// Whether a parsed 16-byte IPv6 address points at loopback:
    /// the canonical `::1`, or an IPv4-mapped loopback `::ffff:127.0.0.0/104`.
    private static func isLoopbackIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        // ::1 — fifteen zero bytes followed by 0x01.
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return true
        }

        // ::ffff:a.b.c.d — IPv4-mapped IPv6. Bytes 0...9 are zero, 10...11 are
        // 0xffff, and 12...15 hold the embedded IPv4 address. Loopback when the
        // embedded IPv4 falls in 127.0.0.0/8.
        if bytes[0..<10].allSatisfy({ $0 == 0 })
            && bytes[10] == 0xff && bytes[11] == 0xff
            && bytes[12] == 127 {
            return true
        }

        return false
    }
}
