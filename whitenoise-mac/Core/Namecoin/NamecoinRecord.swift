//
//  NamecoinRecord.swift
//  whitenoise-mac
//
//  Namecoin value-record parsing: verbose-transaction value extraction, the
//  ifa-0001 `import` chain, and the fail-closed nostr identity extraction.
//
//  Ported from whitenoise-linux `app/namecoin.odin` (commit 79447095f2),
//  preserving its fail-closed semantics exactly:
//
//  * a missing local part never silently substitutes the domain owner's key
//    (`alice@example.bit` against a record that only names `bob` and `_` is
//    Not_Found, not the `_` entry),
//  * a root lookup against a record without an `_` entry is Not_Found (never
//    picks an arbitrary `names` map entry),
//  * identity extraction requires a top-level `pubkey`; no fallback to a
//    `names` sub-object's owner key,
//  * the `_` fallback for `d/` root lookups IS kept (domain-owner convention).
//
//  Import expansion is a non-destructive merge: Swift dictionaries are value
//  types, so the clone-and-merge the Odin rewrite arrived at is the natural
//  shape here — the parsed source tree and the expanded result never alias.
//

import Foundation

/// What came out of a name value's `nostr` field.
nonisolated struct NamecoinResolution: Equatable, Sendable {
    /// 64 lowercase hex.
    let pubkeyHex: String
    let relays: [String]
    let namecoinName: String
    let localPart: String
}

/// Tri-state lookup outcome, distinguishing not-found from unavailable so the UI can tell
/// "name doesn't exist" apart from "can't reach ElectrumX". Same shape as upstream
/// `Nc_Status`.
nonisolated enum NamecoinLookup: Equatable, Sendable {
    case resolved(NamecoinResolution)
    case notFound
    case unavailable
}

/// One parsed ifa-0001 import operation.
nonisolated struct NamecoinImportOp: Equatable, Sendable {
    let name: String
    let selector: String
}

