//
//  SettingsSidebarGroupCard.swift
//  whitenoise-mac
//
//  The settings drawer's card: a group of destination rows on one surface, with the hairlines
//  between them and the fill behind the selected one.
//
//  Ported from `wn-ios-prototype`'s settings hub, whose spec is a main card, a support card and
//  a final isolated destructive row. The drawer used to be one flat column of ten rows, which
//  gave the reader no way to tell that Relays and Appearance answer different questions.
//
//  The card is `backgroundPrimary` on the settings drawer's `backgroundTertiary` — the same
//  relationship an iOS grouped list has between its cards and its background, and the reason that
//  drawer has a background level of its own (see `MessagesSidebarBackground.Level`).
//
//  There is deliberately no border. An earlier pass outlined the card because it sat on
//  `backgroundSecondary`, one ramp step away, where a bare fill is the palette's classic
//  invisible card. Moving the drawer to `backgroundTertiary` buys the separation honestly —
//  `FFFFFF` on `F5F5F5`, `000000` on `171717` — so the outline became a line the prototype does
//  not draw. The grouped card there is a surface, not a box.
//

import SwiftUI

/// A group of settings destinations drawn as one card.
///
/// Rows are laid out full-bleed with no spacing, so the card's own `clipShape` rounds the first
/// and last row's outer corners — which is what lets a selected row at either end fill the card
/// to its edge instead of floating inside it.
struct SettingsSidebarGroupCard<Content: View>: View {
    static var cornerRadius: CGFloat { 10 }

    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(WNColor.backgroundPrimary)
        .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
    }
}

/// The hairline between two rows of a card, inset to start where the row's text starts.
///
/// Inset rather than full-width because a separator that runs under the glyph column reads as a
/// divider between *groups*; aligning it to the text is what keeps the rows reading as one group.
struct SettingsSidebarRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(WNColor.borderTertiary)
            .frame(height: 0.5)
            .padding(.leading, SettingsSidebarRowMetrics.textLeadingInset)
    }
}

/// The fill behind a row inside a card.
///
/// A plain rectangle, not a rounded one: the rows are full-bleed and the card clips, so a radius
/// here would cut a notch out of the selection at the card's first and last row. `fillTertiary`
/// is transparent in both appearances, which is exactly what an unselected row wants — the card
/// shows through.
struct SettingsSidebarRowBackground: View {
    let isSelected: Bool

    var body: some View {
        Rectangle()
            .fill(isSelected ? WNColor.fillTertiaryHover : WNColor.fillTertiary)
    }
}

/// The one place the drawer row's geometry is decided, so the separator's inset cannot drift
/// away from the text it is supposed to line up with.
enum SettingsSidebarRowMetrics {
    static let glyphWidth: CGFloat = 22
    static let glyphSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 9

    static var textLeadingInset: CGFloat { horizontalPadding + glyphWidth + glyphSpacing }
}
