//
//  OnboardingTitleBar.swift
//  whitenoise-mac
//
//  The back affordance and title above an onboarding form.
//

import SwiftUI

/// The top strip of an onboarding form: a back control on the leading edge and the screen's
/// name centred over it.
///
/// The prototype gets this from `NavigationStack` — its sign-in and sign-up screens are pushed,
/// so they inherit a navigation bar with a title and a Close button. Onboarding is not a stack
/// here; it is the detail pane swapping its contents, so the strip is drawn explicitly.
///
/// The title is centred in the full width while the button is overlaid on the leading edge, so
/// the title sits in the middle of the *window* rather than in the middle of the space left
/// over beside the button — which is what a plain `HStack` would give, and what makes a title
/// visibly drift when the button appears.
struct OnboardingTitleBar: View {
    let title: String
    let onBack: () -> Void
    var isBackEnabled = true

    var body: some View {
        Text(title)
            .wnFont(.semiBold16)
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .wnFont(.semiBold14)
                }
                .nativeGlassCircleButtonStyle()
                .disabled(!isBackEnabled)
                .help(L10n.string("Back"))
                .accessibilityLabel(L10n.string("Back"))
            }
            .padding(.horizontal, OnboardingMetrics.screenPadding)
            .padding(.vertical, 12)
    }
}

#Preview {
    OnboardingTitleBar(title: "Sign In", onBack: {})
        .frame(width: 520)
}
