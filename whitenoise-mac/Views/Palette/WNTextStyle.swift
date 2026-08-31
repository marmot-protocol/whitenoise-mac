//
//  WNTextStyle.swift
//  whitenoise-mac
//
//  A rung is a size paired with a weight, applied through `View.wnFont(_:)` rather
//  than as a bare `Font`, so the ladder stays the vocabulary every call site speaks
//  and can be moved in one place.
//
//  Sizes are the Flutter ladder verbatim. Where this app once used a macOS text
//  style or an off-ladder pixel size, it was migrated onto the *nearest* rung, so
//  the app keeps its native desktop scale instead of inheriting the mobile client's
//  larger one.
//
//  The face is the system one — the same choice `wn-ios-prototype` makes, where
//  nothing is registered and every run is `systemFont`. Two things follow from it:
//
//  The ramp carries no tracking. It used to hold a kern ladder alongside each size
//  — opened up at small sizes, pulled closed at large — because the bundled Manrope
//  was drawn tight and needed it. San Francisco is already tracked optically per
//  size by the framework, so those values would now land on a face that has had
//  them; the ladder is sizes and weights only.
//
//  And a rung is a fixed size rather than one scaled against a text style. Only
//  `Font.custom` takes `relativeTo:`, and it addresses a face by name — which is
//  not how a system font may be asked for: CoreText answers a name lookup for one
//  with a substitute rather than an error, and macOS ships no `UIFontMetrics` twin
//  to scale a size by hand. So the ramp trades the reader's text-size setting for
//  the supported route to the face. Reach for `@ScaledMetric` at a call site that
//  genuinely needs to follow it.
//
//  Flutter's "compact" variants are deliberately absent: they differ from their
//  siblings only in line height, which this ramp leaves to SwiftUI.
//

import SwiftUI

struct WNTextStyle: Equatable, Sendable {
    let weight: WNFontWeight
    let size: CGFloat
    var usesMonospacedDigits = false

    var font: Font {
        let face = Font.system(size: size, weight: weight.swiftUI)
        return usesMonospacedDigits ? face.monospacedDigit() : face
    }

    /// Fixed-width digits, for counters and timers that would otherwise jitter as they tick.
    func monospacedDigit() -> Self {
        var copy = self
        copy.usesMonospacedDigits = true
        return copy
    }
}

// MARK: - The ladder

extension WNTextStyle {
    /// Every size on the ramp, in order — the Flutter ladder verbatim. The tokens below
    /// are the only sizes the app is set in; `TypographyTests` holds them to this list so
    /// a fifteenth size cannot arrive by way of a new token.
    static let ladder: [CGFloat] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96]

    /// A rung of the ladder. Private so a size can only enter the ramp as a named token.
    private static func rung(_ size: CGFloat, _ weight: WNFontWeight) -> Self {
        Self(weight: weight, size: size)
    }

    /// Escape hatch for text whose size is computed at runtime — an avatar monogram
    /// scaled to its circle, say. The size is honoured as given; a ladder size is what
    /// every other call site should be asking for.
    static func custom(size: CGFloat, weight: WNFontWeight) -> Self {
        Self(weight: weight, size: size)
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
