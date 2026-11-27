//
//  View+WNFont.swift
//  whitenoise-mac
//
//  Applies rungs of the legacy fixed `WNTextStyle` ladder. New and refreshed views
//  should use Apple's native semantic `Font` text styles (`.body`, `.headline`,
//  `.subheadline`, `.caption`, `.title3`, `.callout`) directly rather than adding
//  to the legacy ladder.
//

import SwiftUI

extension View {
    /// Applies a rung of the legacy fixed type ramp — retained until callers migrate to
    /// Apple's native semantic `Font` text styles.
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
