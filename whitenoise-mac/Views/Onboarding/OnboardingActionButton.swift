//
//  OnboardingActionButton.swift
//  whitenoise-mac
//
//  One onboarding push button, tier and all, so a caller cannot pair the wrong
//  style with the wrong label height.
//

import SwiftUI

/// Which of the two tiers an onboarding action is.
///
/// A named tier rather than a `ButtonStyle` passed in, because the style is only half of what a
/// tier is: the other half is how much height its label has to claim for the button to come out
/// `OnboardingLayout.actionHeight` tall, and the two numbers differ per style. Keeping them
/// together is what makes a stacked pair the same height.
enum OnboardingActionTier {
    /// The glass primary. One per pane.
    case primary
    /// The raised secondary — `WNElevatedButtonStyle`. Shadowed, not ringed.
    case elevated
}

/// A full-width onboarding push button.
///
/// The reusable piece the onboarding panes are actually built from, and the reason there is a
/// component here at all rather than a `Button` per call site: the tier decides *both* the style
/// and the label's minimum height, and a call site that picked the style itself would be one
/// `.frame` away from a pane whose two buttons are 4pt apart. See `OnboardingLayout.actionHeight`.
struct OnboardingActionButton: View {
    /// Already resolved by the caller, in-flight wording included — `Creating...` rather than
    /// `Sign Up` while the identity is being made.
    let title: String
    var tier: OnboardingActionTier = .primary
    var isLoading = false
    let action: () -> Void

    var body: some View {
        switch tier {
        case .primary:
            Button(action: action) { label }
                .wnPrimaryButtonStyle()
        case .elevated:
            Button(action: action) { label }
                .buttonStyle(.wnElevated)
        }
    }

    private var label: some View {
        OnboardingActionLabel(title: title, isLoading: isLoading)
            .frame(minHeight: OnboardingLayout.actionLabelHeight(for: tier))
    }
}
