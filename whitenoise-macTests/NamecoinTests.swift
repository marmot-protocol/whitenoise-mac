//
//  NamecoinTests.swift
//  whitenoise-macTests
//
//  Namecoin `.bit` resolver: pure-function tests for the parts that do not touch the
//  ElectrumX network (identifier parsing, script assembly, scripthash derivation,
//  name-op vout decoding, fail-closed record extraction, import expansion) and
//  resolver-level tests against a scripted transport. Ported from whitenoise-linux
//  `tests/app/namecoin_test.odin` (commit 79447095f2).
//

import Foundation
import Testing

@testable import whitenoise_mac

struct NamecoinTests {
    // MARK: - identifier gate

    @Test func isBitPositives() {
        #expect(NamecoinIdentifier.isBit("alice@example.bit"))
        #expect(NamecoinIdentifier.isBit("Alice@Example.BIT"))
        #expect(NamecoinIdentifier.isBit("example.bit"))
        #expect(NamecoinIdentifier.isBit("nostr:example.bit"))
        #expect(NamecoinIdentifier.isBit("d/example"))
        #expect(NamecoinIdentifier.isBit("id/alice"))
        #expect(NamecoinIdentifier.isBit("  d/example  "))
    }

    @Test func isBitNegatives() {
        #expect(!NamecoinIdentifier.isBit(""))
        #expect(!NamecoinIdentifier.isBit(".bit"))
        #expect(!NamecoinIdentifier.isBit("d/"))
        #expect(!NamecoinIdentifier.isBit("id/"))
        #expect(!NamecoinIdentifier.isBit("example.com"))
        #expect(!NamecoinIdentifier.isBit("alice@example.com"))
        #expect(!NamecoinIdentifier.isBit("npub1w90qcnzy9pxxaanl7zt50pgn8gj9tnpwd3wkfnq8fj0h4pft2eus5at3v3"))
    }

    // MARK: - identifier parsing

    @Test func parseBareDomain() throws {
        let parsed = try #require(NamecoinIdentifier.parse("Example.BIT"))
        #expect(parsed.namecoinName == "d/example")
        #expect(parsed.localPart == "_")
        #expect(parsed.isDomain)
    }

    @Test func parseUserAtDomain() throws {
        let parsed = try #require(NamecoinIdentifier.parse("Alice@Example.bit"))
        #expect(parsed.namecoinName == "d/example")
        #expect(parsed.localPart == "alice")
        #expect(parsed.isDomain)
    }

    @Test func parseEmptyLocalPart() throws {
        // Empty local-part falls back to the root entry.
        let parsed = try #require(NamecoinIdentifier.parse("@example.bit"))
        #expect(parsed.localPart == "_")
    }

    @Test func parseDSlash() throws {
        let parsed = try #require(NamecoinIdentifier.parse("d/Foo"))
        #expect(parsed.namecoinName == "d/foo")
        #expect(parsed.localPart == "_")
        #expect(parsed.isDomain)
    }

    @Test func parseIDSlash() throws {
        let parsed = try #require(NamecoinIdentifier.parse("id/Alice"))
        #expect(parsed.namecoinName == "id/alice")
        #expect(parsed.localPart == "_")
        #expect(!parsed.isDomain)
    }

    @Test func parseNostrPrefix() throws {
        let parsed = try #require(NamecoinIdentifier.parse("nostr:example.bit"))
        #expect(parsed.namecoinName == "d/example")
    }

    @Test func parseRejectsNonBit() {
        #expect(NamecoinIdentifier.parse("example.com") == nil)
        #expect(NamecoinIdentifier.parse("d/") == nil)
        #expect(NamecoinIdentifier.parse("") == nil)
    }

    // MARK: - script assembly + scripthash

    @Test func scriptLayoutForShortName() {
        // Short names use the direct-length push opcode: the first byte after
        // OP_NAME_UPDATE is the name length, not a PUSHDATA opcode.
        let name = Array("d/example".utf8)
        let script = NamecoinScript.buildNameIndexScript(name: name)
        // OP_NAME_UPDATE (0x53) | len=9 | name bytes | 0x00 (empty value push)
        // | OP_2DROP (0x6d) | OP_DROP (0x75) | OP_RETURN (0x6a)
        #expect(script[0] == 0x53)
        #expect(script[1] == UInt8(name.count))
        for (index, byte) in name.enumerated() {
            #expect(script[2 + index] == byte)
        }
        let tail = 2 + name.count
        #expect(script[tail] == 0x00)
        #expect(script[tail + 1] == 0x6D)
        #expect(script[tail + 2] == 0x75)
        #expect(script[tail + 3] == 0x6A)
    }

