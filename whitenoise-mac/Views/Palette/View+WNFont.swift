//
//  View+WNFont.swift
//  whitenoise-mac
//
//  How the type ramp is applied. Prefer `.wnFont(.semiBold14)` over reaching for
//  `.font(...)` directly: the rung is the ramp's vocabulary, and a call site that
//  names a size instead is one the ladder can no longer move.
//

import SwiftUI

extension View {
    /// Applies a rung of the type ramp — the system face at that rung's size and weight.
    func wnFont(_ style: WNTextStyle) -> some View {
        font(style.font)
    }
}

extension Text {
    /// `Text`-scoped twin of `View.wnFont(_:)`, for runs that are styled before being
    /// composed into a larger string, where the modifier has to stay on `Text`.
    func wnFont(_ style: WNTextStyle) -> Text {
        font(style.font)
    }
}
