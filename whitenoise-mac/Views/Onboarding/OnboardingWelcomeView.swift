//
//  OnboardingWelcomeView.swift
//  whitenoise-mac
//
//  The first thing a new install shows: the mark, and the two ways in.
//

import SwiftUI

/// The onboarding landing pane.
///
/// Not only a first launch's: this is also Settings → Add Account, which used to raise a sheet of
/// its own with a second key field and a second pair of buttons for the same two actions. The
/// prototype does not have a second one either — `AddProfileFlow` presents this pane and pushes
/// the real `LoginView` and `SignUpView` behind it. The only thing the two entrances differ by is
/// the way out; see `exit`.
///
/// `wn-ios-prototype`'s `WelcomeView` and Flutter's `WnAuthButtonsContainer` agree on the
/// ordering, and it is the opposite of what this pane used to do: **the lesser action sits on
/// top and the primary one sits at the bottom**, closest to the edge the hand or the pointer
/// arrives from. This pane previously led with `Create New Identity` and put logging in
/// underneath it as a `.plain` button — which is to say as a link, a third tier below both push
/// buttons, for one of the two things this screen exists to do.
///
/// Both actions are now push buttons, one tier apart: the raised secondary
/// (`WNSecondaryButtonStyle`) for signing in, and the glass primary for signing up.
///
/// `Sign Up` no longer creates anything. It opens `OnboardingSignUpView`, which is where the
/// identity is made — the button that minted one outright, in the time it took to press it, is
/// what left every new account sitting under a hex id with no profile. The pane behind it is the
/// prototype's `SignUpView` and Flutter's `SignupScreen`, and neither creates anything either
/// until its own button is pressed. This one therefore has no in-flight label: nothing is in
/// flight.
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

    /// Present only when this pane is not the end of the line — see
    /// `WorkspaceState.canLeaveAccountOnboarding`. Reached from Settings → Add Account there is an
    /// app behind this pane to cancel back to. On a first launch, or after the last identity was
    /// signed out or removed, there is not, and a control that returned to a blank window would be
    /// a lie.
    private var exit: OnboardingExitControl? {
        guard workspace.canLeaveAccountOnboarding else { return nil }
        return .cancel { workspace.leaveAccountOnboarding() }
    }

    var body: some View {
        OnboardingScaffold(exit: exit) {
            OnboardingMessageLine(message: workspace.lastError)
        } actions: {
            OnboardingActionButton(
                title: L10n.string("Sign In"),
                tier: .secondary
            ) {
                workspace.showLogin()
            }
            .disabled(workspace.isAuthenticating)
            .accessibilityIdentifier("onboarding.log-in")

            OnboardingActionButton(
                title: L10n.string("Sign Up"),
                tier: .primary
            ) {
                workspace.showSignUp()
            }
            .disabled(workspace.isAuthenticating)
            .accessibilityIdentifier("onboarding.create-identity")
        }
        // Both set on the pane, not on either button: the shape and the padding the two tiers draw
        // come out of the environment, so a pair that read either separately could disagree. See
        // `WNButtonMetrics`.
        .controlSize(.large)
        .wnButtonShape(OnboardingLayout.buttonShape)
    }
}
