//
//  OnboardingView.swift
//  whitenoise-mac
//
//  Which onboarding pane is showing.
//

import SwiftUI

/// The onboarding surface: the landing pane, the sign-in pane, or the sign-up pane.
///
/// The two panes were one view before this — a single stack that grew a key field and a
/// `Cancel`/`Log in` row underneath its buttons once `authenticationMode` flipped, so both states
/// were on screen at once and the pane's height changed under the pointer. They are two panes
/// now, and this is the only thing that knows there are two.
///
/// The crossfade rather than a slide: nothing has navigated: the header row and the two `Spacer`s
/// stay put and the column between them is replaced, which is what actually happened. The sign-up
/// pane swaps the hero out too — the avatar being created stands where the mark stands — which is
/// the only thing any pane is allowed to change about the scaffold. See `OnboardingScaffold`.
struct OnboardingView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Group {
            switch workspace.authenticationMode {
            case .landing:
                OnboardingWelcomeView()
            case .login:
                OnboardingSignInView()
            case .signUp:
                OnboardingSignUpView()
            }
        }
        .animation(.smooth(duration: 0.2), value: workspace.authenticationMode)
    }
}