    @Test func scripthashMatchesReferenceVectors() {
        // Ground truth: SHA-256 of the name-index script, byte-reversed, lowercase hex —
        // the exact digest ElectrumX keys `blockchain.scripthash.get_history` by.
        let vectors: [(String, String)] = [
            ("d/example", "92f51fe51fa9c53ea842325c9c63a9b8592b3f64c7477b6e538a64d80cd8c0ac"),
            ("d/x", "4479660d853c00394a3aca82f1c65652662d2d2e66eb0eea6baf4a4a343a6d8a"),
            ("id/alice", "9ed8755882d3a40faba01df22e83b85d62fda02d9ebed68c34101f04ea9a853e"),
            ("d/mstrofnone", "4975bc3120749faf95ae70a06bf3d83a697cbb56a9bc17f1ffa252e456137557"),
        ]
        for (name, expected) in vectors {
            let script = NamecoinScript.buildNameIndexScript(name: Array(name.utf8))
            #expect(NamecoinScript.electrumScripthash(script) == expected, "scripthash mismatch for \(name)")
        }
    }

    @Test func scripthashDeterministic() {
        let script = NamecoinScript.buildNameIndexScript(name: Array("d/example".utf8))
        let first = NamecoinScript.electrumScripthash(script)
        let second = NamecoinScript.electrumScripthash(script)
        #expect(first == second)
        #expect(first.count == 64)
    }

    // MARK: - name-op vout decoding

    @Test func parseOpNameUpdate() throws {
        // OP_NAME_UPDATE <push "d/example"> <push "hello"> <trailer>
        let script = Self.nameUpdateScriptHexDecoded(name: "d/example", value: "hello")
        let parsed = try #require(NamecoinScript.parseNameScript(script))
        #expect(parsed.name == "d/example")
        #expect(parsed.value == "hello")
    }

