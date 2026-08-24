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

    /// The line under the field: this draft's own complaint, or the core's from the last attempt.
    ///
    /// The core's complaint is shown only under an `.empty` draft, and that is the part worth
    /// keeping. `login()` scrubs the field on every exit path, failures included (#32), so the
    /// field is always empty at the instant `lastError` lands — which makes anything in it
    /// afterwards a fresh identity the core was never complaining about. Showing `lastError`
    /// regardless left the previous attempt's error sitting under the well-formed key the user
    /// had just pasted to replace it, until the next submit finally cleared it.
    ///
    /// Associating the error with the identity that produced it, rather than clearing it on every
    /// edit, is also what keeps the scrub from eating it: the scrub *is* an edit, and it runs
    /// after the `catch` that sets `lastError`.
    func message(lastError: String?) -> String? {
        switch self {
        case .empty:
            return lastError
        case .invalid:
            return L10n.string("Invalid nsec or npub. Make sure you entered it correctly.")
        case .valid:
            return nil
        }
    }
}
