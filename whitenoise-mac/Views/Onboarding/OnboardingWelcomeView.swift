//
//  OnboardingWelcomeView.swift
//  whitenoise-mac
//
//  The first thing a new install shows: the mark, and the two ways in.
//

import SwiftUI

/// The onboarding landing pane.
///
/// `wn-ios-prototype`'s `WelcomeView` and Flutter's `WnAuthButtonsContainer` agree on the
/// ordering, and it is the opposite of what this pane used to do: **the lesser action sits on
/// top and the primary one sits at the bottom**, closest to the edge the hand or the pointer
/// arrives from. This pane previously led with `Create New Identity` and put logging in
/// underneath it as a `.plain` button — which is to say as a link, a third tier below both push
/// buttons, for one of the two things this screen exists to do.
///
/// Both actions are now push buttons, one tier apart: the raised `WNElevatedButtonStyle` for
/// signing in, and the glass primary for signing up.
///
/// The copy is the prototype's, two words each. `Log in with Key` and `Create New Identity` were
/// more precise and were also the two longest strings on the pane — and neither precision was
/// load-bearing, because the pane behind each button says the same thing at more length: the
/// sign-in pane is titled `Private Key` and the field under it takes nothing else. In German
/// `Neue Identität erstellen` is 24 characters inside a 360pt column, which is a button that reads
/// as a sentence. `Sign Up` is the string the other clients use for the same action —
/// Flutter's `WnAuthButtonsContainer` calls `l10n.signUp` — so all nine translations came from
/// there rather than being invented here.
struct OnboardingWelcomeView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isCreating: Bool {
        workspace.authenticationActivity == .signUp
    }

    var body: some View {
        OnboardingScaffold {
            OnboardingMessageLine(message: workspace.lastError)
        } actions: {
            OnboardingActionButton(
                title: L10n.string("Sign In"),
                tier: .elevated
            ) {
                workspace.showLogin()
            }
            .disabled(workspace.isAuthenticating)
            .accessibilityIdentifier("onboarding.log-in")

            OnboardingActionButton(
                title: L10n.string(isCreating ? "Creating..." : "Sign Up"),
                tier: .primary,
                isLoading: isCreating
            ) {
                Task { await workspace.signUp() }
            }
            .disabled(workspace.isAuthenticating)
            .accessibilityIdentifier("onboarding.create-identity")
        }
        // Both set on the pane, not on either button: the shape and the padding the two tiers draw
        // come out of the environment, so a pair that read either separately could disagree. See
        // `WNButtonMetrics`.
        .controlSize(.large)
        .wnButtonShape(.capsule)
    }
}
