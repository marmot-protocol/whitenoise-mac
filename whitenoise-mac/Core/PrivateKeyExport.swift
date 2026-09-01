//
//  PrivateKeyExport.swift
//  whitenoise-mac
//
//  The two ways the active account's signing key leaves this Mac as a file, and the
//  password rating shown while one of them is being set up. Pure values, so the naming,
//  the file extension and the rating are all assertable without a save panel.
//

import Foundation
import UniformTypeIdentifiers

/// Which of the two exports is being written.
///
/// `encrypted` is the one to offer first: a NIP-49 `ncryptsec1…` file is useless to whoever finds
/// it without the password, while `raw` is a plaintext `nsec1…` — the account itself, in a file.
/// Both are listed because a raw key is what a password manager and every other Nostr client
/// accept, so refusing to produce one only pushes people through the clipboard instead.
nonisolated enum PrivateKeyExportKind: Hashable, CaseIterable {
    case encrypted
    case raw

    /// What the save panel offers as a name. Unlocalized product name, localized noun phrase —
    /// the same split `SettingsVersionFooter` makes.
    var suggestedFilenameKey: String {
        switch self {
        case .encrypted: "White Noise Encrypted Private Key"
        case .raw: "White Noise Private Key"
        }
    }

    /// Plain text in both cases: bech32 is text, and naming a bespoke type would only stop other
    /// Nostr clients' importers from seeing the file.
    var contentType: UTType { .plainText }

    /// `nsec1…` and `ncryptsec1…` are single-line bech32 strings. The trailing newline is there so
    /// the file reads correctly in a terminal and round-trips through editors that add one anyway;
    /// every importer trims whitespace.
    func fileContents(forKeyMaterial keyMaterial: String) -> Data {
        Data("\(keyMaterial)\n".utf8)
    }
}

/// How much a chosen export password is worth, as the three rungs the reader is shown.
///
/// Deliberately coarse and deliberately not a security guarantee: NIP-49's scrypt work factor is
/// what actually defends the file. This exists so a one-word password does not slip through
/// looking the same as a passphrase, which is the failure a bare "passwords match" check allows.
nonisolated enum PrivateKeyExportPasswordStrength: Int, Comparable, CaseIterable {
    case low = 1
    case fair = 2
    case strong = 3

    static let scale = 3.0

    /// Length first, then variety. Length is what a scrypt-hardened file actually benefits from,
    /// so a 20-character passphrase of nothing but lowercase words rates above a 10-character
    /// scramble of four character classes.
    static func evaluate(_ password: String) -> PrivateKeyExportPasswordStrength {
        guard password.count >= 12 else { return .low }

        let hasLetters = password.contains { $0.isLetter }
        let hasDigits = password.contains { $0.isNumber }
        let hasSymbols = password.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }

        if password.count >= 16, hasLetters, hasDigits, hasSymbols { return .strong }
        return .fair
    }

    var labelKey: String {
        switch self {
        case .low: "Low"
        case .fair: "Fair"
        case .strong: "Strong"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether a password and its confirmation are ready to encrypt a file with, and what to say
/// while they are not.
///
/// Pulled out of the sheet so the enabled state of a destructive-adjacent action is a value, not
/// a chain of `&&` inside a view body.
nonisolated enum PrivateKeyExportPasswordEntry {
    /// Both fields non-empty and equal. An empty password would produce an `ncryptsec1` file
    /// anyone can open, which is worse than the raw export because it *looks* protected.
    static func isReady(password: String, confirmation: String) -> Bool {
        !password.isEmpty && password == confirmation
    }

    /// True once the reader has typed enough of the confirmation to be told it disagrees. Held
    /// back while the confirmation is empty so the first keystroke in an empty field is not met
    /// with an error.
    static func showsMismatch(password: String, confirmation: String) -> Bool {
        !confirmation.isEmpty && password != confirmation
    }
}
