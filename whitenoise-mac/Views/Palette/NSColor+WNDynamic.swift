//
//  NSColor+WNDynamic.swift
//  whitenoise-mac
//
//  Light/dark pairing for the semantic palette.
//

import AppKit

extension NSColor {
    /// A single semantic token that resolves to `light` in Aqua and `dark` in
    /// Dark Aqua.
    ///
    /// The other clients express this as two `SemanticColors` constants
    /// (`.light` / `.dark`) that Flutter swaps wholesale. AppKit has no
    /// equivalent swap, so each token carries both values and lets the drawing
    /// appearance pick — which is also what makes `Color(nsColor:)` follow the
    /// window's appearance without any view having to read `\.colorScheme`.
    ///
    /// `name` is only used for archiving and debug descriptions, but it is worth
    /// setting: an unnamed dynamic color prints as `<dynamic>` in the view
    /// debugger, which makes a mis-paired token very hard to spot.
    nonisolated static func wnDynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
