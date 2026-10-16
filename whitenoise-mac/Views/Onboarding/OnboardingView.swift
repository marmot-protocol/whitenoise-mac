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
    let model: OnboardingCoordinator?

    var body: some View {
        Group {
            if let model, Self.showsAccountSetup(model) {
                AccountSetupView(model: model)
            } else {
                switch workspace.authenticationMode {
                case .landing:
                    OnboardingWelcomeView()
                case .login:
                    OnboardingSignInView()
                case .signUp:
                    OnboardingSignUpView()
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: workspace.authenticationMode)
    }

    /// Whether the account-setup pane stands in for the sign-in panes: only for a checkpoint the
    /// user is still being walked through.
    ///
    /// Not merely "there is a checkpoint". MarmotKit keeps a ready one, and Settings → Add
    /// Account reopens onboarding with the current account's scope still active — so that test
    /// put the current account's "You’re ready to chat" where Welcome belongs, with an Open Chats
    /// that changes nothing the shell waits on and a ✕ that cancels *that* account's onboarding.
    /// A checkpoint that was ready before anyone was walked through it, or whose chats were
    /// already entered, is excluded. One that is ready and waiting on Open Chats, or on the shell
    /// after it, still shows, so its spinner is not replaced by the sign-in pane mid-transition.
    static func showsAccountSetup(_ model: OnboardingCoordinator?) -> Bool {
        guard let model, model.snapshot != nil, !model.hasEnteredChats else { return false }
        return !(model.isDurablyReady && !model.hasShownIncompleteSetup)
    }
}

#Preview {
    OnboardingView(model: nil)
        .environment(WorkspaceState.preview())
}
