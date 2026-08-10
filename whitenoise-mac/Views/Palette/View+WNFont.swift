//
//  View+WNFont.swift
//  whitenoise-mac
//
//  How the type ramp is applied. Prefer `.wnFont(.semiBold14)` over reaching for
//  `.font(...)` directly: a rung is a size *and* the tracking that size is set at,
//  and `.font()` alone would drop half of it.
//

import SwiftUI

extension View {
    /// Applies a rung of the Manrope type ramp — face, size, and the letter spacing
    /// that size is designed to be set at.
    func wnFont(_ style: WNTextStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
    }
}

extension Text {
    /// `Text`-scoped twin of `View.wnFont(_:)`, for runs that are styled before being
    /// composed into a larger string, where the modifier has to stay on `Text`.
    func wnFont(_ style: WNTextStyle) -> Text {
        font(style.font)
            .tracking(style.tracking)
    }
}
