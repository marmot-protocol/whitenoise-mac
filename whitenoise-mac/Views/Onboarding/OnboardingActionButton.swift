//
//  OnboardingActionButton.swift
//  whitenoise-mac
//
//  The full-width capsule the signed-out screens act through.
//

import SwiftUI

/// A full-width capsule button, in one of the two tiers the onboarding screens use.
///
/// This is the port of the prototype's onboarding action — `controlSize(.extraLarge)` plus
/// `buttonSizing(.flexible)`, a capsule filling its column, with the primary action on
/// `.glassProminent` and its alternative on `.glass`. `buttonSizing` is macOS 26 only and the
/// deployment target here is 15.6, so the width comes from the label's own
/// `frame(maxWidth: .infinity)` instead; the effect is the same and it needs no availability
/// fork.
///
/// **Why `.glass` and not `.wnSecondary` for the secondary tier.** `WNSecondaryButtonStyle` is
/// this app's answer to `WnButton.outline` and remains the right choice for an action sitting
/// beside or beneath a primary one in a form or a sheet. These two are not that: on the
/// welcome screen "Sign In" and "Sign Up" are peers — the whole screen is those two buttons —
/// and the prototype builds them as a matched glass pair. An 8pt-radius filled outline button
/// under a capsule of glass would not read as the other half of a pair. The tier split here is
/// prominence within one hero pair, not the app-wide primary/secondary ladder.
struct OnboardingActionButton: View {
    /// Which of the two hero tiers this button draws at.
    enum Tier {
        /// The action the screen exists to perform. Liquid glass, filled.
        case primary
        /// Its peer or its alternative. Liquid glass, unfilled.
        case secondary
    }

    let title: String
    var tier: Tier = .primary
    var isLoading = false
    let action: () -> Void

    var body: some View {
        switch tier {
        case .primary:
            base.nativeGlassProminentButtonStyle()
        case .secondary:
            base.nativeGlassButtonStyle()
        }
    }

    private var base: some View {
        Button(action: action) {
            OnboardingPrimaryActionLabel(title: title, isLoading: isLoading)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.extraLarge)
        .buttonBorderShape(.capsule)
    }
}

#Preview {
    VStack(spacing: 12) {
        OnboardingActionButton(title: "Sign In", tier: .secondary) {}
        OnboardingActionButton(title: "Sign Up") {}
        OnboardingActionButton(title: "Sign Up", isLoading: true) {}
        OnboardingActionButton(title: "Sign Up") {}
            .disabled(true)
    }
    .frame(width: OnboardingMetrics.actionColumnWidth)
    .padding(40)
}
