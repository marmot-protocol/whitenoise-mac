//
//  OnboardingView.swift
//  whitenoise-mac
//
//  Which onboarding pane is showing.
//

import SwiftUI

/// The onboarding surface: the landing pane, or the sign-in pane.
///
/// The two panes were one view before this — a single stack that grew a key field and a
/// `Cancel`/`Log in` row underneath its buttons once `authenticationMode` flipped, so both states
/// were on screen at once and the pane's height changed under the pointer. They are two panes
/// now, and this is the only thing that knows there are two.
///
/// The crossfade rather than a slide: nothing has navigated: the mark stays put and the column
/// under it is replaced, which is what actually happened.
struct OnboardingView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Group {
            switch workspace.authenticationMode {
            case .landing:
                OnboardingWelcomeView()
            case .login:
                OnboardingSignInView()
            }
        }
        .animation(.smooth(duration: 0.2), value: workspace.authenticationMode)
    }
}
