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
/// The reservation is the point. `whitenoise-ios`'s sign-in screen swaps a hint for an error in
/// the same slot, so the field never moves; panes with no `hint` hold nothing in the slot most of
/// the time, and it would collapse — every appearance of an error would shove the button that
/// produced it downwards, out from under the pointer that just clicked it. `minHeight` keeps the
/// column still instead.
///
/// One line, not many, because there is only ever one thing to say: what the field thinks of what
/// is in it, or failing that, what the core said when the last attempt failed — or, when there is
/// no complaint, the `hint`.
struct OnboardingMessageLine: View {
    /// `nil` draws the `hint`, or the empty reserved line when there is none.
    let message: String?
    /// Shown, in the quieter hint colour, while there is no `message` to show.
    var hint: String? = nil
    /// How much height the line keeps while it is empty. Defaults to `reservedHeight`; the
    /// sign-in pane passes `singleLineReservedHeight`. See there.
    var minimumHeight: CGFloat = Self.reservedHeight

    var body: some View {
        Text(message ?? hint ?? "")
            .wnFont(.medium12)
            .foregroundStyle(
                message == nil ? WNColor.backgroundContentTertiary : WNColor.backgroundContentDestructive
            )
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.default, value: message)
            .accessibilityHidden(message == nil && hint == nil)
    }

    /// Two `medium12` lines, which is what the longest of the messages that land here wraps to at
    /// `OnboardingLayout.contentWidth`.
    static let reservedHeight: CGFloat = 32

    /// One `medium12` line. The sign-in pane reserves only this much, because there the empty slot
    /// is the whole of the air between the key field and the Sign In button it submits: two lines
    /// of nothing put the button 56pt under the field, which read as two separate things rather
    /// than a field and its button. The pane's hint fills the line when there is nothing wrong, so
    /// it is not empty air either. The trade is that a message wrapping to a second line — the
    /// German, Portuguese and Russian invalid-key copy at `OnboardingLayout.contentWidth`, or a
    /// long error from the core — grows the line and moves the button down by that one line.
    static let singleLineReservedHeight: CGFloat = 16
}
