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
    /// Applies a native macOS semantic text role (`WNSemanticFont`).
    func wnSemanticFont(_ style: WNSemanticFont) -> some View {
        font(style.font)
    }

    /// Applies a rung of the legacy fixed type ramp — retained until callers migrate to
    /// `wnSemanticFont(_:)` / Apple's built-in text styles.
    func wnFont(_ style: WNTextStyle) -> some View {
        font(style.font)
    }
}

extension Text {
    /// `Text`-scoped twin of `View.wnSemanticFont(_:)`.
    func wnSemanticFont(_ style: WNSemanticFont) -> Text {
        font(style.font)
    }

    /// `Text`-scoped twin of `View.wnFont(_:)`, for runs that are styled before being
    /// composed into a larger string, where the modifier has to stay on `Text`.
    func wnFont(_ style: WNTextStyle) -> Text {
        font(style.font)
    }
}
