//
//  WNReactionColorSet.swift
//  whitenoise-mac
//
//  Reaction chip colors, ported from `_lightReactionColors` /
//  `_darkReactionColors` in the sibling repository's
//  `lib/theme/semantic_colors.dart`.
//
//  Reactions get their own sets rather than reusing `fill*` because a chip sits
//  *against a bubble*, not against the app surface, and the two bubbles run in
//  opposite directions: the sent bubble is `fillPrimary` (inverted), the received
//  one is `backgroundMessageIncoming` (a neutral step). A chip that used one fill
//  token for both would disappear into one of them.
//
//  Which is also why the two sets cross over between appearances — the light
//  `outgoing` set and the dark `incoming` set are the same values, because in both
//  of those cases the chip is sitting on a dark bubble.
//

import SwiftUI

/// A chip's three states, each with its matching content color.
///
/// Stored as dynamic `NSColor`s with their SwiftUI twins alongside, for the same
/// reason `WNAccentColorSet` does it: converting a `SwiftUI.Color` back to an
/// `NSColor` is not a round-trip and can bake in whichever appearance was current.
nonisolated struct WNReactionColorSet {
    let nsFill: NSColor
    let nsFillHover: NSColor
    /// The state for a reaction the local account has added.
    let nsFillSelected: NSColor
    let nsContent: NSColor
    let nsContentSelected: NSColor

    let fill: Color
    let fillHover: Color
    let fillSelected: Color
    let content: Color
    let contentHover: Color
    let contentSelected: Color

    fileprivate init(
        _ name: String,
        lightFill: NSColor, darkFill: NSColor,
        lightFillHover: NSColor, darkFillHover: NSColor,
        lightFillSelected: NSColor, darkFillSelected: NSColor,
        lightContent: NSColor, darkContent: NSColor,
        lightContentSelected: NSColor, darkContentSelected: NSColor
    ) {
        self.nsFill = .wnDynamic("wn.reaction.\(name).fill", light: lightFill, dark: darkFill)
        self.nsFillHover = .wnDynamic(
            "wn.reaction.\(name).fillHover", light: lightFillHover, dark: darkFillHover)
        self.nsFillSelected = .wnDynamic(
            "wn.reaction.\(name).fillSelected", light: lightFillSelected, dark: darkFillSelected)
        self.nsContent = .wnDynamic(
            "wn.reaction.\(name).content", light: lightContent, dark: darkContent)
        self.nsContentSelected = .wnDynamic(
            "wn.reaction.\(name).contentSelected",
            light: lightContentSelected,
            dark: darkContentSelected)

        self.fill = Color(nsColor: nsFill)
        self.fillHover = Color(nsColor: nsFillHover)
        self.fillSelected = Color(nsColor: nsFillSelected)
        // `content` and `contentHover` are the same value in every set the other
        // clients define, so one dynamic color backs both.
        self.content = Color(nsColor: nsContent)
        self.contentHover = Color(nsColor: nsContent)
        self.contentSelected = Color(nsColor: nsContentSelected)
    }
}

nonisolated enum WNReactionColors {
    /// Chips on a received bubble.
    static let incoming = WNReactionColorSet(
        "incoming",
        lightFill: WNColorRamp.white, darkFill: WNColorRamp.neutral800,
        lightFillHover: WNColorRamp.neutral200, darkFillHover: WNColorRamp.neutral700,
        lightFillSelected: WNColorRamp.neutral800, darkFillSelected: WNColorRamp.neutral50,
        lightContent: WNColorRamp.neutral500, darkContent: WNColorRamp.neutral250,
        lightContentSelected: WNColorRamp.white, darkContentSelected: WNColorRamp.neutral950)

    /// Chips on a sent bubble.
    static let outgoing = WNReactionColorSet(
        "outgoing",
        lightFill: WNColorRamp.neutral800, darkFill: WNColorRamp.neutral100,
        lightFillHover: WNColorRamp.neutral700, darkFillHover: WNColorRamp.neutral150,
        lightFillSelected: WNColorRamp.neutral50, darkFillSelected: WNColorRamp.neutral800,
        lightContent: WNColorRamp.neutral250, darkContent: WNColorRamp.neutral500,
        lightContentSelected: WNColorRamp.neutral950, darkContentSelected: WNColorRamp.white)

    static func set(isOutgoing: Bool) -> WNReactionColorSet {
        isOutgoing ? outgoing : incoming
    }
}
