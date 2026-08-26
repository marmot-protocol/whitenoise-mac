//
//  SignUpAvatarView.swift
//  whitenoise-mac
//
//  What the identity being created looks like, at whatever size is asking.
//

import SwiftUI

/// The sign-up draft's avatar: the staged photo, or the name's initials, or — while both are
/// empty — a neutral glyph.
///
/// Shared between the sign-up pane's hero and the image picker's header row, which are the only
/// two places the draft's face is drawn and which would otherwise disagree about the third case.
///
/// The picture comes from bytes rather than a URL. Nothing has been uploaded yet and nothing can
/// be until there is an account to sign the upload, so `localImagePayload` is the only way in;
/// see `SignUpDraft`.
///
/// **Why this draws its own disc rather than reaching for `ProfileImageAvatarView`.** Every other
/// avatar in the app identifies a *person*, and `AvatarPalette` is what tells two of them apart:
/// twelve accent ramps keyed on an account id. A draft has no account id, so the seed was a
/// constant — one arbitrary accent, picked for an identity that is not yet anybody. Worse, the
/// ramp's light step is `50`, a pale wash, which is what made the pane's subject the faintest
/// thing on it.
///
/// `wn-ios-prototype`'s `ProfileEditorAvatarView` fills the same disc with `AccentColor`, and that
/// colorset is black in light and white in dark — the inversion this palette calls `fillPrimary`,
/// with `fillContentPrimary` for the letters on top of it. Same pairing, both appearances, and no
/// accent at all: this circle says "you", not "which of twelve people you are".
///
/// **One ground, whatever is on it.** The empty first frame used to take the *other* half of the
/// palette — `fillSecondary` under `fillContentSecondary`, the prototype's `.secondarySystemFill`
/// — on the reasoning that a filled disc announces an identity that does not exist yet. It read as
/// the inversion running backwards: in light the pane opened with a near-white circle carrying a
/// dark glyph, and then went dark-with-light-letters the moment a name was typed into the field
/// below it. The prototype does not make that switch either — `SignUpView` passes no
/// `emptySystemImage`, so its disc is `AccentColor` from the first frame — and the switch is what
/// the hero is judged by, since the empty frame is the one every new account sees.
struct SignUpAvatarView: View {
    @Environment(WorkspaceState.self) private var workspace
    let size: CGFloat

    /// The first frame: no photo and no name.
    ///
    /// Worth a branch of its own because initials of nothing are not initials. It picks *what* is
    /// drawn on the disc and no longer what the disc is — see the note on the ground above.
    private var hasNothingToShow: Bool {
        workspace.signUpDraft.image == nil && workspace.signUpDraft.trimmedDisplayName.isEmpty
    }

    var body: some View {
        face
            .frame(width: size, height: size)
            .clipShape(.circle)
            .modifier(AvatarChromeModifier(isSelected: false))
    }

    @ViewBuilder
    private var face: some View {
        if let payload = workspace.signUpDraft.image?.preview {
            // Drawn here rather than through `ProfileImageAvatarView` so the placeholder shown
            // while the bytes decode is *this* view's disc. That wrapper's placeholder is
            // `AvatarView`, so routing the photo case through it would flash the palette accent
            // this file exists to not draw.
            DownsampledDataImage(payload: payload, maxPixelSize: size * 2) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                disc
            }
        } else {
            disc
        }
    }

    /// The photo-less disc: one ground, and whichever mark the draft has to put on it.
    ///
    /// The ground and the ink are named once, outside the branch, because they are the pairing —
    /// `fillPrimary` carrying `fillContentPrimary`, which is white on `neutral950` in light and
    /// `neutral950` on white in dark. Splitting them across the branch is how the empty frame
    /// came to draw the pairing the other way round. See the pairing rule in `WNNSColor`.
    private var disc: some View {
        mark
            .foregroundStyle(WNColor.fillContentPrimary)
            .frame(width: size, height: size)
            // Deliberately not one of the twelve accent sets: those identify a person, and this is
            // an identity that is not anybody yet.
            .background(WNColor.fillPrimary, in: .circle)
    }

    /// What the disc carries: the draft's initials, or — with no name to take them from — a person.
    @ViewBuilder
    private var mark: some View {
        if hasNothingToShow {
            Image(systemName: "person.fill")
                .wnFont(.custom(size: size * Self.glyphScale, weight: .medium))
        } else {
            Text(DisplayText.initials(for: workspace.signUpDraft.displayName, fallback: ""))
                // `AvatarView`'s monogram ratio, so the draft's letters are the size every other
                // avatar in the app draws them at.
                .wnFont(.custom(size: size * Self.monogramScale, weight: .bold))
        }
    }

    /// How much of the circle the glyph fills. `AvatarView` sets its monogram at `monogramScale`;
    /// a person symbol reads smaller than two capitals at the same point size, so it takes a
    /// little more.
    private static let glyphScale: CGFloat = 0.4

    /// `AvatarView`'s monogram ratio, restated because that one is a literal inside its body.
    private static let monogramScale: CGFloat = 0.34
}
