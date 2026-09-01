//
//  OnboardingActionLabel.swift
//  whitenoise-mac
//
//  The label every onboarding push button wears: full-width, and able to show
//  that it is working without changing height.
//

import SwiftUI

/// A full-width button label that can carry a spinner.
///
/// This is `wn-ios-prototype`'s `OnboardingPrimaryActionLabel` with two deliberate differences,
/// both of which come from the label sitting on a *mac* button:
///
/// 1. **It does not name a content color.** The prototype resolves black or white off
///    `colorScheme` because its label is drawn as an `overlay` over a hidden button, so it is
///    outside the button style and inherits nothing. Here the label is the button's own, and the
///    styles it goes into — `.glassProminent` for the primary tier, `WNSecondaryButtonStyle` for
///    the raised one — already own their ink and adapt it to the appearance, the accent and the
///    contrast settings. Naming a color here would override all three.
/// 2. **The title stays visible while working**, with the spinner beside it rather than crossed
///    over it. The onboarding actions already have in-flight titles in the catalog
///    (`Creating...`, `Logging in...`), and a button that says what it is doing beats a button
///    that goes blank. It is also the shape the rest of the app's in-flight buttons take — see
///    `PendingInviteActionButtons`.
///
/// The width is `.infinity` so a stack of these fills the action column
/// (`OnboardingLayout.contentWidth`) and every button in it comes out the same width.
struct OnboardingActionLabel: View {
    /// Already resolved by the caller, in-flight wording included.
    let title: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }

            Text(title)
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: isLoading)
    }
}
