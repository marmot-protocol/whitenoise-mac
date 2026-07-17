//
//  MarkdownLinkPolicy.swift
//  whitenoise-mac
//
//  Safety policy for links rendered from untrusted peer Markdown.
//

import Foundation

/// Peer-controlled message text must never be allowed to hand arbitrary URL schemes to
/// LaunchServices. `http`/`https` links may be handed to the system browser after the app-side
/// `OpenURLAction` gate runs; `nostr:` links and strict `marmot://profile/<npub|nprofile>`
/// links are handled internally by `WorkspaceState` — every other `marmot://` form is dropped.
nonisolated enum MarkdownLinkPolicy {
    private static let resolvableProfilePrefixes = ["npub1", "nprofile1"]
    private static let recognizedNostrReferencePrefixes =
        resolvableProfilePrefixes + ["note1", "nevent1", "naddr1", "nrelay1"]
    /// Bech32 data alphabet — `1`, `b`, `i`, and `o` are excluded by the encoding.
    private static let bech32DataAlphabet = Set("023456789acdefghjklmnpqrstuvwxyz")

    static func sanitizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let url = URL(string: trimmed),
            isAllowed(url)
        else { return nil }
        return url
    }

    static func nostrURL(for bech32: String) -> URL? {
        sanitizedURL(from: "nostr:\(bech32)")
    }

    static func isAllowed(_ url: URL) -> Bool {
        isAllowedExternalURL(url) || isInternalNostrURL(url) || isInternalMarmotProfileURL(url)
    }

    static func isInternalMarmotProfileURL(_ url: URL) -> Bool {
        MarmotProfileLink.profileReference(from: url) != nil
    }

    static func isAllowedExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        // Reject embedded userinfo before host-based checks. A peer-controlled
        // link like `https://relay.damus.io@evil.example` connects to
        // `evil.example` but reads as the trusted relay host to a human.
        guard url.user == nil, url.password == nil else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        // Peer-controlled links must not point at literal private/loopback/link-local
        // destinations. Reuse the SSRF host check already implemented for avatar image URLs so
        // a Markdown link to a LAN/loopback address is suppressed symmetrically with images
        // (whitenoise-mac#249). Public http/https hosts still pass; the same DNS-rebinding
        // limitation documented on `RemoteImageURLPolicy` applies (a public-looking hostname can
        // still resolve to a private IP).
        guard !RemoteImageURLPolicy.isDisallowedHost(host) else { return false }
        return true
    }

    static func isInternalNostrURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "nostr",
            let reference = nostrReference(from: url)
        else { return false }
        return isRecognizedNostrReference(reference)
    }

    static func nostrReference(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "nostr" else { return nil }
        let absolute = url.absoluteString
        guard let separator = absolute.firstIndex(of: ":") else { return nil }
        let reference = String(absolute[absolute.index(after: separator)...])
        guard !reference.isEmpty else { return nil }
        return reference
    }

    /// A profile reference is resolvable only when the payload after its prefix stays inside the
    /// bech32 alphabet — a prefix-only match would let a ref with an embedded `@domain` reparse
    /// as NIP-05 downstream and beacon a request to an attacker-chosen host.
    static func isResolvableProfileReference(_ reference: String) -> Bool {
        let normalized = reference.lowercased()
        guard let prefix = resolvableProfilePrefixes.first(where: normalized.hasPrefix) else {
            return false
        }
        let payload = normalized.dropFirst(prefix.count)
        return !payload.isEmpty && payload.allSatisfy(bech32DataAlphabet.contains)
    }

    /// True when `value` carries a nostr reference marker anywhere in it. Such strings must never
    /// be reinterpreted as NIP-05 identifiers, only the FFI parse may consume them. Matched as a
    /// substring, deliberately over-inclusive — over-skipping NIP-05 fails safe (the FFI parse
    /// still resolves genuine references), while under-skipping would let a marked string reach
    /// the resolver. A NIP-05 handle whose local part merely contains a marker is negligibly rare.
    static func containsNostrReferenceMarker(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalized.contains("nostr:") { return true }
        return resolvableProfilePrefixes.contains { normalized.contains($0) }
    }

    static func isProfileReferenceInput(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let reference: String
        if normalized.hasPrefix("nostr:") {
            reference = String(normalized.dropFirst("nostr:".count))
        } else {
            reference = normalized
        }
        return hasNostrPrefix(in: reference, prefixes: resolvableProfilePrefixes)
    }

    private static func isRecognizedNostrReference(_ reference: String) -> Bool {
        hasNostrPrefix(in: reference, prefixes: recognizedNostrReferencePrefixes)
    }

    private static func hasNostrPrefix(in reference: String, prefixes: [String]) -> Bool {
        let normalized = reference.lowercased()
        return prefixes.contains { normalized.hasPrefix($0) }
    }
}
