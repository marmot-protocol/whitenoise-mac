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
/// `wn-ios-prototype`'s `LoginView` keeps this inline as a private `KeyState` and decides it with
/// `normalizedKey.hasPrefix("nsec")`. Ported literally that would be a **regression**, not a
/// port: this app's `login(identity:)` hands the string to the core, and the core accepts an
/// `npub1…` as well — it tracks a public key without being able to sign with it, which is how a
/// read-only account is added. A field that greys its button out for anything not starting
/// `nsec` would make that path unreachable through the UI, silently, with the button simply
/// never enabling.
///
/// So the accepted set is both bech32 human-readable prefixes, and the value lives out here
/// where that can be asserted.
enum LoginIdentityDraft: Equatable {
    /// Nothing typed yet. The pane shows no complaint — an empty field is not a wrong one.
    case empty
    /// Typed, and not a bech32 identity this app can hand to the core.
    case invalid
    /// Ready to submit.
    case valid

    /// The bech32 human-readable parts the core will take. `nsec1…` signs; `npub1…` is watched
    /// without signing.
    static let acceptedPrefixes = ["nsec1", "npub1"]

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
        self =
            Self.acceptedPrefixes.contains(where: lowered.hasPrefix)
            ? .valid
            : .invalid
    }

    /// Whether the pane's primary action can fire.
    var isSubmittable: Bool { self == .valid }
}
