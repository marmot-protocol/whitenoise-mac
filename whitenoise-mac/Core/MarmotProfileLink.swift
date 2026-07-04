//
//  MarmotProfileLink.swift
//  whitenoise-mac
//
//  Single source of truth for the marmot://profile/<npub|nprofile> link form
//  (MIP deep-link scheme, mdk#725): QR emission, OS deep-link parsing, and the
//  New Chat paste pre-check all go through here so they cannot drift apart.
//

import Foundation

nonisolated enum MarmotProfileLink {
    static let scheme = "marmot"
    private static let profileHost = "profile"
    private static let profilePrefix = "marmot://profile/"

    /// Payload encoded into the public-identity QR code. The `from=qr` marker
    /// matches what other White Noise clients emit and is ignored on parse.
    static func qrPayload(npub: String) -> String {
        "\(profilePrefix)\(npub)?from=qr"
    }

    /// Extract the profile reference from a strict `marmot://profile/<ref>` URL.
    ///
    /// Inbound URLs are untrusted (the scheme is not exclusive to this app), so
    /// only the exact profile form with a single resolvable `npub1`/`nprofile1`
    /// path component is accepted; query (`?from=qr`) is ignored, and every
    /// other `marmot://` shape returns nil.
    static func profileReference(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
            url.host?.lowercased() == profileHost
        else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1,
            let reference = components.first,
            MarkdownLinkPolicy.isResolvableProfileReference(reference)
        else { return nil }
        return reference
    }

    /// Cheap pre-check for pasted input; `normalizeMemberRef` on the FFI side
    /// does the authoritative parse.
    static func hasProfileLinkPrefix(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix(profilePrefix)
    }
}
