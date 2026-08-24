//
//  WhiteNoiseMarkView.swift
//  whitenoise-mac
//
//  The app's wordless mark, on nothing.
//

import SwiftUI

/// White Noise's mark: the four interlocking diagonals, drawn in the palette's own ink.
///
/// This replaces `Image("WhiteNoiseLogo")`, which was not a mark at all but a **pre-rendered
/// tile** — an opaque `#2C2C2C` rounded square with the mark knocked out of it, baked into a
/// 104pt PNG. Two things were wrong with it, and they are the same thing twice: the tile's
/// surface belonged to no palette, so the one pane that showed it (the sign-in screen) had to
/// pick a background that would bleed into the tile rather than the background the screen
/// wanted, and the tile could not follow the appearance, so a dark square sat on a light pane
/// in Aqua. The imageset is gone; nothing draws that tile any more.
///
/// What draws here instead is `assets/svgs/whitenoise.svg` from the Flutter client — the same
/// path data `wn-ios-prototype` ships as `WhiteNoiseMark` — as a **template** asset, so the
/// color comes from `foregroundStyle` rather than from the file. That makes this the same mark
/// the other clients draw, tinted the same way: Flutter fills it with
/// `colors.backgroundContentPrimary` through a `srcIn` color filter, and this is that token.
/// It is also literally the file's own fill — the SVG's `#0A0A0A` *is* `neutral950`, the light
/// half of `backgroundContentPrimary` — which is the tell that the mark was always meant to be
/// ink and never a tile.
struct WhiteNoiseMarkView: View {
    /// The mark's drawn width. Its height follows from `Self.aspectRatio`; callers size one edge
    /// and let the other fall out, so the mark can never be squashed.
    let width: CGFloat

    /// 171 × 132, straight off the source SVG's `viewBox`. Named because the mark is wider than
    /// it is tall — the one thing a caller reaching for a square frame would get wrong.
    static let aspectRatio: CGFloat = 171.0 / 132.0

    var body: some View {
        Image("WhiteNoiseMark")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .frame(width: width, height: (width / Self.aspectRatio).rounded())
            // Named rather than inherited. The ambient foreground is already
            // `backgroundContentPrimary` (see `ContentView`), so leaving this off would look
            // right today and go wrong the first time the mark is drawn inside something that
            // sets its own foreground — a button label, a filled row.
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .accessibilityLabel(L10n.string("White Noise"))
    }
}
