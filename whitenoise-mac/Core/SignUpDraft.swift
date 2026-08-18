//
//  SignUpDraft.swift
//  whitenoise-mac
//
//  The profile the sign-up screen collects before the identity exists.
//

import Foundation

/// Name and bio typed on the sign-up screen, before there is an account to publish them to.
///
/// The iOS prototype's `SignUpView` gathers the same two fields (plus a photo, which needs an
/// account here — see `SignUpScreen`) and hands them back on completion. This is that payload
/// as a pure value, so the "is there anything worth publishing?" question can be asserted
/// without a runtime.
///
/// Both fields are optional by design. Creating an identity requires nothing, and the prototype
/// never blocks its Sign Up button on the form either — so a user who wants a pseudonymous,
/// metadata-free account gets one by pressing straight through. `hasPublishableProfile` is what
/// keeps that case from publishing an empty `kind:0` to the network.
/// Not `nonisolated`: `profileDraft` builds a `ProfileDraft`, which inherits the module's
/// MainActor default. Asserting these values still needs nothing but the main actor.
struct SignUpDraft: Equatable {
    var displayName: String
    var about: String

    init(displayName: String = "", about: String = "") {
        self.displayName = displayName
        self.about = about
    }

    var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAbout: String {
        about.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether sign-up should follow account creation with a profile publish. Whitespace-only
    /// input counts as nothing typed.
    var hasPublishableProfile: Bool {
        !trimmedDisplayName.isEmpty || !trimmedAbout.isEmpty
    }

    /// The draft the profile screen would have produced for the same input, so onboarding
    /// publishes through exactly the same shape Settings does rather than a parallel one.
    ///
    /// `name` and `displayName` are both set: Nostr `kind:0` carries the two separately, and
    /// every other White Noise client writes the single field a user typed into both rather
    /// than leaving one blank for other clients to fall back through.
    var profileDraft: ProfileDraft {
        ProfileDraft(
            name: trimmedDisplayName,
            displayName: trimmedDisplayName,
            about: trimmedAbout
        )
    }
}