    @Test func parseOpNameFirstUpdate() throws {
        // OP_NAME_FIRSTUPDATE <push name> <push 20-byte rand> <push value> <trailer>
        let name = Array("d/mstrofnone".utf8)
        let value = Array(#"{"nostr":"deadbeef"}"#.utf8)
        var script: [UInt8] = [0x52, UInt8(name.count)] + name
        script.append(20)
        script.append(contentsOf: [UInt8](repeating: 0xAA, count: 20))
        script.append(UInt8(value.count))
        script.append(contentsOf: value)
        script.append(contentsOf: [0x6D, 0x6D, 0x75, 0x6A])
        let parsed = try #require(NamecoinScript.parseNameScript(script))
        #expect(parsed.name == "d/mstrofnone")
        #expect(parsed.value == #"{"nostr":"deadbeef"}"#)
    }

    @Test func parseRejectsOpNameNew() {
        // OP_NAME_NEW (0x51) carries no visible value.
        let script: [UInt8] = [0x51, 0x02, 0xAA, 0xBB, 0x75, 0x6A]
        #expect(NamecoinScript.parseNameScript(script) == nil)
    }

    @Test func hexDecodeRoundtrip() throws {
        let input: [UInt8] = [0x00, 0x53, 0xFF, 0xA1, 0x0D]
        let hex = input.map { String(format: "%02x", $0) }.joined()
        let back = try #require(NamecoinScript.hexDecode(hex))
        #expect(back == input)
        #expect(NamecoinScript.hexDecode("0xnothex") == nil)
        #expect(NamecoinScript.hexDecode("abc") == nil)  // odd length
    }

    @Test func extractNameValueMatches() {
        // A vout paying a plain p2pkh must be skipped by the front-door filter; the
        // name-carrying vout wins; a non-matching name returns empty.
        let updateHex = Self.hexString(Self.nameUpdateScriptHexDecoded(name: "d/x", value: "V"))
        let p2pkh = "76a914aabbccddeeff112233445566778899aabbccddee88ac"
        #expect(NamecoinScript.extractNameValue(fromVoutHexes: [p2pkh, updateHex], name: "d/x") == "V")
        #expect(NamecoinScript.extractNameValue(fromVoutHexes: [updateHex], name: "d/y") == "")
    }

    // MARK: - nc_extract_from_domain: fail closed
    //
    // These exercise the security-critical branch that previously silently substituted
    // `_` (root) or "first valid entry" for a missing requested identity. Both fallbacks
    // are gone upstream and stay gone here: a missing entry resolves to notFound instead
    // of another party's pubkey.

    @Test func extractFromDomainMissingLocalPartFailsClosed() throws {
        // alice@example.bit against a record that only names bob and `_` must be
        // notFound — falling back to `_` would silently attach the domain owner's
        // identity to alice's invite.
        let nostr = try #require(NamecoinRecord.jsonObject(#"{"names":{"bob":"\#(Self.bob)","_":"\#(Self.alice)"}}"#))
        let parsed = try #require(NamecoinIdentifier.parse("alice@example.bit"))
        #expect(NamecoinRecord.extractFromDomain(nostr, parsed: parsed) == .notFound)
    }

    @Test func extractFromDomainRootWithoutUnderscoreFailsClosed() throws {
        // The root of a domain whose `names` map has entries but no `_` must be
        // notFound. Picking "the first valid key" would be attacker-controlled
        // substitution.
        let nostr = try #require(
            NamecoinRecord.jsonObject(#"{"names":{"alice":"\#(Self.alice)","bob":"\#(Self.bob)"}}"#))
        let parsed = try #require(NamecoinIdentifier.parse("example.bit"))
        #expect(NamecoinRecord.extractFromDomain(nostr, parsed: parsed) == .notFound)
    }

    @Test func extractFromDomainExactMatchResolves() throws {
        // Positive control: alice@example.bit returns alice's pubkey.
        let nostr = try #require(NamecoinRecord.jsonObject(#"{"names":{"alice":"\#(Self.alice)"}}"#))
        let parsed = try #require(NamecoinIdentifier.parse("alice@example.bit"))
        guard case .resolved(let resolution) = NamecoinRecord.extractFromDomain(nostr, parsed: parsed) else {
            Issue.record("expected resolved")
            return
        }
        #expect(resolution.pubkeyHex == Self.alice)
        #expect(resolution.localPart == "alice")
    }

    @Test func extractFromDomainRootWithUnderscoreResolves() throws {
        let nostr = try #require(NamecoinRecord.jsonObject(#"{"names":{"_":"\#(Self.alice)","bob":"\#(Self.bob)"}}"#))
        let parsed = try #require(NamecoinIdentifier.parse("example.bit"))
        guard case .resolved(let resolution) = NamecoinRecord.extractFromDomain(nostr, parsed: parsed) else {
            Issue.record("expected resolved")
            return
        }
        #expect(resolution.pubkeyHex == Self.alice)
        #expect(resolution.localPart == "_")
    }

    @Test func extractFromDomainPicksUpRelayHints() throws {
        let raw = #"{"names":{"alice":"\#(Self.alice)"},"relays":{"\#(Self.alice)":["wss://one","wss://two"]}}"#
        let nostr = try #require(NamecoinRecord.jsonObject(raw))
        let parsed = try #require(NamecoinIdentifier.parse("alice@example.bit"))
        guard case .resolved(let resolution) = NamecoinRecord.extractFromDomain(nostr, parsed: parsed) else {
            Issue.record("expected resolved")
            return
        }
        #expect(resolution.relays == ["wss://one", "wss://two"])
    }

    // MARK: - id/ identity records: no cross-shape substitution

    @Test func extractFromIdentityRejectsNamesFallback() throws {
        // An id/ record carrying only a `names` sub-object (no top-level `pubkey`) must
        // be notFound — accepting `names._` would silently return whatever key that map
        // holds instead of the identity's own pubkey.
        let nostr = try #require(NamecoinRecord.jsonObject(#"{"names":{"_":"\#(Self.alice)"}}"#))
        let parsed = try #require(NamecoinIdentifier.parse("id/alice"))
        #expect(NamecoinRecord.extractFromIdentity(nostr, parsed: parsed) == .notFound)
    }

    @Test func extractFromIdentityAcceptsFlatPubkey() throws {
        let nostr = try #require(NamecoinRecord.jsonObject(#"{"pubkey":"\#(Self.bob)"}"#))
        let parsed = try #require(NamecoinIdentifier.parse("id/alice"))
        guard case .resolved(let resolution) = NamecoinRecord.extractFromIdentity(nostr, parsed: parsed) else {
            Issue.record("expected resolved")
            return
        }
        #expect(resolution.pubkeyHex == Self.bob)
    }

    @Test func extractNostrSimpleStringForm() throws {
        // "nostr": "hex-pubkey" names the record owner: fine for the root, never for a
        // named user of a domain.
        let rootParsed = try #require(NamecoinIdentifier.parse("example.bit"))
        let aliceParsed = try #require(NamecoinIdentifier.parse("alice@example.bit"))
        let value = try #require(NamecoinRecord.jsonObject(#"{"nostr":"\#(Self.alice)"}"#))
        guard case .resolved(let resolution) = NamecoinRecord.extractNostr(from: value, parsed: rootParsed) else {
            Issue.record("expected resolved for the root lookup")
            return
        }
        #expect(resolution.pubkeyHex == Self.alice)
        #expect(NamecoinRecord.extractNostr(from: value, parsed: aliceParsed) == .notFound)
    }

    @Test func extractNostrRejectsNonHexPubkey() throws {
        let value = try #require(NamecoinRecord.jsonObject(#"{"nostr":"not-a-pubkey"}"#))
        let parsed = try #require(NamecoinIdentifier.parse("example.bit"))
        #expect(NamecoinRecord.extractNostr(from: value, parsed: parsed) == .notFound)
    }

    // MARK: - import expansion

    @Test func resolveValueNoImportReturnsTreeWithoutImportKey() async throws {
        let expanded = try #require(
            await NamecoinRecord.resolveValueWithImports(#"{"nostr":{"pubkey":"\#(Self.alice)"}}"#) { _ in nil }
        )
        #expect(expanded["nostr"] != nil)
        #expect(expanded["import"] == nil)
    }

    @Test func resolveValueEmptyImportKeepsEverythingElse() async throws {
        // `"import":[]` must not disturb the rest of the record (the upstream reviewer's
        // exact repro against the old move-children expansion).
        let expanded = try #require(
            await NamecoinRecord.resolveValueWithImports(#"{"import":[],"nostr":{"pubkey":"\#(Self.bob)"}}"#) { _ in nil
            }
        )
        #expect(expanded["import"] == nil)
        #expect(expanded["nostr"] != nil)
    }

    @Test func resolveValueNestedMapSurvives() async throws {
        let raw =
            #"{"import":[],"nostr":{"names":{"alice":"\#(Self.alice)"},"relays":{"\#(Self.alice)":["wss://one","wss://two"]}}}"#
        let expanded = try #require(await NamecoinRecord.resolveValueWithImports(raw) { _ in nil })
        let nostr = try #require(expanded["nostr"] as? [String: Any])
        let names = try #require(nostr["names"] as? [String: Any])
        #expect(names["alice"] as? String == Self.alice)
        let relays = try #require(nostr["relays"] as? [String: Any])
        #expect(relays[Self.alice] as? [String] == ["wss://one", "wss://two"])
    }

    @Test func importExpansionImporterWins() async throws {
        // The importer's own keys beat anything the imported record carries; keys the
        // importer lacks are filled in from the import.
        let imported = #"{"nostr":{"pubkey":"\#(Self.alice)"},"extra":"filled"}"#
        let expanded = try #require(
            await NamecoinRecord.resolveValueWithImports(#"{"import":"d/base","nostr":{"pubkey":"\#(Self.bob)"}}"#) {
                name in
                #expect(name == "d/base")
                return NamecoinRecord.jsonObject(imported)
            }
        )
        let nostr = try #require(expanded["nostr"] as? [String: Any])
        #expect(nostr["pubkey"] as? String == Self.bob)
        #expect(expanded["extra"] as? String == "filled")
    }

