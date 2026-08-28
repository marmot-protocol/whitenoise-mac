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

/// The glyph column of a settings drawer row.
///
/// An atom rather than four copies of the same `Image` because the glyph column is where the
/// drawer's rows agree with each other: one width, one type size, and one tint rule. The tint rule
/// is the interesting part — `wn-ios-prototype`'s hub draws each row as a single
/// `Label(...).foregroundStyle(.primary)`, so the glyph is *the same colour as the title beside
/// it*. This app had the glyph a step down at `backgroundContentSecondary` and lifted it to primary
/// only on the selected row, which made every unselected glyph read as disabled. Selection is
/// carried by `SettingsSidebarRowBackground`'s fill, which is the only signal the prototype uses
/// too — so the glyph does not need to encode it a second time.
struct SettingsSidebarRowGlyph: View {
    let systemImage: String
    var tint: Color = WNColor.backgroundContentPrimary

    var body: some View {
        Image(systemName: systemImage)
            .wnFont(.medium14)
            .foregroundStyle(tint)
            .frame(width: SettingsSidebarRowMetrics.glyphWidth)
    }
}

/// Glyph, title, and the room a trailing accessory needs: the shape every plain row in the
/// settings drawer takes.
///
/// The rows this composes are a destination, the sign-out line and the add-profile line — three
/// call sites that had three separate copies of the same `HStack`, and so three chances for one of
/// them to drift a padding or a font off the others. Carrying the *label* rather than the whole
/// row is deliberate: a destination row wants a selection background behind it and the sign-out
/// row does not, and that difference belongs to the caller's `Button`, not here.
struct SettingsSidebarRowLabel<Accessory: View>: View {
    let systemImage: String
    let title: String
    var tint: Color = WNColor.backgroundContentPrimary
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: SettingsSidebarRowMetrics.glyphSpacing) {
            SettingsSidebarRowGlyph(systemImage: systemImage, tint: tint)

            Text(title)
                .wnFont(.medium14)
                .foregroundStyle(tint)
                .lineLimit(1)

            Spacer(minLength: 0)

            accessory
        }
        .padding(.vertical, SettingsSidebarRowMetrics.verticalPadding)
        .padding(.horizontal, SettingsSidebarRowMetrics.horizontalPadding)
        .contentShape(Rectangle())
    }
}

extension SettingsSidebarRowLabel where Accessory == EmptyView {
    init(systemImage: String, title: String, tint: Color = WNColor.backgroundContentPrimary) {
        self.init(systemImage: systemImage, title: title, tint: tint, accessory: { EmptyView() })
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
