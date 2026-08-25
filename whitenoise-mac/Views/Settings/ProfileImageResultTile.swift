//
//  ProfileImageResultTile.swift
//  whitenoise-mac
//
//  One square of the web picker's grid, and the badge that says it is the one.
//

import SwiftUI

/// A web search result as the prototype draws it: a bare, edge-to-edge square, cropped to fill,
/// carrying a selection badge in its bottom-trailing corner when it is the active choice.
///
/// `wn-ios-prototype`'s `AvatarWebImagePickerView.imageTile` is a `Color.clear` at a 1:1 aspect
/// ratio with the image laid over it and clipped — no card, no corner radius, no caption. That
/// austerity is the point: what the person is choosing is a *face*, and a 1.18:1 landscape thumb
/// inside a glass card with a title and a credit line under it (which is what this grid used to
/// be, see `GroupImageResultTile`) shows them a crop that the avatar will never take.
///
/// The credit does not disappear, it moves: `ProfileImagePickerSheet` prints the selected result's
/// title and licence in the bar beside the confirm button, where exactly one line has to be read
/// instead of twenty-one.
struct ProfileImageResultTile: View {
    let result: GroupImageSearchResult
    let isSelected: Bool

    @State private var isHovering = false

    /// Large enough for the tile at 2x on the sheet's fixed width — see
    /// `ProfileImagePickerSheet.sheetWidth`, three columns of roughly 205pt.
    private static let previewPixelSize: CGFloat = 448

    private static let badgeSize: CGFloat = 24
    private static let badgeInset: CGFloat = 6
    private static let badgeRingWidth: CGFloat = 2

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let previewURL = result.previewURL {
                    DownsampledAsyncImage(url: previewURL, maxPixelSize: Self.previewPixelSize) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
            .overlay {
                // The pointer affordance the phone has no need of. Drawn inside the square so it
                // does not widen the tile and reopen the 1pt gutters.
                if isHovering, !isSelected {
                    Rectangle()
                        .strokeBorder(WNColor.fillPrimary, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    selectionBadge
                }
            }
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }

    /// What a result without a usable thumbnail draws — see `GroupImageSearchResult.previewURL`,
    /// which never falls back to the arbitrary origin `imageURL`. The glyph takes the muted
    /// content token of the fill it sits on rather than the ambient background family.
    ///
    /// Outlined, unlike a tile carrying a photo. Every "one step off the surface" token in the
    /// palette is `neutral100` in Light, which is what the sheet's own glass resolves to, so a
    /// filled placeholder is invisible against it and a run of them reads as an empty grid rather
    /// than as results that failed to load.
    private var placeholder: some View {
        WNColor.fillSecondary
            .overlay {
                Image(systemName: "photo")
                    .wnFont(.medium24)
                    .foregroundStyle(WNColor.fillContentTertiary)
            }
            .overlay {
                Rectangle()
                    .strokeBorder(WNColor.borderTertiary)
            }
    }

    /// The prototype's badge: the adaptive accent disc, ringed so it separates from whatever the
    /// photo is doing underneath, with a check on it so selection never rides on colour alone.
    ///
    /// The ring is `backgroundPrimary` rather than the prototype's literal white. Its accent is
    /// black in Light and white in Dark, so a white ring in Dark Mode is a white disc with a white
    /// checkmark on it — invisible. `fillPrimary`/`fillContentPrimary` is the same pair inverted
    /// correctly in both appearances; see the pairing rule in `WNNSColor`.
    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(WNColor.fillPrimary)

            Circle()
                .strokeBorder(WNColor.backgroundPrimary, lineWidth: Self.badgeRingWidth)

            Image(systemName: "checkmark")
                .wnFont(.bold10)
                .foregroundStyle(WNColor.fillContentPrimary)
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .padding(Self.badgeInset)
    }
}
