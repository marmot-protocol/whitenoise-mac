//
//  AccountWipeConfirmation.swift
//  whitenoise-mac
//
//  The type-to-confirm gate in front of wiping an account off this Mac: which phrase the
//  reader is asked for, and when what they typed counts as a match.
//

import Foundation

/// The gate in front of the irreversible half of the sign-out sheet.
///
/// Signing out and wiping share one button, so the *only* thing standing between a reader who
/// wanted to sign out and a permanent removal is this challenge. Pure so both halves — which
/// phrase is asked for, and what matches it — are assertable without a sheet.
nonisolated enum AccountWipeConfirmation {
    /// The phrase to ask for: the account's own name when it has one, and `fallback` when it
    /// does not.
    ///
    /// `AccountItem.displayName` is not always a name. With no profile metadata and no label,
    /// `AccountItem(summary:)` leaves it as `DisplayText.short(accountRef)` — and in exactly that
    /// case `accountRef` is the 64-character `accountIdHex`, so what the reader sees is a truncated
    /// hex id with an ellipsis in the middle. Nobody can type that, and asking for it would lock
    /// someone out of a flow they are entitled to complete.
    ///
    /// The placeholder is *derived*, so this recognises it by recomputing it rather than by
    /// guessing at hex-shaped strings — and it only counts as a placeholder when the ref was
    /// actually truncated. `DisplayText.short` returns short input unchanged, so a legitimate
    /// account label of "Pepi" equals its own "shortened" form; without that second half, every
    /// account whose label is its name and is under 18 characters would be asked for the fallback.
    ///
    /// The `fallback` is passed in rather than localized here so this stays a pure value; callers
    /// hand it `L10n.string("WIPE")`.
    static func challenge(displayName: String, accountRef: String, fallback: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let shortened = DisplayText.short(accountRef)
        let isDerivedPlaceholder = shortened != accountRef && trimmed == shortened
        return isDerivedPlaceholder ? fallback : trimmed
    }

    /// Whether `input` clears the gate.
    ///
    /// Trimmed and case-insensitive, matching the iOS client's `WipeConfirmation`. The challenge
    /// is a deliberate speed bump, not a password: someone who typed their own display name with
    /// the wrong capitalisation has demonstrated exactly the intent the gate is checking for, and
    /// rejecting it only teaches people to paste.
    static func matches(_ input: String, challenge: String) -> Bool {
        guard !challenge.isEmpty else { return false }
        return input.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(challenge) == .orderedSame
    }
}