nonisolated enum NamecoinRecord {
    static let hexPubkeyLength = 64
    /// ifa-0001 import-chain depth, spec minimum. Matches `NC_IMPORT_MAX_DEPTH`.
    static let importMaxDepth = 4

    // MARK: - JSON helpers

    /// Parse a JSON object body; `nil` for non-object or malformed input.
    static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    static func isHexPubkey(_ string: String) -> Bool {
        string.count == hexPubkeyLength && string.allSatisfy(\.isHexDigit)
    }

    // MARK: - ElectrumX reply extraction

    /// Pull the last entry of a `blockchain.scripthash.get_history` reply: array of
    /// `{tx_hash, height}`. `nil` for empty or malformed history — an empty history is a
    /// definitive Namecoin miss (the name was never registered).
    static func lastHistoryEntry(from body: String) -> (txHash: String, height: Int)? {
        guard let root = jsonObject(body),
            let array = root["result"] as? [[String: Any]],
            let last = array.last,
            let txHash = last["tx_hash"] as? String,
            let height = (last["height"] as? NSNumber)?.intValue
        else { return nil }
        return (txHash, height)
    }

    /// Best-effort chain height out of a `blockchain.headers.subscribe` reply; 0 when absent.
    static func headerHeight(from body: String) -> Int {
        guard let root = jsonObject(body),
            let result = root["result"] as? [String: Any],
            let height = result["height"] as? NSNumber
        else { return 0 }
        return height.intValue
    }

    /// Extract the raw name value string from a verbose transaction reply by walking its
    /// `vout[]` and matching the OP_NAME_UPDATE / FIRSTUPDATE vout carrying `name`.
    static func extractValue(fromTransactionBody body: String, name: String) -> String {
        guard let root = jsonObject(body),
            let tx = root["result"] as? [String: Any],
            let vout = tx["vout"] as? [[String: Any]]
        else { return "" }
        let hexes = vout.compactMap { entry -> String? in
            (entry["scriptPubKey"] as? [String: Any])?["hex"] as? String
        }
        return NamecoinScript.extractNameValue(fromVoutHexes: hexes, name: name)
    }

    // MARK: - ifa-0001 import chain

    /// Parse `valueJSON` and, if it declares any `import`, return a fresh object graph with
    /// those imports expanded and merged in importer-wins order. `fetchImport` resolves one
    /// imported name to its parsed value tree; a `nil` return collapses to "empty imported
    /// object" (both unavailable and not-found collapse per gitworkshop semantics — only the
    /// root's availability drives the resolver's tri-state signal).
    static func resolveValueWithImports(
        _ valueJSON: String,
        maxDepth: Int = importMaxDepth,
        fetchImport: (String) async -> [String: Any]?
    ) async -> [String: Any]? {
        guard let root = jsonObject(valueJSON) else { return nil }
        var visited: Set<String> = []
        return await expandImports(root, budget: maxDepth, visited: &visited, fetchImport: fetchImport)
    }

    /// Recursive import expansion. Non-destructive: `object` is read-only; the result is a
    /// new dictionary (value-type copies make aliasing impossible).
    private static func expandImports(
        _ object: [String: Any],
        budget: Int,
        visited: inout Set<String>,
        fetchImport: (String) async -> [String: Any]?
    ) async -> [String: Any] {
        // Start with everything in `object` except `import`.
        var base = object
        base.removeValue(forKey: "import")

        guard budget > 0, let importValue = object["import"] else { return base }
        let ops = parseImportItem(importValue)
        guard !ops.isEmpty else { return base }

        var accumulator: [String: Any] = [:]
        for op in ops {
            let key = "\(op.name)|\(op.selector)"
            if visited.contains(key) { continue }
            visited.insert(key)
            defer { visited.remove(key) }

            guard let importedRoot = await fetchImport(op.name) else { continue }
            guard let selected = applySelector(importedRoot, selector: op.selector) else { continue }
            let expanded = await expandImports(
                selected,
                budget: budget - 1,
                visited: &visited,
                fetchImport: fetchImport
            )
            mergeImporterWins(importer: &accumulator, imported: expanded)
        }
        mergeImporterWins(importer: &base, imported: accumulator)
        return base
    }

    /// Merge `imported` underneath `importer` with importer-wins semantics: keys the
    /// importer already has are kept; everything else is taken from `imported`.
    static func mergeImporterWins(importer: inout [String: Any], imported: [String: Any]) {
        for (key, value) in imported where importer[key] == nil {
            importer[key] = value
        }
    }

    /// Parse an ifa-0001 `import` directive. Shorthand string form (`"import": "d/foo"`),
    /// canonical nested form (`[[name, selector], ...]`), and shorthand pair form
    /// (`[name, selector]`) are all accepted; a selector ending in `.` is rejected.
    static func parseImportItem(_ item: Any) -> [NamecoinImportOp] {
        if let string = item as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [NamecoinImportOp(name: trimmed, selector: "")]
        }
        guard let array = item as? [Any], !array.isEmpty else { return [] }
        if array.first is [Any] {
            return array.compactMap { entry in
                (entry as? [Any]).flatMap(opFromArray)
            }
        }
        return opFromArray(array).map { [$0] } ?? []
    }

    private static func opFromArray(_ array: [Any]) -> NamecoinImportOp? {
        guard let nameValue = array.first as? String else { return nil }
        let name = nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var selector = ""
        if array.count >= 2 {
            guard let selectorValue = array[1] as? String else { return nil }
            selector = selectorValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !selector.hasSuffix(".") else { return nil }
        return NamecoinImportOp(name: name, selector: selector)
    }

    /// Walk a DNS-dotted selector into `root.map`, priority exact → `*` wildcard → `""`
    /// default. `nil` for a selector that walks off the tree. Labels walk right-to-left,
    /// matching upstream `nc_apply_selector`.
    static func applySelector(_ root: [String: Any], selector: String) -> [String: Any]? {
        let labels = selector.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard !labels.isEmpty else { return root }
        var current = root
        for label in labels.reversed() {
            guard let map = current["map"] as? [String: Any] else { return nil }
            if let exact = map[label] as? [String: Any] {
                current = exact
            } else if let wildcard = map["*"] as? [String: Any] {
                current = wildcard
            } else if let fallback = map[""] as? [String: Any] {
                current = fallback
            } else {
                return nil
            }
        }
        return current
    }

    // MARK: - nostr field extraction (fail closed)

    /// Pull pubkey + relays out of the merged value tree.
    static func extractNostr(from value: [String: Any], parsed: NamecoinParsedIdentifier) -> NamecoinLookup {
        guard let field = value["nostr"] else { return .notFound }

        // Simple form: "nostr": "hex-pubkey".
        if let string = field as? String {
            // A bare key names the record owner; it cannot stand in for a named user.
            guard !parsed.isDomain || parsed.localPart == "_", isHexPubkey(string) else {
                return .notFound
            }
            return .resolved(
                NamecoinResolution(
                    pubkeyHex: string.lowercased(),
                    relays: [],
                    namecoinName: parsed.namecoinName,
                    localPart: "_"
                ))
        }

        guard let nostrObject = field as? [String: Any] else { return .notFound }
        if parsed.isDomain {
            return extractFromDomain(nostrObject, parsed: parsed)
        }
        return extractFromIdentity(nostrObject, parsed: parsed)
    }

    /// Domain-shape extraction. FAIL CLOSED: `alice@example.bit` must resolve to alice's
    /// entry or to nothing — never to `_` (that would silently substitute the domain
    /// owner's identity) and never to "the first valid entry" (that would substitute an
    /// arbitrary other user for the root when the record has no `_`).
    static func extractFromDomain(
        _ nostr: [String: Any],
        parsed: NamecoinParsedIdentifier
    ) -> NamecoinLookup {
        guard let names = nostr["names"] as? [String: Any] else {
            // Some d/ records use the identity-style flat shape (bare `"pubkey": ...` at
            // the root of the `nostr` object). Accept it only for the root (`_`) — for any
            // other local part the identity-style shape does not name them.
            guard parsed.localPart == "_" else { return .notFound }
            return extractFromIdentity(nostr, parsed: parsed)
        }

        guard let entry = names[parsed.localPart] as? String, isHexPubkey(entry) else {
            return .notFound
        }
        return .resolved(
            NamecoinResolution(
                pubkeyHex: entry.lowercased(),
                relays: extractRelays(from: nostr, pubkey: entry),
                namecoinName: parsed.namecoinName,
                localPart: parsed.localPart
            ))
    }

    /// Identity-shape extraction: accept the top-level `pubkey` binding only. A `names`
    /// sub-object belongs to domain (`d/`) records; treating it as an identity-owner key
    /// silently substitutes somebody else's identity for the requested name.
    ///
    /// A `d/` root lookup whose record uses the identity shape also lands here; the caller
    /// has already checked `parsed.localPart == "_"`, so accepting the flat `pubkey` is
    /// well-defined.
    static func extractFromIdentity(
        _ nostr: [String: Any],
        parsed: NamecoinParsedIdentifier
    ) -> NamecoinLookup {
        guard let pubkey = nostr["pubkey"] as? String, isHexPubkey(pubkey) else {
            return .notFound
        }
        let relays: [String]
        if let array = nostr["relays"] as? [Any] {
            relays = array.compactMap { $0 as? String }
        } else {
            relays = []
        }
        return .resolved(
            NamecoinResolution(
                pubkeyHex: pubkey.lowercased(),
                relays: relays,
                namecoinName: parsed.namecoinName,
                localPart: "_"
            ))
    }

    /// Relay hints for a resolved pubkey: the domain shape keys a map by pubkey, the
    /// identity shape is a flat array.
    static func extractRelays(from nostr: [String: Any], pubkey: String) -> [String] {
        guard let raw = nostr["relays"] else { return [] }
        if let map = raw as? [String: Any] {
            let array = (map[pubkey.lowercased()] ?? map[pubkey]) as? [Any]
            return array?.compactMap { $0 as? String } ?? []
        }
        if let array = raw as? [Any] {
            return array.compactMap { $0 as? String }
        }
        return []
    }
}
