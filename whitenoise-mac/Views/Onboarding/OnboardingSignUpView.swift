//
//  OnboardingSignUpView.swift
//  whitenoise-mac
//
//  The third onboarding pane: who you are, before there is anyone to be.
//

import SwiftUI

/// The sign-up pane: a face, a name, a line about yourself, and one button that makes all three
/// real.
///
/// This is `wn-ios-prototype`'s `SignUpView` and `whitenoise`'s `SignupScreen`, which are the same
/// screen twice: an avatar you can tap to change, a name field, an about field, and a single CTA
/// pinned below them. It replaces a landing-pane button that created an identity outright, in the
/// time it took to press it, and dropped you into an empty chat list under a hex id — a profile
/// nobody found until they went looking for Settings → Profile.
///
/// What the port changes, and why:
///
/// * **No pre-filled name.** Both phone clients seed the field — the prototype with `Marmota`,
///   Flutter with a random `adjective animal` from `UniqueNamesGenerator`. That generator's word
///   lists are English-only, so in the nine languages this app ships it would put an English
///   pseudonym into a field the user is about to publish under. An empty field with
///   `Enter your name` in it asks the same question without answering it in the wrong language.
/// * **The photo picker is the app's own.** `ProfileImagePickerSheet` — a file import plus an
///   Openverse search — rather than the prototype's Photos/Files/Web menu, which is a phone's
///   three sources. It is the same sheet Settings → Profile opens, pointed at the draft instead
///   of at an account; see `WorkspaceState.ProfileImagePickerDestination`.
/// * **The privacy line is a hover, not a callout.** Flutter puts a tap-to-expand `WnCallout`
///   here. A collapsible box costs this pane 60pt of a 620pt window, and a pointer has a cheaper
///   way to ask: the headline stays, the sentence behind it is the tooltip.
///
/// The one thing kept exactly is the bar for submitting — a non-blank name, which is Flutter's
/// `hasName` on `signup_create_profile_button`. Nothing else is required, and nothing is created
/// until the button is pressed; see `WorkspaceState.completeSignUp()`.
struct OnboardingSignUpView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isCreating: Bool {
        workspace.authenticationActivity == .signUp
    }

    private var isBusy: Bool {
        workspace.isAuthenticating || workspace.isUploadingProfileImage
    }

    var body: some View {
        @Bindable var workspace = workspace

        OnboardingScaffold(title: L10n.string("Set up profile"), exit: .back(cancel)) {
            OnboardingSignUpAvatar()
        } content: {
            VStack(alignment: .leading, spacing: OnboardingLayout.titleToFieldsSpacing) {
                OnboardingPublicProfileNote()

                VStack(alignment: .leading, spacing: OnboardingLayout.fieldSpacing) {
                    OnboardingFormField(
                        label: L10n.string("Name"),
                        prompt: L10n.string("Enter your name"),
                        text: $workspace.signUpDraft.displayName,
                        isEnabled: !isBusy
                    )
                    .accessibilityIdentifier("onboarding.sign-up.name")

                    OnboardingFormField(
                        label: L10n.string("About"),
                        prompt: L10n.string("Introduce yourself"),
                        text: $workspace.signUpDraft.about,
                        lineLimit: OnboardingLayout.aboutFieldLineLimit,
                        isEnabled: !isBusy
                    )
                    .accessibilityIdentifier("onboarding.sign-up.about")
                }

                OnboardingMessageLine(message: workspace.lastError)
            }
        } actions: {
            OnboardingActionButton(
                title: L10n.string(isCreating ? "Creating..." : "Create profile"),
                tier: .primary,
                isLoading: isCreating
            ) {
                Task { await workspace.completeSignUp() }
            }
            .disabled(!workspace.signUpDraft.isSubmittable || isBusy)
            .accessibilityIdentifier("onboarding.sign-up.create")
        }
        .controlSize(.large)
        .wnButtonShape(.capsule)
        .sheet(isPresented: $workspace.isProfileImagePickerPresented) {
            ProfileImagePickerSheet()
                // Sheets are hosted outside this view's hierarchy and inherit nothing from it, so
                // the app-language locale has to be handed over again or the picker comes up in
                // the system language while the pane behind it is not.
                .environment(\.locale, workspace.preferredLocale)
        }
    }

    /// Where "back" goes depends on whether a failed attempt already minted the identity — see
    /// `WorkspaceState.cancelSignUp()`, which owns that decision.
    private func cancel() {
        Task { await workspace.cancelSignUp() }
    }
}

/// The one thing this pane has to say about publishing, above the fields it publishes.
///
/// Both strings are already in the catalog, from the `profileIsPublic` callout Settings → Profile
/// draws in full: the headline, and the sentence explaining it. Flutter puts the same pair here as
/// a tap-to-expand `WnCallout`; a collapsible box costs this pane 60pt of a 620pt window, and a
/// pointer has a cheaper way to ask for the sentence. So the headline stays on the pane and the
/// sentence is the tooltip — with the same text as the accessibility hint, since a tooltip is
/// exactly the disclosure VoiceOver cannot hover for.
private struct OnboardingPublicProfileNote: View {
    private static let detail = L10n.string(
        "Name, photo, and bio are visible on the global Nostr network. Use what you're comfortable sharing."
    )

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
            Text(L10n.string("Your profile is public"))
        }
        .wnFont(.medium12)
        .foregroundStyle(WNColor.backgroundContentSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Self.detail)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Self.detail)
    }
}
