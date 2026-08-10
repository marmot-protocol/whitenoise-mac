//
//  WNNSFont.swift
//  whitenoise-mac
//
//  The AppKit face of the type ramp — the `NSFont` twin of `WNTextStyle`, so the
//  TextKit-backed composer is set in the same Manrope, at the same rung, as the
//  SwiftUI views around it. Same relationship `WNNSColor` has to `WNColor`: one
//  set of values, two frameworks.
//
//  Tracking travels as the `.kern` attribute, which TextKit applies per run, so
//  `attributes(for:)` hands back the font and the kern together for the same
//  reason `View.wnFont(_:)` does: a rung applied without its tracking is not the
//  design.
//

import AppKit

nonisolated enum WNNSFont {
    /// The Manrope face for a rung, falling back to the system face at the same size
    /// and nearest weight if the bundled fonts somehow failed to register.
    static func font(for style: WNTextStyle) -> NSFont {
        let face =
            NSFont(name: style.weight.postScriptName, size: style.size)
            ?? .systemFont(ofSize: style.size, weight: systemWeight(for: style.weight))
        guard style.usesMonospacedDigits else { return face }
        let descriptor = face.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: style.size) ?? face
    }

    /// Font plus tracking for a rung, ready to drop into a `TextKit` attribute dictionary.
    static func attributes(for style: WNTextStyle) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: style),
            .kern: style.tracking,
        ]
    }

    private static func systemWeight(for weight: WNFontWeight) -> NSFont.Weight {
        switch weight {
        case .medium: .medium
        case .semiBold: .semibold
        case .bold: .bold
        }
    }
}