    @Test func importExpansionAppliesSelector() async throws {
        let imported = #"{"map":{"com":{"map":{"example":{"nostr":{"pubkey":"\#(Self.alice)"}}}}}}"#
        let expanded = try #require(
            await NamecoinRecord.resolveValueWithImports(#"{"import":[["d/base","example.com"]]}"#) { _ in
                NamecoinRecord.jsonObject(imported)
            }
        )
        let nostr = try #require(expanded["nostr"] as? [String: Any])
        #expect(nostr["pubkey"] as? String == Self.alice)
    }

    @Test func importExpansionCycleGuardTerminates() async throws {
        // a imports b, b imports a: the per-path visited set must stop the walk.
        let a = #"{"import":"d/b","marker":"a"}"#
        let b = #"{"import":"d/a","marker":"b"}"#
        let expanded = await NamecoinRecord.resolveValueWithImports(a) { name in
            name == "d/b" ? NamecoinRecord.jsonObject(b) : NamecoinRecord.jsonObject(a)
        }
        #expect(expanded != nil)
    }

    @Test func importExpansionDepthBudgetStopsTheWalk() async throws {
        // Chain a -> b -> c -> d -> e. With the budget of 4 the walk fetches a, b, c, d
        // and never asks for e.
        var fetched: [String] = []
        let names = ["d/a", "d/b", "d/c", "d/d", "d/e"]
        _ = await NamecoinRecord.resolveValueWithImports(#"{"import":"d/a"}"#, maxDepth: 4) { name in
            fetched.append(name)
            guard let index = names.firstIndex(of: name), index + 1 < names.count else {
                return ["leaf": "end"]
            }
            return ["import": names[index + 1]]
        }
        #expect(fetched == ["d/a", "d/b", "d/c", "d/d"])
    }

    @Test func parseImportItemForms() {
        // Shorthand string form.
        #expect(NamecoinRecord.parseImportItem("d/foo") == [NamecoinImportOp(name: "d/foo", selector: "")])
        // Canonical nested form.
        #expect(
            NamecoinRecord.parseImportItem([["d/a", "x"], ["d/b", "y"]]) == [
                NamecoinImportOp(name: "d/a", selector: "x"),
                NamecoinImportOp(name: "d/b", selector: "y"),
            ]
        )
        // Shorthand pair form.
        #expect(NamecoinRecord.parseImportItem(["d/foo", "sel"]) == [NamecoinImportOp(name: "d/foo", selector: "sel")])
        // A selector ending in `.` is rejected.
        #expect(NamecoinRecord.parseImportItem(["d/foo", "bad."]) == [])
        // Empty string shorthand is no import at all.
        #expect(NamecoinRecord.parseImportItem("  ") == [])
    }

    @Test func applySelectorPriority() throws {
        // exact label beats `*` wildcard beats `""` default; walking off the tree fails.
        let root = try #require(
            NamecoinRecord.jsonObject(
                #"{"map":{"com":{"map":{"example":{"v":1},"*":{"v":2},"":{"v":3}}},"org":{"map":{"":{"v":4}}}}}"#
            ))
        #expect((NamecoinRecord.applySelector(root, selector: "example.com")?["v"] as? Int) == 1)
        #expect((NamecoinRecord.applySelector(root, selector: "other.com")?["v"] as? Int) == 2)
        #expect((NamecoinRecord.applySelector(root, selector: "anything.org")?["v"] as? Int) == 4)
        #expect(NamecoinRecord.applySelector(root, selector: "missing.net") == nil)
        #expect(NamecoinRecord.applySelector(root, selector: "") != nil)
    }

    // MARK: - transport envelope filter
    //
    // The Swift transport parses every envelope with JSONSerialization and accepts a
    // reply only when its top-level `id` matches — the same guarantee the C shim's
    // depth-1 byte walker + Odin re-parse pair provides, in one real parse.

    @Test func topLevelIDExtraction() {
        #expect(ElectrumXTransport.topLevelID(of: #"{"result":{"id":99},"id":2}"#) == 2)
        #expect(ElectrumXTransport.topLevelID(of: #"{"id" : 2,"result":null}"#) == 2)
        #expect(ElectrumXTransport.topLevelID(of: #"{"result":null}"#) == nil)
        #expect(ElectrumXTransport.topLevelID(of: #"{"data":"has \"id\": inside","id":7}"#) == 7)
        #expect(
            ElectrumXTransport.topLevelID(
                of: #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"nope"},"id":42}"#
            ) == 42
        )
        // Server notification (subscription push): no top-level id, keep reading.
        #expect(
            ElectrumXTransport.topLevelID(
                of: #"{"method":"blockchain.headers.subscribe","params":[{"hex":"...","height":1}]}"#
            ) == nil
        )
        // A JSON boolean is bridged to NSNumber by JSONSerialization but is not an id.
        #expect(ElectrumXTransport.topLevelID(of: #"{"id":true}"#) == nil)
        // Not an object at all.
        #expect(ElectrumXTransport.topLevelID(of: #"[1,2,3]"#) == nil)
    }

    @Test func serverURLAndPinDecoding() throws {
        let server = NamecoinServer(
            host: "nmc2.bitcoins.sk",
            port: 57002,
            path: "",
            pinnedLeafKeyBase64: "tkCCQ6AZPqU4Te1poKHeS5l/CRWYHz5n7J4LH22/LxQ="
        )
        #expect(server.url?.absoluteString == "wss://nmc2.bitcoins.sk:57002/")
        #expect(try #require(server.pinnedLeafKeySHA256).count == 32)
        // The three pinned defaults carry decodable 32-byte pins.
        for pinned in [NamecoinServer].namecoinDefaultPinned {
            #expect(pinned.pinnedLeafKeySHA256?.count == 32)
        }
    }
}

