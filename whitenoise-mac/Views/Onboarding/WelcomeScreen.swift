//
//  WelcomeScreen.swift
//  whitenoise-mac
//
//  The first screen of a signed-out app: the mark, and the two ways in.
//

import SwiftUI

/// The welcome screen.
///
/// A direct port of the prototype's `WelcomeView`: the mark centred in the space above, and two
/// stacked capsules at the bottom — Sign In first on plain glass, Sign Up beneath it on filled
/// glass. The order is the prototype's and is not accidental. Most people opening a messenger
/// on a second device already have an identity, so the returning path reads first; the
/// prominence goes to Sign Up because that is the action with consequences.
///
/// The error line is the pane's, not a button's: both actions fail into `lastError`, and a
/// failure belongs under the pair rather than shifting whichever button produced it.
struct WelcomeScreen: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        OnboardingScaffold(columnWidth: OnboardingMetrics.actionColumnWidth) {
            OnboardingBrandMark()
        } actions: {
            VStack(spacing: 12) {
                OnboardingActionButton(
                    title: L10n.string("Sign In"),
                    tier: .secondary
                ) {
                    workspace.showLogin()
                }
                .disabled(workspace.isAuthenticating)
                .accessibilityIdentifier("onboarding.sign-in")

                OnboardingActionButton(title: L10n.string("Sign Up")) {
                    workspace.showSignUp()
                }
                .disabled(workspace.isAuthenticating)
                .accessibilityIdentifier("onboarding.sign-up")

                OnboardingErrorMessage(message: workspace.lastError)
            }
        }
    }
}
