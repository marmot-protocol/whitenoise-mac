//
//  MarkdownLinkPolicy.swift
//  whitenoise-mac
//
//  Safety policy for links rendered from untrusted peer Markdown.
//

import Foundation

/// Peer-controlled message text must never be allowed to hand arbitrary URL schemes to
/// LaunchServices. `http`/`https` links may be handed to the system browser after the app-side
/// `OpenURLAction` gate runs; `nostr:` links are handled internally by `WorkspaceState`.
nonisolated enum MarkdownLinkPolicy {
    private static let resolvableProfilePrefixes = ["npub1", "nprofile1"]
    private static let recognizedNostrReferencePrefixes =
        resolvableProfilePrefixes + ["note1", "nevent1", "naddr1", "nrelay1"]

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
        isAllowedExternalURL(url) || isInternalNostrURL(url)
    }

    static func isAllowedExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host, !host.isEmpty else { return false }
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

    static func isResolvableProfileReference(_ reference: String) -> Bool {
        hasNostrPrefix(in: reference, prefixes: resolvableProfilePrefixes)
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
