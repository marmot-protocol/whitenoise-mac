//
//  SignUpScreen.swift
//  whitenoise-mac
//
//  Naming a brand-new identity before creating it.
//

import SwiftUI

/// The sign-up screen: a monogram, a name, a bio, and the button that creates the identity.
///
/// Ported from the prototype's `SignUpView`, with its shape intact — the round subject above
/// two labelled fields, the primary action at the bottom.
///
/// **Neither field is required.** Creating an identity needs nothing but a keypair, and the
/// prototype never gates its Sign Up button on the form either; pressing straight through is
/// the pseudonymous path and it stays open. What the fields buy is that the profile is
/// published as part of sign-up instead of being a thing to go and find in Settings afterwards
/// — and if they are left blank, `SignUpDraft.hasPublishableProfile` is what stops an empty
/// `kind:0` going to the network.
struct SignUpScreen: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        OnboardingScaffold {
            VStack(spacing: OnboardingMetrics.sectionSpacing) {
                SignUpAvatarPreview(displayName: workspace.signUpDraft.trimmedDisplayName)

                SettingsLabeledField(label: L10n.string("Name")) {
                    TextField(
                        L10n.string("Enter your name"),
                        text: $workspace.signUpDraft.displayName
                    )
                }

                SettingsLabeledField(label: L10n.string("About"), minHeight: 76) {
                    TextField(
                        L10n.string("Introduce yourself"),
                        text: $workspace.signUpDraft.about,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                }

                OnboardingFieldFootnote(
                    text: L10n.string("Both are optional and public. You can add a photo later in Settings.")
                )
            }
            .disabled(workspace.isAuthenticating)
        } actions: {
            VStack(spacing: 12) {
                OnboardingActionButton(
                    title: L10n.string("Sign Up"),
                    isLoading: workspace.authenticationActivity == .signUp,
                    action: signUp
                )
                .disabled(workspace.isAuthenticating)
                .accessibilityIdentifier("onboarding.sign-up.submit")

                OnboardingErrorMessage(message: workspace.lastError)
            }
        }
        .onboardingTitleBar(
            title: L10n.string("Sign Up"),
            isBackEnabled: !workspace.isAuthenticating
        ) {
            workspace.returnToOnboardingLanding()
        }
    }

    private func signUp() {
        guard !workspace.isAuthenticating else { return }
        Task { await workspace.signUp() }
    }
}
