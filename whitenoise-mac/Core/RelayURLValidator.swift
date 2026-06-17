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

        if normalized == "localhost" || normalized == "::1" {
            return true
        }

        // 127.0.0.0/8 is the IPv4 loopback range.
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.first == "127", octets.allSatisfy({ isByte($0) }) {
            return true
        }

        return false
    }

    private static func isByte(_ component: Substring) -> Bool {
        guard !component.isEmpty, component.allSatisfy({ $0.isNumber }), let value = Int(component) else {
            return false
        }
        return (0...255).contains(value)
    }
}
