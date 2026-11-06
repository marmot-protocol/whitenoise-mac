//
//  ProfileDeletionConfirmation.swift
//  whitenoise-mac
//
//  The type-to-confirm gate on the Delete Profile page, ported from `whitenoise-ios`'s
//  `ProfileExitConfirmation`.
//

import Foundation

/// When what the reader typed clears the Delete Profile page's gate.
///
/// Stricter than `AccountWipeConfirmation.matches`, which guards the sign-out sheet's wipe toggle:
/// this page is the one place whose *only* purpose is deletion, so — as on iOS — the phrase has to
/// be typed exactly. Stray spaces around an otherwise correct name do not clear it; they get a hint
/// instead (`hasExtraSurroundingWhitespace`), so the reader is told why the button stays off.
///
/// Which phrase is asked for is still `AccountWipeConfirmation.challenge`, so an account with no
/// name is asked for the fallback rather than for a truncated hex id nobody can type.
nonisolated enum ProfileDeletionConfirmation {
    static func canDelete(input: String, challenge: String, busy: Bool) -> Bool {
        !busy && !challenge.isEmpty && input == challenge
    }

    static func hasExtraSurroundingWhitespace(_ input: String, challenge: String) -> Bool {
        !challenge.isEmpty && input != challenge
            && input.trimmingCharacters(in: .whitespacesAndNewlines) == challenge
    }
}
