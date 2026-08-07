//
//  WNAccentColorSet.swift
//  whitenoise-mac
//
//  The twelve accent sets, ported from `_lightAccentColors` / `_darkAccentColors`
//  in the sibling repository's `lib/theme/semantic_colors.dart`.
//
//  Accents are not a second palette to decorate with — they exist so that one
//  person is consistently one color. Everything else in the app stays neutral.
//

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
    /// The surface. `X50` in light appearance, `X950` in dark.
    let nsFill: NSColor
    /// Primary content on `fill`. `X900` in light, `X50` in dark — it crosses over
    /// with `fill` so the pair keeps its contrast in both appearances.
    let nsContentPrimary: NSColor
    /// Supporting content on `fill`, and the color a mention of this person is
    /// written in. `X500` in both appearances: the one step of each ramp that is
    /// neither the light surface nor the dark one, and therefore the only one that
    /// stays legible without knowing which fill it landed on.
    let nsContentSecondary: NSColor
    /// The outline around `fill`. `X200` in both appearances.
    let nsBorder: NSColor

    let fill: Color
    let contentPrimary: Color
    let contentSecondary: Color
    let border: Color

    fileprivate init(
        _ name: String,
        lightFill: NSColor,
        darkFill: NSColor,
        lightContent: NSColor,
        darkContent: NSColor,
        contentSecondary: NSColor,
        border: NSColor
    ) {
        self.nsFill = .wnDynamic("wn.accent.\(name).fill", light: lightFill, dark: darkFill)
        self.nsContentPrimary = .wnDynamic(
            "wn.accent.\(name).contentPrimary", light: lightContent, dark: darkContent)
        self.nsContentSecondary = contentSecondary
        self.nsBorder = border

        self.fill = Color(nsColor: nsFill)
        self.contentPrimary = Color(nsColor: nsContentPrimary)
        self.contentSecondary = Color(nsColor: nsContentSecondary)
        self.border = Color(nsColor: nsBorder)
    }
}

nonisolated enum WNAccentColors {
    static let blue = WNAccentColorSet(
        "blue",
        lightFill: WNColorRamp.blue50, darkFill: WNColorRamp.blue950,
        lightContent: WNColorRamp.blue900, darkContent: WNColorRamp.blue50,
        contentSecondary: WNColorRamp.blue500, border: WNColorRamp.blue200)

    static let cyan = WNAccentColorSet(
        "cyan",
        lightFill: WNColorRamp.cyan50, darkFill: WNColorRamp.cyan950,
        lightContent: WNColorRamp.cyan900, darkContent: WNColorRamp.cyan50,
        contentSecondary: WNColorRamp.cyan500, border: WNColorRamp.cyan200)

    static let emerald = WNAccentColorSet(
        "emerald",
        lightFill: WNColorRamp.emerald50, darkFill: WNColorRamp.emerald950,
        lightContent: WNColorRamp.emerald900, darkContent: WNColorRamp.emerald50,
        contentSecondary: WNColorRamp.emerald500, border: WNColorRamp.emerald200)

    static let fuchsia = WNAccentColorSet(
        "fuchsia",
        lightFill: WNColorRamp.fuchsia50, darkFill: WNColorRamp.fuchsia950,
        lightContent: WNColorRamp.fuchsia900, darkContent: WNColorRamp.fuchsia50,
        contentSecondary: WNColorRamp.fuchsia500, border: WNColorRamp.fuchsia200)

    static let indigo = WNAccentColorSet(
        "indigo",
        lightFill: WNColorRamp.indigo50, darkFill: WNColorRamp.indigo950,
        lightContent: WNColorRamp.indigo900, darkContent: WNColorRamp.indigo50,
        contentSecondary: WNColorRamp.indigo500, border: WNColorRamp.indigo200)

    static let lime = WNAccentColorSet(
        "lime",
        lightFill: WNColorRamp.lime50, darkFill: WNColorRamp.lime950,
        lightContent: WNColorRamp.lime900, darkContent: WNColorRamp.lime50,
        contentSecondary: WNColorRamp.lime500, border: WNColorRamp.lime200)

    static let orange = WNAccentColorSet(
        "orange",
        lightFill: WNColorRamp.orange50, darkFill: WNColorRamp.orange950,
        lightContent: WNColorRamp.orange900, darkContent: WNColorRamp.orange50,
        contentSecondary: WNColorRamp.orange500, border: WNColorRamp.orange200)

    static let rose = WNAccentColorSet(
        "rose",
        lightFill: WNColorRamp.rose50, darkFill: WNColorRamp.rose950,
        lightContent: WNColorRamp.rose900, darkContent: WNColorRamp.rose50,
        contentSecondary: WNColorRamp.rose500, border: WNColorRamp.rose200)

    static let sky = WNAccentColorSet(
        "sky",
        lightFill: WNColorRamp.sky50, darkFill: WNColorRamp.sky950,
        lightContent: WNColorRamp.sky900, darkContent: WNColorRamp.sky50,
        contentSecondary: WNColorRamp.sky500, border: WNColorRamp.sky200)

    static let teal = WNAccentColorSet(
        "teal",
        lightFill: WNColorRamp.teal50, darkFill: WNColorRamp.teal950,
        lightContent: WNColorRamp.teal900, darkContent: WNColorRamp.teal50,
        contentSecondary: WNColorRamp.teal500, border: WNColorRamp.teal200)

    static let violet = WNAccentColorSet(
        "violet",
        lightFill: WNColorRamp.violet50, darkFill: WNColorRamp.violet950,
        lightContent: WNColorRamp.violet900, darkContent: WNColorRamp.violet50,
        contentSecondary: WNColorRamp.violet500, border: WNColorRamp.violet200)

    static let amber = WNAccentColorSet(
        "amber",
        lightFill: WNColorRamp.amber50, darkFill: WNColorRamp.amber950,
        lightContent: WNColorRamp.amber900, darkContent: WNColorRamp.amber50,
        contentSecondary: WNColorRamp.amber500, border: WNColorRamp.amber200)
}
