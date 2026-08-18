//
//  OnboardingTests.swift
//  whitenoise-macTests
//
//  The pure values behind the signed-out screens: what the sign-in field will
//  accept, and what the sign-up form is worth publishing.
//

import Foundation
import Testing

@testable import whitenoise_mac

@Suite(.serialized)
struct OnboardingTests {
    // MARK: - Sign-in field

    @Test func untouchedSignInFieldIsNeitherSubmittableNorWrong() {
        // The distinction the three-state enum exists for: an empty field must not accuse the
        // user of anything, so `empty` shows the hint rather than the error even though it is
        // just as unsubmittable as `invalid`.
        for raw in ["", "   ", "\n\t "] {
            let state = SignInIdentityValidation.state(for: raw)
            #expect(state == .empty)
            #expect(!state.canSubmit)
            #expect(!state.showsError)
        }
    }

    @Test func signInAcceptsAnNsecAndAnNpub() {
        // `npub` is not an oversight. MDK's `login(identity:)` branches on `is_nostr_secret` and
        // treats anything else as a public identity to track without local signing, so narrowing
        // this to `nsec` would silently remove an account type the app already supports.
        #expect(SignInIdentityValidation.state(for: "nsec1qqqqq") == .valid)
        #expect(SignInIdentityValidation.state(for: "npub1qqqqq") == .valid)
    }

    @Test func signInAcceptsTheCaseAndWhitespaceAPasteBringsWithIt() {
        // A key pasted out of a password manager or a chat message arrives wrapped in
        // whitespace, and `is_nostr_secret` compares the prefix case-insensitively, so the
        // client-side gate must not be stricter than the core it is gating.
        #expect(SignInIdentityValidation.state(for: "  nsec1qqqqq\n") == .valid)
        #expect(SignInIdentityValidation.state(for: "NSEC1QQQQQ") == .valid)
        #expect(SignInIdentityValidation.normalized("  nsec1qqqqq\n") == "nsec1qqqqq")
    }

    @Test func signInRejectsWhatIsPlainlyNotAKey() {
        for raw in ["hello", "nse", "1nsec1qqqqq", "https://example.com", "npub"] {
            let state = SignInIdentityValidation.state(for: raw)
            #expect(state == .invalid, "\(raw) should not be submittable")
            #expect(!state.canSubmit)
            #expect(state.showsError)
        }
    }

    @Test func signInRequiresTheBech32SeparatorAndNotJustTheHumanReadablePart() {
        // MDK's own `is_nostr_secret` stops after four characters, so it would take `nsec` as a
        // secret and then fail to parse it. The gate here asks for the separator too, which
        // turns away nothing that could have succeeded and catches the one case the hint is
        // already describing.
        #expect(SignInIdentityValidation.state(for: "nsec") == .invalid)
        #expect(SignInIdentityValidation.state(for: "nsec1") == .valid)
    }

    // MARK: - Sign-up draft

    @MainActor
    @Test func blankSignUpDraftHasNothingWorthPublishing() {
        // Pressing straight through the form is the pseudonymous path and stays open. What must
        // not happen is an empty `kind:0` going to the network to say nothing about nobody.
        #expect(!SignUpDraft().hasPublishableProfile)
        #expect(!SignUpDraft(displayName: "   ", about: "\n ").hasPublishableProfile)
    }

    @MainActor
    @Test func eitherFieldOnItsOwnIsWorthPublishing() {
        #expect(SignUpDraft(displayName: "Marmota").hasPublishableProfile)
        #expect(SignUpDraft(about: "Building things.").hasPublishableProfile)
    }

    @MainActor
    @Test func signUpDraftPublishesTheTypedNameAsBothNostrNameFields() {
        // Nostr `kind:0` carries `name` and `display_name` separately, and every other White
        // Noise client writes the one name a user typed into both rather than leaving one blank
        // for other clients to fall back through.
        let draft = SignUpDraft(displayName: "  Marmota  ", about: "  Building things.  ")
        let profile = draft.profileDraft

        #expect(profile.name == "Marmota")
        #expect(profile.displayName == "Marmota")
        #expect(profile.about == "Building things.")
        #expect(profile.picture.isEmpty)
    }

    @MainActor
    @Test func signUpDraftLeavesTheRestOfTheProfileAlone() {
        // The form collects two fields; everything else on a Nostr profile has to arrive empty
        // so the publish cannot overwrite a value the user never saw with a default.
        let profile = SignUpDraft(displayName: "Marmota").profileDraft

        #expect(profile.about.isEmpty)
        #expect(profile.banner.isEmpty)
        #expect(profile.nip05.isEmpty)
        #expect(profile.lud16.isEmpty)
        #expect(profile.sanitizedPictureURL == nil)
    }
}
