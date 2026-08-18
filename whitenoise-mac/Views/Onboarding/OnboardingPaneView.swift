//
//  OnboardingPaneView.swift
//  whitenoise-mac
//
//  Which signed-out screen the detail pane is showing.
//

import SwiftUI

/// The signed-out pane: whichever onboarding screen `authenticationMode` names.
///
/// The three screens are siblings behind one switch rather than a pushed stack. On the phone
/// the prototype presents sign-in and sign-up as sheets over the welcome screen; a sheet is the
/// wrong container here — it would lose the injected `\.locale`, and the pane it would cover is
/// already the whole window.
///
/// The cross-fade is deliberately plain. A slide would imply a stack that is not there, and
/// each screen re-anchors its own bottom action — sliding two differently-sized action columns
/// past each other draws the eye to the layout rather than to the screen being entered.
struct OnboardingPaneView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Group {
            switch workspace.authenticationMode {
            case .landing:
                WelcomeScreen()
            case .login:
                SignInScreen()
            case .signUp:
                SignUpScreen()
            }
        }
        // `id` is what makes the cross-fade happen at all: a `switch` inside a `Group` swaps the
        // branch without changing the wrapper's identity, so a `transition` hung off the wrapper
        // would never fire. Changing the identity also resets each screen's focus and local
        // state, which is what the entry point wants — every arrival is a fresh form.
        .transition(.opacity)
        .id(workspace.authenticationMode)
        .animation(.smooth(duration: 0.22), value: workspace.authenticationMode)
    }
}
