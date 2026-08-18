//
//  OnboardingFieldFootnote.swift
//  whitenoise-mac
//
//  The line under an onboarding field: what it wants, or what is wrong with it.
//

import SwiftUI

/// The single line beneath an onboarding field.
///
/// One component with two intents rather than two views, because the prototype's sign-in screen
/// puts the hint and the error in *the same slot* — the footnote turns red and changes wording,
/// the layout does not move. Rendering them as separate conditional views is what makes a form
/// jump by a line the moment a paste goes wrong.
struct OnboardingFieldFootnote: View {
    /// Which of the two things the line is saying.
    enum Intent {
        /// What the field expects, before anything is wrong.
        case hint
        /// What is wrong with what was typed.
        case error
    }

    let text: String
    var intent: Intent = .hint

    var body: some View {
        Text(text)
            .wnFont(.medium12)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.15), value: intent == .error)
    }

    private var color: Color {
        switch intent {
        case .hint: WNColor.backgroundContentSecondary
        case .error: WNColor.backgroundContentDestructive
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        OnboardingFieldFootnote(text: "It starts with nsec1.")
        OnboardingFieldFootnote(text: "That key isn't valid. Check it and try again.", intent: .error)
    }
    .frame(width: OnboardingMetrics.formColumnWidth)
    .padding(40)
}
