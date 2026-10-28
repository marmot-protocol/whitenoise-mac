//
//  LoginIdentityDraft.swift
//  whitenoise-mac
//
//  What the sign-in field makes of what has been typed into it, as a value the
//  view reads rather than logic the view holds.
//

import Foundation

/// The state of a half-typed login identity.
///
/// `whitenoise-ios` decides this with a prefix check on `nsec`, and so does this: the field signs
/// in with a private key and nothing else. The core would also take an `npub1…` — it tracks a
/// public key without being able to sign with it — but an account that cannot send a message is
/// not something the sign-in pane offers, and its hint says the key "starts with nsec".
///
/// The value lives out here, rather than inline in the view, so the rule can be asserted and so
/// `login()` can refuse anything the field would not have submitted.
enum LoginIdentityDraft: Equatable {
    /// Nothing typed yet. The pane shows no complaint — an empty field is not a wrong one.
    case empty
    /// Typed, and not a private key: anything that does not start `nsec1`, an `npub1…` included.
    case invalid
    /// Ready to submit.
    case valid

    /// The bech32 human-readable part of a private key.
    static let acceptedPrefix = "nsec1"

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            self = .empty
            return
        }

        // Case-folded because bech32 is defined over a single case and a paste out of another
        // client can arrive upper-cased. The core normalizes; the field should not disagree with
        // it about what it is looking at.
        let lowered = trimmed.lowercased()
        self = lowered.hasPrefix(Self.acceptedPrefix) ? .valid : .invalid
    }

    /// Whether the pane's primary action can fire.
    var isSubmittable: Bool { self == .valid }

    /// Whether the line under the field should still carry what the core said about the last
    /// attempt.
    ///
    /// Only the empty draft does. `login()` scrubs the field on every exit path, failures
    /// included (see issue #32), so an emptied field is what a failed attempt leaves behind and
    /// is the only draft that complaint is still about. `lastError` itself survives until the
    /// *next* attempt starts, so without this a key pasted in to replace the one that failed
    /// would be shown the previous key's error.
    var showsLastAttemptError: Bool { self == .empty }
}
