//
//  SignInScreen.swift
//  whitenoise-mac
//
//  Signing in with a key that already exists.
//

import SwiftUI

/// The sign-in screen: a labelled key field, one footnote, and the action at the bottom.
///
/// Ported from the prototype's `LoginView`. What carries over is the shape — the section label
/// above the capsule, the hint that becomes the error in the same slot, and a primary action
/// pinned to the bottom that is disabled until the field could plausibly succeed. The
/// prototype's QR-scanner accessory does not: it opens the phone camera, and the mac app has no
/// equivalent capture path here.
///
/// The field is not disabled while signing in — it is the *action* that is gated, through
/// `isAuthenticating`. Disabling the field would blank its focus ring and make a two-second
/// relay round-trip look like the form had been taken away.
struct SignInScreen: View {
    @Environment(WorkspaceState.self) private var workspace

    private var identityState: SignInIdentityState {
        SignInIdentityValidation.state(for: workspace.loginIdentity)
    }

    var body: some View {
        @Bindable var workspace = workspace

        OnboardingScaffold {
            VStack(alignment: .leading, spacing: OnboardingMetrics.stackSpacing) {
                Text(L10n.string("Private Key"))
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.backgroundContentPrimary)

                SignInIdentityField(
                    identity: $workspace.loginIdentity,
                    isEnabled: !workspace.isAuthenticating,
                    onSubmit: signIn
                )

                OnboardingFieldFootnote(
                    text: identityState.showsError
                        ? L10n.string("That key isn't valid. Check it and try again.")
                        : L10n.string("It starts with nsec1."),
                    intent: identityState.showsError ? .error : .hint
                )
            }
        } actions: {
            VStack(spacing: 12) {
                OnboardingActionButton(
                    title: L10n.string("Sign In"),
                    isLoading: workspace.authenticationActivity == .login,
                    action: signIn
                )
                .disabled(!identityState.canSubmit || workspace.isAuthenticating)
                .accessibilityIdentifier("onboarding.sign-in.submit")

                OnboardingErrorMessage(message: workspace.lastError)
            }
        }
        .onboardingTitleBar(
            title: L10n.string("Sign In"),
            isBackEnabled: !workspace.isAuthenticating
        ) {
            workspace.returnToOnboardingLanding()
        }
    }

    private func signIn() {
        guard identityState.canSubmit, !workspace.isAuthenticating else { return }
        Task { await workspace.login() }
    }
}
