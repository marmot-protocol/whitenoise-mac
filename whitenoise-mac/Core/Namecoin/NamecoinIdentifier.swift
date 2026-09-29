//
//  NamecoinIdentifier.swift
//  whitenoise-mac
//
//  The `.bit` front door: decide whether an identifier routes to Namecoin
//  resolution rather than a DNS-based NIP-05 verifier, and parse it into a
//  structured lookup request.
//
//  Ported from whitenoise-linux `app/namecoin.odin` `nc_is_bit` / `nc_parse`
//  (commit 79447095f2). Accepts `alice@example.bit`, `example.bit`,
//  `d/example`, `id/alice`, and tolerates a leading NIP-21 `nostr:`.
//

import Foundation

/// A structured Namecoin lookup request.
nonisolated struct NamecoinParsedIdentifier: Equatable, Sendable {
    /// e.g. `"d/example"` or `"id/alice"` — the key in the Namecoin name index.
    let namecoinName: String
    /// The local part of a `user@domain.bit` lookup; `"_"` for the root.
    let localPart: String
    /// `false` for `id/` identity names.
    let isDomain: Bool
}

nonisolated enum NamecoinIdentifier {
    /// True when `identifier` should be routed to Namecoin resolution rather than a
    /// DNS-based NIP-05 verifier. Cheap enough to gate a hot path. Matches the front-door
    /// check the gitworkshop TS and Amethyst implementations use (and the upstream Odin
    /// `nc_is_bit`).
    static func isBit(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var lower = trimmed.lowercased()
        if lower.hasPrefix("nostr:") {
            lower = String(lower.dropFirst("nostr:".count))
        }
        if lower.hasPrefix("d/") {
            return lower.count > 2
        }
        if lower.hasPrefix("id/") {
            return lower.count > 3
        }
        return lower.hasSuffix(".bit") && lower.count > 4
    }

    /// Parse `raw` into a structured request. Returns `nil` for non-Namecoin identifiers.
    static func parse(_ raw: String) -> NamecoinParsedIdentifier? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        // Tolerate a leading NIP-21 `nostr:`.
        if input.count >= 6, input.prefix(6).lowercased() == "nostr:" {
            input = String(input.dropFirst(6))
        }
        let lower = input.lowercased()

        if lower.hasPrefix("d/") {
            guard lower.count > 2 else { return nil }
            return NamecoinParsedIdentifier(namecoinName: lower, localPart: "_", isDomain: true)
        }
        if lower.hasPrefix("id/") {
            guard lower.count > 3 else { return nil }
            return NamecoinParsedIdentifier(namecoinName: lower, localPart: "_", isDomain: false)
        }

        if input.contains("@"), lower.hasSuffix(".bit"),
            let atIndex = input.firstIndex(of: "@")
        {
            let localRaw = input[..<atIndex]
            let local = localRaw.isEmpty ? "_" : localRaw.lowercased()
            var domainRaw = input[input.index(after: atIndex)...].lowercased()
            guard domainRaw.hasSuffix(".bit") else { return nil }
            domainRaw = String(domainRaw.dropLast(4))
            guard !domainRaw.isEmpty else { return nil }
            return NamecoinParsedIdentifier(
                namecoinName: "d/\(domainRaw)",
                localPart: local,
                isDomain: true
            )
        }

        if lower.hasSuffix(".bit") {
            let domain = String(lower.dropLast(4))
            guard !domain.isEmpty else { return nil }
            return NamecoinParsedIdentifier(
                namecoinName: "d/\(domain)",
                localPart: "_",
                isDomain: true
            )
        }
        return nil
    }

    /// Normalized cache key: trimmed + lowercased, same as upstream `nc_normalize`.
    static func normalize(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
