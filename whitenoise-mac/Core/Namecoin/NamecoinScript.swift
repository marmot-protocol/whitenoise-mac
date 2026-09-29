//
//  NamecoinScript.swift
//  whitenoise-mac
//
//  Namecoin OP_NAME_UPDATE script assembly and OP_NAME_* vout parsing.
//
//  ElectrumX indexes Namecoin names by the scripthash of a canonical
//  OP_NAME_UPDATE-shaped script over the name bytes; the resolver hashes
//  that here to derive the key it sends to `blockchain.scripthash.get_history`.
//  Once history comes back, the same code decodes the OP_NAME_UPDATE or
//  OP_NAME_FIRSTUPDATE vout the transaction carries and pulls the raw name
//  value JSON out. Both layouts share the name push; FIRSTUPDATE wedges a
//  20-byte HASH160 commitment between the name and the value push.
//
//  Ported from whitenoise-linux `app/namecoin_script.odin` (commit 79447095f2).
//  Script-hash derivation is computed locally on purpose: the resolver never
//  trusts the ElectrumX server for name-to-script derivation.
//

import CryptoKit
import Foundation

nonisolated enum NamecoinScript {
    // Namecoin script opcodes used by the name-index script.
    private static let opNameNew: UInt8 = 0x51
    private static let opNameFirstUpdate: UInt8 = 0x52
    private static let opNameUpdate: UInt8 = 0x53
    private static let op2Drop: UInt8 = 0x6D
    private static let opDrop: UInt8 = 0x75
    private static let opReturn: UInt8 = 0x6A
    private static let opPushData1: UInt8 = 0x4C
    private static let opPushData2: UInt8 = 0x4D
    private static let opPushData4: UInt8 = 0x4E

    /// HASH160 commitment length in an OP_NAME_FIRSTUPDATE vout, per namecore consensus rules.
    private static let firstUpdateRandLength = 20

    /// Build the OP_NAME_UPDATE name-index script for `name` bytes:
    ///   OP_NAME_UPDATE <push(name)> <push(empty)> OP_2DROP OP_DROP OP_RETURN
    static func buildNameIndexScript(name: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [opNameUpdate]
        pushData(&out, name)
        pushData(&out, [])
        out.append(contentsOf: [op2Drop, opDrop, opReturn])
        return out
    }

    private static func pushData(_ out: inout [UInt8], _ data: [UInt8]) {
        let n = data.count
        switch n {
        case ..<Int(opPushData1):
            out.append(UInt8(n))
        case ...0xFF:
            out.append(contentsOf: [opPushData1, UInt8(n)])
        case ...0xFFFF:
            out.append(contentsOf: [opPushData2, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)])
        default:
            out.append(contentsOf: [
                opPushData4,
                UInt8(n & 0xFF),
                UInt8((n >> 8) & 0xFF),
                UInt8((n >> 16) & 0xFF),
                UInt8((n >> 24) & 0xFF),
            ])
        }
        out.append(contentsOf: data)
    }

    /// ElectrumX scripthash: SHA-256 of the script, byte-reversed, lowercase hex. Every
    /// ElectrumX server keys `blockchain.scripthash.get_history` by this exact digest.
    static func electrumScripthash(_ script: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(script))
        return digest.reversed().map { String(format: "%02x", $0) }.joined()
    }

    /// Read one push from `script` at `pos`; returns the pushed bytes plus the position just
    /// past it. `nil` for a malformed / truncated push.
    private static func readPush(_ script: [UInt8], _ pos: Int) -> (data: ArraySlice<UInt8>, next: Int)? {
        guard pos < script.count else { return nil }
        let op = script[pos]
        if op == 0x00 {
            return (script[pos..<pos], pos + 1)
        }
        if op < opPushData1 {
            let length = Int(op)
            let end = pos + 1 + length
            guard end <= script.count else { return nil }
            return (script[(pos + 1)..<end], end)
        }
        if op == opPushData1 {
            guard pos + 2 <= script.count else { return nil }
            let length = Int(script[pos + 1])
            let end = pos + 2 + length
            guard end <= script.count else { return nil }
            return (script[(pos + 2)..<end], end)
        }
        if op == opPushData2 {
            guard pos + 3 <= script.count else { return nil }
            let length = Int(script[pos + 1]) | (Int(script[pos + 2]) << 8)
            let end = pos + 3 + length
            guard end <= script.count else { return nil }
            return (script[(pos + 3)..<end], end)
        }
        if op == opPushData4 {
            guard pos + 5 <= script.count else { return nil }
            let length =
                Int(script[pos + 1])
                | (Int(script[pos + 2]) << 8)
                | (Int(script[pos + 3]) << 16)
                | (Int(script[pos + 4]) << 24)
            let end = pos + 5 + length
            guard end >= 0, end <= script.count else { return nil }
            return (script[(pos + 5)..<end], end)
        }
        return nil
    }

    /// Decode one Namecoin name-op vout into its `(name, value)` pair. Accepts both
    /// value-carrying layouts:
    ///
    ///   OP_NAME_FIRSTUPDATE <name> <rand> <value> OP_2DROP OP_2DROP OP_DROP <p2pkh>
    ///   OP_NAME_UPDATE      <name> <value>        OP_2DROP OP_DROP        <p2pkh>
    ///
    /// OP_NAME_NEW carries no value here; returns `nil` for it.
    static func parseNameScript(_ script: [UInt8]) -> (name: String, value: String)? {
        guard let op = script.first, op == opNameUpdate || op == opNameFirstUpdate else {
            return nil
        }
        guard let (nameBytes, afterName) = readPush(script, 1) else { return nil }
        var pos = afterName
        if op == opNameFirstUpdate {
            guard let (randBytes, afterRand) = readPush(script, pos),
                randBytes.count == firstUpdateRandLength
            else { return nil }
            pos = afterRand
        }
        guard let (valueBytes, _) = readPush(script, pos) else { return nil }
        return (String(decoding: nameBytes, as: UTF8.self), String(decoding: valueBytes, as: UTF8.self))
    }

    /// Decode one lowercase hex string into bytes; `nil` on any malformed nibble.
    static func hexDecode(_ string: String) -> [UInt8]? {
        let bytes = Array(string.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let hi = hexNibble(bytes[index]), let lo = hexNibble(bytes[index + 1]) else {
                return nil
            }
            out.append(UInt8(hi << 4 | lo))
            index += 2
        }
        return out
    }

    private static func hexNibble(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
        default: nil
        }
    }

    /// Walk `vouts` (each a hex-encoded scriptPubKey) and return the raw name value string
    /// for the vout that carries `name`. Empty string when no vout matches.
    static func extractNameValue(fromVoutHexes vouts: [String], name: String) -> String {
        for hexScript in vouts {
            // Cheap front-door: only 0x52 / 0x53 opcodes carry a value.
            guard hexScript.count >= 2,
                hexScript.hasPrefix("52") || hexScript.hasPrefix("53"),
                let bytes = hexDecode(hexScript),
                let parsed = parseNameScript(bytes),
                parsed.name == name
            else { continue }
            return parsed.value
        }
        return ""
    }
}
