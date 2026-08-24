//
//  OnboardingMessageLine.swift
//  whitenoise-mac
//
//  The one place an onboarding pane says something went wrong, and the space it
//  keeps for doing so.
//

import SwiftUI

/// A reserved line under an onboarding control, for whatever complaint that control has.
///
/// The reservation is the point. `wn-ios-prototype`'s sign-in screen swaps a hint for an error in
/// the same slot, so the field never moves; the mac pane has no persistent hint to swap out, so
/// the slot holds nothing most of the time and would collapse — and every appearance of an error
/// would shove the button that produced it downwards, out from under the pointer that just
/// clicked it. `minHeight` keeps the column still instead.
///
/// One line, not many, because there is only ever one thing to say: what the field thinks of what
/// is in it, or failing that, what the core said when the last attempt failed.
struct OnboardingMessageLine: View {
    /// `nil` draws the empty reserved line.
    let message: String?

    var body: some View {
        Text(message ?? "")
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentDestructive)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: Self.reservedHeight, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.default, value: message)
            .accessibilityHidden(message == nil)
    }

    /// Two `medium12` lines, which is what the longest of the messages that land here wraps to at
    /// `OnboardingLayout.contentWidth`.
    static let reservedHeight: CGFloat = 32
}
