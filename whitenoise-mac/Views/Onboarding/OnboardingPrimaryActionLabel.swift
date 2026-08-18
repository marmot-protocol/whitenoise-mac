//
//  OnboardingPrimaryActionLabel.swift
//  whitenoise-mac
//
//  A button label that swaps to a spinner without the button changing size.
//

import SwiftUI

/// The label inside an onboarding action button: a title that cross-fades to a spinner while
/// the action runs.
///
/// Ported from the prototype's `OnboardingPrimaryActionLabel`. The title stays in the layout at
/// zero opacity rather than being removed, which is the point of the component — a `Button`
/// whose label is replaced outright resizes to the spinner mid-press, and a full-width capsule
/// collapsing to 30pt is a much louder event than the spinner it was trying to show.
///
/// It deliberately sets no foreground color. On the phone the prototype hard-codes black or
/// white against the tint; here the native glass styles own their label color and adapt it to
/// the accent, contrast setting and appearance — the same reason the rest of this app's
/// primary buttons leave it alone.
struct OnboardingPrimaryActionLabel: View {
    let title: String
    var isLoading = false

    var body: some View {
        ZStack {
            Text(title)
                .opacity(isLoading ? 0 : 1)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: isLoading)
        .accessibilityLabel(title)
    }
}

#Preview {
    VStack(spacing: 16) {
        OnboardingPrimaryActionLabel(title: "Sign In")
        OnboardingPrimaryActionLabel(title: "Sign In", isLoading: true)
    }
    .padding(40)
}
