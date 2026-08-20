//
//  WNNSFont.swift
//  whitenoise-mac
//
//  The AppKit face of the type ramp — the `NSFont` twin of `WNTextStyle`, so the
//  TextKit-backed composer is set at the same rung, in the same face, as the
//  SwiftUI views around it. Same relationship `WNNSColor` has to `WNColor`: one
//  set of values, two frameworks.
//
//  Both twins ask the framework for the system face by weight rather than for a
//  face by name. That is the supported route — CoreText answers a name lookup for
//  a system font with a warning and a substitute — and it is what keeps the two
//  sides in step: they read the same `WNFontWeight` and neither can resolve to a
//  face the other cannot.
//

import AppKit

nonisolated enum WNNSFont {
    /// The system face at a rung's size and weight.
    static func font(for style: WNTextStyle) -> NSFont {
        style.usesMonospacedDigits
            ? .monospacedDigitSystemFont(ofSize: style.size, weight: style.weight.appKit)
            : .systemFont(ofSize: style.size, weight: style.weight.appKit)
    }

    /// A rung as a `TextKit` attribute dictionary, ready to drop into text storage.
    static func attributes(for style: WNTextStyle) -> [NSAttributedString.Key: Any] {
        [.font: font(for: style)]
    }
}