// MARK: - resolver-level tests (scripted transport)

struct NamecoinResolverTests {
    @Test func resolvesIdentityRecord() async throws {
        let transport = ScriptedElectrumXTransport()
        transport.scriptValue(Self.identityValue, forName: "id/alice", tipHeight: 1_000_000)
        let resolver = Self.makeResolver(transport: transport)
        let pubkey = try await resolver.accountReference(for: "id/alice")
        #expect(pubkey == Self.alice)
    }

    @Test func resolvesDomainRootAndUser() async throws {
        let transport = ScriptedElectrumXTransport()
        transport.scriptValue(Self.domainValue, forName: "d/example", tipHeight: 1_000_000)
        let resolver = Self.makeResolver(transport: transport)
        #expect(try await resolver.accountReference(for: "example.bit") == Self.alice)
        #expect(try await resolver.accountReference(for: "bob@example.bit") == Self.bob)
        // Missing local part fails closed at the resolver boundary too.
        var thrown: NamecoinResolutionError?
        do {
            _ = try await resolver.accountReference(for: "carol@example.bit")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        #expect(thrown == .notFound("carol@example.bit"))
    }

    @Test func resolvesThroughImportChain() async throws {
        // d/example imports d/base with a selector; the imported record carries the key.
        let transport = ScriptedElectrumXTransport()
        transport.scriptValue(#"{"import":[["d/base","example.com"]]}"#, forName: "d/example", tipHeight: 1_000_000)
        transport.scriptValue(
            #"{"map":{"com":{"map":{"example":{"nostr":{"pubkey":"\#(Self.alice)"}}}}}}"#,
            forName: "d/base",
            tipHeight: 1_000_000
        )
        let resolver = Self.makeResolver(transport: transport)
        #expect(try await resolver.accountReference(for: "example.bit") == Self.alice)
    }

    @Test func emptyHistoryIsDefinitiveMiss() async {
        let transport = ScriptedElectrumXTransport()
        // No scripted value: history comes back empty on every server.
        let resolver = Self.makeResolver(transport: transport)
        var thrown: NamecoinResolutionError?
        do {
            _ = try await resolver.accountReference(for: "missing.bit")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        #expect(thrown == .notFound("missing.bit"))
    }

    @Test func fallsBackAcrossServers() async throws {
        // First server dead at the transport layer; second has the record.
        let transport = ScriptedElectrumXTransport()
        transport.failHost("one.test")
        transport.scriptValue(Self.identityValue, forName: "id/alice", tipHeight: 1_000_000, onHosts: ["two.test"])
        let resolver = Self.makeResolver(transport: transport)
        #expect(try await resolver.accountReference(for: "id/alice") == Self.alice)
    }

    @Test func unavailableWhenEveryServerFailsTransport() async {
        let transport = ScriptedElectrumXTransport()
        transport.failHost("one.test")
        transport.failHost("two.test")
        transport.failHost("three.test")
        let resolver = Self.makeResolver(transport: transport)
        var thrown: NamecoinResolutionError?
        do {
            _ = try await resolver.accountReference(for: "id/alice")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        #expect(thrown == .unavailable)
    }

    @Test func definitiveMissLatchesButLaterServerCanStillWin() async throws {
        // Server one has indexed nothing (empty history — a definitive miss), server two
        // has the record: the walk must continue past the miss, same as upstream.
        let transport = ScriptedElectrumXTransport()
        transport.scriptValue(Self.identityValue, forName: "id/alice", tipHeight: 1_000_000, onHosts: ["two.test"])
        let resolver = Self.makeResolver(transport: transport)
        #expect(try await resolver.accountReference(for: "id/alice") == Self.alice)
    }

    @Test func expiredNameIsNotFound() async {
        let transport = ScriptedElectrumXTransport()
        transport.scriptValue(Self.identityValue, forName: "id/alice", tipHeight: 1_000_000, height: 100)
        let resolver = Self.makeResolver(transport: transport)
        var thrown: NamecoinResolutionError?
        do {
            _ = try await resolver.accountReference(for: "id/alice")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        // 1_000_000 - 100 >= 36_000 -> expired.
        #expect(thrown == .notFound("id/alice"))
    }

    @Test func positiveAndNegativeOutcomesAreCached() async throws {
        let transport = ScriptedElectrumXTransport()
        transport.scriptValue(Self.identityValue, forName: "id/alice", tipHeight: 1_000_000)
        let resolver = Self.makeResolver(transport: transport)

        _ = try await resolver.accountReference(for: "id/alice")
        let historyCallsAfterFirst = transport.historyRequestCount
        // Second lookup: cache hit, no further history requests.
        _ = try await resolver.accountReference(for: "id/alice")
        #expect(transport.historyRequestCount == historyCallsAfterFirst)

        // Negative outcome caches too: a miss asked twice costs one network round.
        var thrown: NamecoinResolutionError?
        do {
            _ = try await resolver.accountReference(for: "missing.bit")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        #expect(thrown != nil)
        let missCalls = transport.historyRequestCount
        do {
            _ = try await resolver.accountReference(for: "missing.bit")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        #expect(transport.historyRequestCount == missCalls)
    }

    @Test func unavailableIsNeverCached() async throws {
        // A transport failure must not latch: fix the servers and the next lookup wins.
        let transport = ScriptedElectrumXTransport()
        transport.failHost("one.test")
        transport.failHost("two.test")
        transport.failHost("three.test")
        let resolver = Self.makeResolver(transport: transport)
        var thrown: NamecoinResolutionError?
        do {
            _ = try await resolver.accountReference(for: "id/alice")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        #expect(thrown == .unavailable)

        let transportFixed = ScriptedElectrumXTransport()
        transportFixed.scriptValue(Self.identityValue, forName: "id/alice", tipHeight: 1_000_000)
        let fixedResolver = Self.makeResolver(transport: transportFixed)
        #expect(try await fixedResolver.accountReference(for: "id/alice") == Self.alice)
    }

    @Test func duplicateInFlightLookupsShareOneNetworkRound() async throws {
        let transport = ScriptedElectrumXTransport()
        transport.responseDelay = .milliseconds(100)
        transport.scriptValue(Self.identityValue, forName: "id/alice", tipHeight: 1_000_000)
        let resolver = Self.makeResolver(transport: transport)

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { try await resolver.accountReference(for: "id/alice") }
            }
            var collected: [String] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }
        #expect(results.allSatisfy { $0 == Self.alice })
        // One resolve pipeline ran: exactly one history request total (the first server
        // answered, so no fallback either).
        #expect(transport.historyRequestCount == 1)
    }

    @Test func simpleNostrStringFormResolvesForRootOnly() async throws {
        let transport = ScriptedElectrumXTransport()
        transport.scriptValue(#"{"nostr":"\#(Self.alice)"}"#, forName: "d/example", tipHeight: 1_000_000)
        let resolver = Self.makeResolver(transport: transport)
        #expect(try await resolver.accountReference(for: "example.bit") == Self.alice)
        var thrown: NamecoinResolutionError?
        do {
            _ = try await resolver.accountReference(for: "alice@example.bit")
        } catch let error as NamecoinResolutionError {
            thrown = error
        } catch {
            Issue.record("expected NamecoinResolutionError, got \(error)")
        }
        #expect(thrown == .notFound("alice@example.bit"))
    }

    // MARK: fixtures

    static let alice = String(repeating: "aa", count: 32)
    static let bob = String(repeating: "bb", count: 32)

    static let identityValue = #"{"nostr":{"pubkey":"\#(alice)","relays":["wss://relay.one"]}}"#
    static let domainValue = #"{"nostr":{"names":{"_":"\#(alice)","bob":"\#(bob)"}}}"#

    static func makeResolver(transport: ScriptedElectrumXTransport) -> NamecoinResolver {
        NamecoinResolver(
            transport: transport,
            servers: [
                NamecoinServer(host: "one.test", port: 50004, path: "", pinnedLeafKeyBase64: nil),
                NamecoinServer(host: "two.test", port: 50004, path: "", pinnedLeafKeyBase64: nil),
                NamecoinServer(host: "three.test", port: 50004, path: "", pinnedLeafKeyBase64: nil),
            ]
        )
    }
}

/// Scripted ElectrumX transport: answers the resolver's four RPC shapes per host from a
/// name→value table, synthesizing the history and verbose-transaction envelopes the real
/// servers would send. Failures are per host. No networking of any kind.
nonisolated final class ScriptedElectrumXTransport: ElectrumXTransporting, @unchecked Sendable {
    var responseDelay: Duration = .zero

    private struct ServerScript {
        var failTransport = false
        /// scripthash -> (txHash, height)
        var histories: [String: (String, Int)] = [:]
        /// txHash -> (name, value)
        var transactions: [String: (String, String)] = [:]
        var tipHeight = 0
    }

    private let lock = NSLock()
    private var scripts: [String: ServerScript] = [:]
    private(set) var historyRequestCount = 0

    /// Make every request to `host` fail at the transport layer.
    func failHost(_ host: String) {
        lock.withLock {
            var script = scripts[host] ?? ServerScript()
            script.failTransport = true
            scripts[host] = script
        }
    }

    /// Script `name` to resolve to `value` (raw name-value JSON) at `height`, on the
    /// given hosts (default: all three fixture hosts).
    func scriptValue(
        _ value: String,
        forName name: String,
        tipHeight: Int,
        height: Int = 999_000,
        onHosts hosts: [String] = ["one.test", "two.test", "three.test"]
    ) {
        let scripthash = NamecoinScript.electrumScripthash(
            NamecoinScript.buildNameIndexScript(name: Array(name.utf8))
        )
        // Unique per scripted name (the scripthash doubles as the tx id): a shared
        // constant would let a later scriptValue overwrite an earlier name's transaction.
        let txHash = scripthash
        lock.withLock {
            for host in hosts {
                var script = scripts[host] ?? ServerScript()
                script.histories[scripthash] = (txHash, height)
                script.transactions[txHash] = (name, value)
                script.tipHeight = tipHeight
                scripts[host] = script
            }
        }
    }

    func roundTrip(to server: NamecoinServer, request: String, wantID: Int) async throws -> String {
        if responseDelay > .zero {
            try? await Task.sleep(for: responseDelay)
        }
        let scripted = lock.withLock { () -> ServerScript? in
            if wantID == 2 { historyRequestCount += 1 }
            return scripts[server.host]
        }
        // An unscripted host is a live server with no data (answers RPCs with empty
        // results); only an explicitly failed host is unreachable.
        if let scripted, scripted.failTransport {
            throw ElectrumXTransportError.connectionFailed
        }
        let script = scripted ?? ServerScript()
        switch wantID {
        case 1:
            return #"{"jsonrpc":"2.0","id":1,"result":["scripted","1.4"]}"#
        case 2:
            let scripthash = Self.firstRequestParam(request)
            guard let (txHash, height) = script.histories[scripthash] else {
                return #"{"jsonrpc":"2.0","id":2,"result":[]}"#
            }
            return #"{"jsonrpc":"2.0","id":2,"result":[{"tx_hash":"\#(txHash)","height":\#(height)}]}"#
        case 3:
            let txHash = Self.firstRequestParam(request)
            guard let (name, value) = script.transactions[txHash] else {
                return #"{"jsonrpc":"2.0","id":3,"result":{}}"#
            }
            let hex = Self.hexString(nameUpdateScript(name: name, value: value))
            return #"{"jsonrpc":"2.0","id":3,"result":{"vout":[{"scriptPubKey":{"hex":"\#(hex)"}}]}}"#
        case 4:
            return #"{"jsonrpc":"2.0","id":4,"result":{"height":\#(script.tipHeight)}}"#
        default:
            throw ElectrumXTransportError.connectionFailed
        }
    }

    /// Pull the first string param out of `"params":["<x>"...]` — the scripthash or tx
    /// hash the resolver asked about.
    private static func firstRequestParam(_ request: String) -> String {
        guard let paramsStart = request.range(of: #""params":[""#),
            let quoteEnd = request[paramsStart.upperBound...].firstIndex(of: "\"")
        else { return "" }
        return String(request[paramsStart.upperBound..<quoteEnd])
    }
}

// MARK: - shared script-building helpers

extension NamecoinTests {
    static let alice = String(repeating: "aa", count: 32)
    static let bob = String(repeating: "bb", count: 32)

    /// OP_NAME_UPDATE <push name> <push value> OP_2DROP OP_DROP OP_RETURN, as bytes.
    static func nameUpdateScriptHexDecoded(name: String, value: String) -> [UInt8] {
        nameUpdateScript(name: name, value: value)
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension ScriptedElectrumXTransport {
    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// OP_NAME_UPDATE <push name> <push value> OP_2DROP OP_DROP OP_RETURN — the vout shape a
/// verbose transaction carries for a name update.
private func nameUpdateScript(name: String, value: String) -> [UInt8] {
    var script: [UInt8] = [0x53]
    appendPush(&script, Array(name.utf8))
    appendPush(&script, Array(value.utf8))
    script.append(contentsOf: [0x6D, 0x75, 0x6A])
    return script
}

/// Full push-data encoding (direct / PUSHDATA1 / PUSHDATA2 / PUSHDATA4): value JSON is
/// longer than 75 bytes, and a direct-length opcode there is a malformed push.
private func appendPush(_ script: inout [UInt8], _ data: [UInt8]) {
    let count = data.count
    switch count {
    case ..<0x4C:
        script.append(UInt8(count))
    case ...0xFF:
        script.append(contentsOf: [0x4C, UInt8(count)])
    case ...0xFFFF:
        script.append(contentsOf: [0x4D, UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF)])
    default:
        script.append(contentsOf: [
            0x4E,
            UInt8(count & 0xFF),
            UInt8((count >> 8) & 0xFF),
            UInt8((count >> 16) & 0xFF),
            UInt8((count >> 24) & 0xFF),
        ])
    }
    script.append(contentsOf: data)
}

// MARK: - wire-in routing

/// The four identifier surfaces funnel through `memberRefCandidate(for:)` and gate on
/// `looksLikeMemberRef`, so these pin the routing rules at the workspace level: `.bit`
/// goes to Namecoin (never DNS, even when it is a syntactically valid NIP-05), other
/// `@` addresses keep the NIP-05 HTTP path, and bare `.bit` names count as member refs
/// so resolution triggers at all.
struct NamecoinRoutingTests {
    @MainActor
    @Test func bitIdentifiersGateAsMemberRefs() {
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        #expect(state.looksLikeMemberRef("example.bit"))
        #expect(state.looksLikeMemberRef("alice@example.bit"))
        #expect(state.looksLikeMemberRef("d/example"))
        #expect(state.looksLikeMemberRef("id/alice"))
        #expect(!state.looksLikeMemberRef("example.com"))
        #expect(!state.looksLikeMemberRef(""))
    }

    @MainActor
    @Test func memberRefCandidateRoutesBitToNamecoin() async throws {
        let namecoin = RecordingNamecoinResolver(accountReferences: [
            "example.bit": String(repeating: "aa", count: 32),
            "alice@example.bit": String(repeating: "bb", count: 32),
            "d/example": String(repeating: "cc", count: 32),
            "id/alice": String(repeating: "dd", count: 32),
            // The production resolver strips a leading nostr: internally; the stub keys
            // the raw query instead.
            "nostr:example.bit": String(repeating: "aa", count: 32),
        ])
        let nip05 = RecordingNIP05Resolver(accountReferences: [:])
        let state = WorkspaceState(
            nip05Resolver: nip05,
            namecoinResolver: namecoin,
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )

        // Every .bit / d/ / id/ shape routes to Namecoin…
        #expect(try await state.memberRefCandidate(for: "example.bit") == String(repeating: "aa", count: 32))
        // …including user@domain.bit, which is a syntactically valid NIP-05 identifier
        // but must never hit DNS.
        #expect(try await state.memberRefCandidate(for: "alice@example.bit") == String(repeating: "bb", count: 32))
        #expect(try await state.memberRefCandidate(for: "d/example") == String(repeating: "cc", count: 32))
        #expect(try await state.memberRefCandidate(for: "id/alice") == String(repeating: "dd", count: 32))
        // A nostr:-prefixed .bit name still resolves (upstream nc_is_bit strips it).
        #expect(try await state.memberRefCandidate(for: "nostr:example.bit") == String(repeating: "aa", count: 32))
        #expect(nip05.requestedIdentifiers.isEmpty)
    }

    @MainActor
    @Test func memberRefCandidateKeepsNonBitOnExistingPaths() async throws {
        let namecoin = RecordingNamecoinResolver(accountReferences: [:])
        let nip05 = RecordingNIP05Resolver(accountReferences: [
            "alice@example.com": String(repeating: "ee", count: 32)
        ])
        let state = WorkspaceState(
            nip05Resolver: nip05,
            namecoinResolver: namecoin,
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )

        // DNS NIP-05 keeps the HTTP verifier.
        #expect(try await state.memberRefCandidate(for: "alice@example.com") == String(repeating: "ee", count: 32))
        // Hex pubkeys and nostr references pass through untouched.
        let hex = String(repeating: "ff", count: 32)
        #expect(try await state.memberRefCandidate(for: hex) == hex)
        let nostrRef = "nostr:npub1w90qcnzy9pxxaanl7zt50pgn8gj9tnpwd3wkfnq8fj0h4pft2eus5at3v3"
        #expect(try await state.memberRefCandidate(for: nostrRef) == nostrRef)
        #expect(namecoin.requestedIdentifiers.isEmpty)
    }

    @MainActor
    @Test func namecoinFailureSurfacesNamecoinWording() async {
        // A definitive .bit miss must not masquerade as a malformed npub: the new-chat
        // error line carries the Namecoin message naming the identifier.
        let namecoin = RecordingNamecoinResolver(accountReferences: [:])
        let state = WorkspaceState(
            nip05Resolver: RecordingNIP05Resolver(accountReferences: [:]),
            namecoinResolver: namecoin,
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.client = FakeMarmotRuntime(accounts: [])
        state.newChatQuery = "missing.bit"
        let recipient = await state.resolveNewChatQuery()
        #expect(recipient == nil)
        #expect(
            state.lastError
                == String(
                    format: L10n.string("Couldn't resolve %@ on Namecoin. Double-check it and try again."),
                    "missing.bit"
                )
        )
    }
}
