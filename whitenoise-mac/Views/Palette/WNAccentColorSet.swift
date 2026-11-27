//
//  WNAccentColorSet.swift
//  whitenoise-mac
//
//  The twelve identity accent sets, derived dynamically from Apple's native macOS
//  `NSColor.system*` palette so every identity keeps a consistent hue across Light
//  and Dark appearances while maintaining crisp contrast against both the window
//  surface (no border ring needed) and the initials drawn on top (WCAG AAA ≥ 7:1).
//
//  Accents are not a second palette to decorate with — they exist so that one
//  person is consistently one color. Everything else in the app stays neutral.
//

import AppKit
import SwiftUI

/// One accent, as the four roles it plays together. Never mix roles across sets:
/// `contentPrimary` is legible on its own set's `fill` and on no other.
///
/// Each role is stored as the dynamic `NSColor` with the SwiftUI twin alongside it,
/// rather than converting on demand. `NSColor(someSwiftUIColor)` is not a
/// round-trip — it can bake in the appearance that happened to be current when it
/// was called — and one of these roles is handed to AppKit for the composer's
/// mention tokens.
nonisolated struct WNAccentColorSet {
    /// The adaptive avatar disc surface derived from Apple's native system color.
    let nsFill: NSColor
    /// Primary initials/content on `fill`. Crosses over with `fill` between Light and Dark
    /// so every pair clears WCAG AAA contrast in both appearances.
    let nsContentPrimary: NSColor
    /// Supporting content and mention color: Apple's native adaptive system color directly.
    let nsContentSecondary: NSColor
    /// Selection/focus ring accent for this hue.
    let nsBorder: NSColor

    let fill: Color
    let contentPrimary: Color
    let contentSecondary: Color
    let border: Color

    fileprivate init(
        _ name: String,
        systemBase: @escaping @Sendable () -> NSColor
    ) {
        self.nsFill = NSColor(name: "wn.accent.\(name).fill") { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let resolved = Self.resolveSRGB(systemBase())
            if isDark {
                let lum = Self.relativeLuminance(resolved)
                let fraction: CGFloat = lum > 0.55 ? 0.36 : (lum > 0.35 ? 0.41 : 0.54)
                return Self.mix(.black, resolved, t: fraction)
            } else {
                return Self.mix(.white, resolved, t: 0.24)
            }
        }
        self.nsContentPrimary = NSColor(name: "wn.accent.\(name).contentPrimary") { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let resolved = Self.resolveSRGB(systemBase())
            return isDark
                ? Self.mix(resolved, .white, t: 0.92)
                : Self.mix(resolved, .black, t: 0.62)
        }
        self.nsContentSecondary = NSColor(name: "wn.accent.\(name).contentSecondary") { _ in
            Self.resolveSRGB(systemBase())
        }
        self.nsBorder = NSColor(name: "wn.accent.\(name).border") { _ in
            let resolved = Self.resolveSRGB(systemBase())
            return Self.mix(.white, resolved, t: 0.55)
        }

        self.fill = Color(nsColor: nsFill)
        self.contentPrimary = Color(nsColor: nsContentPrimary)
        self.contentSecondary = Color(nsColor: nsContentSecondary)
        self.border = Color(nsColor: nsBorder)
    }

    private static func resolveSRGB(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    fileprivate static func mix(_ lhs: NSColor, _ rhs: NSColor, t: CGFloat) -> NSColor {
        let a = resolveSRGB(lhs)
        let b = resolveSRGB(rhs)
        return NSColor(
            srgbRed: a.redComponent * (1 - t) + b.redComponent * t,
            green: a.greenComponent * (1 - t) + b.greenComponent * t,
            blue: a.blueComponent * (1 - t) + b.blueComponent * t,
            alpha: 1
        )
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        let s = resolveSRGB(color)
        func linear(_ component: CGFloat) -> Double {
            let v = Double(component)
            return v <= 0.039_28 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(s.redComponent) + 0.7152 * linear(s.greenComponent) + 0.0722 * linear(s.blueComponent)
    }
}

nonisolated enum WNAccentColors {
    static let blue = WNAccentColorSet("blue") { .systemBlue }
    static let cyan = WNAccentColorSet("cyan") { .systemCyan }
    static let emerald = WNAccentColorSet("emerald") { .systemGreen }
    static let fuchsia = WNAccentColorSet("fuchsia") { .systemPink }
    static let indigo = WNAccentColorSet("indigo") { .systemIndigo }
    static let lime = WNAccentColorSet("lime") {
        WNAccentColorSet.mix(.systemGreen, .systemYellow, t: 0.45)
    }
    static let orange = WNAccentColorSet("orange") { .systemOrange }
    static let rose = WNAccentColorSet("rose") { .systemRed }
    static let sky = WNAccentColorSet("sky") { .systemBrown }
    static let teal = WNAccentColorSet("teal") { .systemMint }
    static let violet = WNAccentColorSet("violet") { .systemPurple }
    static let amber = WNAccentColorSet("amber") { .systemYellow }
}
