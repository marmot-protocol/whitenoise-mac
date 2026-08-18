//
//  SignInIdentityValidation.swift
//  whitenoise-mac
//
//  What the sign-in screen knows about the key it is being handed, kept apart
//  from the view so the three states can be asserted without standing one up.
//

import Foundation

/// Whether what has been typed into the sign-in field can be submitted.
///
/// The iOS prototype's `LoginView` carries the same three-state idea (`empty` / `invalid` /
/// `valid`): the field is only ever *wrong* once something has been typed, so an untouched
/// screen shows the hint rather than an error.
nonisolated enum SignInIdentityState: Equatable {
    /// Nothing typed yet. Neither an error nor submittable — the field shows its hint.
    case empty
    /// Typed, but not a key this app can log in with.
    case invalid
    /// Submittable.
    case valid

    var canSubmit: Bool { self == .valid }

    /// Whether the field should render its error affordance. Deliberately false for `empty`:
    /// an untouched form must not accuse the user of anything.
    var showsError: Bool { self == .invalid }
}

/// Client-side triage of the identity typed into the sign-in field.
///
/// This is a *shape* check, not a bech32 checksum: it exists to keep the primary action
/// disabled on obvious paste mistakes and to explain what the field wants, and the core
/// remains the authority on whether a key is real. Anything it lets through still fails
/// through `WorkspaceState.login()` and surfaces as `lastError`.
///
/// **Both `nsec1…` and `npub1…` are valid here, and that is not an oversight.** MDK's
/// `login(identity:)` (`crates/marmot-uniffi/src/commands/account.rs`) branches on
/// `is_nostr_secret` and treats a non-`nsec` identity as a public key to track without local
/// signing. Narrowing this to `nsec` alone — which the phone prototype does, having no such
/// path — would silently remove an account type the mac app already supports.
nonisolated enum SignInIdentityValidation {
    /// The full bech32 human-readable part *and* its `1` separator, compared case-insensitively.
    ///
    /// Five characters rather than the four MDK's `is_nostr_secret` looks at, and deliberately
    /// so: every real key begins `nsec1` / `npub1`, so nothing that could have succeeded is
    /// turned away, while `nsec` typed on its own — which the core would accept as a secret and
    /// then fail to parse — is caught here, next to the hint that asked for `nsec1`.
    private static let acceptedPrefixes: Set<String> = ["nsec1", "npub1"]

    /// The value actually handed to `login(identity:)` — surrounding whitespace is what a
    /// paste from a password manager or a chat message brings with it.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func state(for raw: String) -> SignInIdentityState {
        let normalized = normalized(raw)
        guard !normalized.isEmpty else { return .empty }
        return acceptedPrefixes.contains(normalized.prefix(5).lowercased()) ? .valid : .invalid
    }
}
