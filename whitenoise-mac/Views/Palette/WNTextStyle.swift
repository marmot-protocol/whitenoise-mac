//
//  WNTextStyle.swift
//  whitenoise-mac
//
//  The type ramp, ported from the Flutter client's `lib/theme/app_typography.dart`
//  so both clients share one ladder of sizes and one set of weights.
//
//  A rung is a size paired with the letter spacing that size is meant to be set
//  at: Manrope is drawn tight, so the ramp opens the tracking up as text gets
//  smaller (+0.8 at 10pt) and pulls it closed as text gets larger (-1.5 at 96pt).
//  The pairing is the point — a size used without its tracking is not the design.
//  That is why a rung carries both and is applied through `View.wnFont(_:)`,
//  rather than being a bare `Font` that a call site could apply on its own.
//
//  Sizes are the Flutter ladder verbatim. Where this app previously used a macOS
//  text style or an off-ladder pixel size, it now uses the *nearest* rung, so the
//  app keeps its native desktop scale instead of inheriting the mobile client's
//  larger one. Every rung still scales with the reader's text-size setting via
//  `relativeTo:`, so pinning a base size does not pin the rendered size.
//
//  Flutter's "compact" variants are deliberately absent: they differ from their
//  siblings only in line height, which this ramp leaves to SwiftUI.
//

import SwiftUI

struct WNTextStyle: Equatable, Sendable {
    let weight: WNFontWeight
    let size: CGFloat
    let tracking: CGFloat
    /// The system text style this rung scales alongside, so the ramp still follows
    /// the reader's text-size setting instead of freezing at `size`.
    let scalesRelativeTo: Font.TextStyle
    var usesMonospacedDigits = false

    var font: Font {
        let face = Font.custom(weight.postScriptName, size: size, relativeTo: scalesRelativeTo)
        return usesMonospacedDigits ? face.monospacedDigit() : face
    }

    /// Fixed-width digits, for counters and timers that would otherwise jitter as they tick.
    /// Manrope ships the Number Spacing feature, so this stays on Manrope rather than
    /// falling back to a system monospaced face.
    func monospacedDigit() -> Self {
        var copy = self
        copy.usesMonospacedDigits = true
        return copy
    }
}

// MARK: - The ladder

extension WNTextStyle {
    /// Every rung of the ramp: size, the tracking that size is set at, and the system
    /// text style it scales with. Single source of truth for the tokens below and for
    /// `custom(size:weight:)`.
    private static let rungs: [(size: CGFloat, tracking: CGFloat, scale: Font.TextStyle)] = [
        (10, 0.8, .caption2),
        (12, 0.6, .callout),
        (14, 0.4, .body),
        (16, 0.2, .title3),
        (18, 0.1, .title2),
        (20, 0, .title),
        (24, -0.1, .title),
        (28, -0.2, .largeTitle),
        (32, -0.3, .largeTitle),
        (36, -0.4, .largeTitle),
        (48, -0.6, .largeTitle),
        (60, -1.0, .largeTitle),
        (72, -1.2, .largeTitle),
        (96, -1.5, .largeTitle),
    ]

    /// Builds the rung nearest `size`, so an off-ladder size snaps onto the ramp
    /// instead of quietly introducing a fifteenth size with invented tracking.
    /// A size falling exactly between two rungs takes the larger one, which is the
    /// rule the existing call sites were migrated onto.
    private static func rung(_ size: CGFloat, _ weight: WNFontWeight) -> Self {
        let nearest =
            rungs.min {
                (abs($0.size - size), -$0.size) < (abs($1.size - size), -$1.size)
            } ?? (size, 0, Font.TextStyle.body)
        return Self(
            weight: weight, size: nearest.size, tracking: nearest.tracking, scalesRelativeTo: nearest.scale)
    }

    /// Escape hatch for text whose size is computed at runtime — an avatar monogram
    /// scaled to its circle, say. The size is honoured as given; the tracking is
    /// borrowed from the nearest rung so the result still sits on the ramp.
    static func custom(size: CGFloat, weight: WNFontWeight) -> Self {
        let nearest = rung(size, weight)
        return Self(
            weight: weight, size: size, tracking: nearest.tracking, scalesRelativeTo: nearest.scalesRelativeTo)
    }

    static let medium10 = rung(10, .medium)
    static let semiBold10 = rung(10, .semiBold)
    static let bold10 = rung(10, .bold)

    static let medium12 = rung(12, .medium)
    static let semiBold12 = rung(12, .semiBold)
    static let bold12 = rung(12, .bold)

    static let medium14 = rung(14, .medium)
    static let semiBold14 = rung(14, .semiBold)
    static let bold14 = rung(14, .bold)

    static let medium16 = rung(16, .medium)
    static let semiBold16 = rung(16, .semiBold)
    static let bold16 = rung(16, .bold)

    static let medium18 = rung(18, .medium)
    static let semiBold18 = rung(18, .semiBold)
    static let bold18 = rung(18, .bold)

    static let medium20 = rung(20, .medium)
    static let semiBold20 = rung(20, .semiBold)
    static let bold20 = rung(20, .bold)

    static let medium24 = rung(24, .medium)
    static let semiBold24 = rung(24, .semiBold)
    static let bold24 = rung(24, .bold)

    static let medium28 = rung(28, .medium)
    static let semiBold28 = rung(28, .semiBold)
    static let bold28 = rung(28, .bold)

    static let medium32 = rung(32, .medium)
    static let semiBold32 = rung(32, .semiBold)
    static let bold32 = rung(32, .bold)

    static let medium36 = rung(36, .medium)
    static let semiBold36 = rung(36, .semiBold)
    static let bold36 = rung(36, .bold)

    static let medium48 = rung(48, .medium)
    static let semiBold48 = rung(48, .semiBold)
    static let bold48 = rung(48, .bold)

    static let medium60 = rung(60, .medium)
    static let semiBold60 = rung(60, .semiBold)
    static let bold60 = rung(60, .bold)

    static let medium72 = rung(72, .medium)
    static let semiBold72 = rung(72, .semiBold)
    static let bold72 = rung(72, .bold)

    static let medium96 = rung(96, .medium)
    static let semiBold96 = rung(96, .semiBold)
    static let bold96 = rung(96, .bold)
}
