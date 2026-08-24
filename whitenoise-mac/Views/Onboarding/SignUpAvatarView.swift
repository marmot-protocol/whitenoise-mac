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
struct SignUpAvatarView: View {
    @Environment(WorkspaceState.self) private var workspace
    let size: CGFloat

    /// The first frame: no photo and no name.
    ///
    /// Worth a branch of its own because `AvatarView` derives initials from the name and falls
    /// back to the *palette seed* when the name is blank — and this seed is a constant, so an
    /// untouched pane drew the two letters of `SignUpDraft.avatarPaletteSeed`. Initials of nothing
    /// are not initials. `wn-ios-prototype`'s `ProfileEditorAvatarView` carries the same branch
    /// for the same reason: `emptySystemImage`, shown only while the image and the name are both
    /// empty.
    private var hasNothingToShow: Bool {
        workspace.signUpDraft.image == nil && workspace.signUpDraft.trimmedDisplayName.isEmpty
    }

    var body: some View {
        if hasNothingToShow {
            Image(systemName: "person.fill")
                .wnFont(.custom(size: size * Self.glyphScale, weight: .medium))
                // The glyph sits on `fillSecondary`, so it takes that family's content token
                // rather than the ambient `backgroundContentPrimary`. See the pairing rule in
                // `WNNSColor`.
                .foregroundStyle(WNColor.fillContentSecondary)
                .frame(width: size, height: size)
                // `fillSecondary`, the ground the fields under it stand on, and the palette's
                // reading of the prototype's `.secondarySystemFill`. Deliberately not one of the
                // twelve accent sets: those identify a person, and this is the absence of one.
                .background(WNColor.fillSecondary, in: .circle)
                .modifier(AvatarChromeModifier(isSelected: false))
        } else {
            ProfileImageAvatarView(
                seed: SignUpDraft.avatarPaletteSeed,
                initials: workspace.signUpDraft.displayName,
                sanitizedPictureURL: nil,
                localImagePayload: workspace.signUpDraft.image?.preview,
                isOwnAccountImage: true,
                size: size,
                isSelected: false
            )
        }
    }

    /// How much of the circle the glyph fills. `AvatarView` sets its monogram at `0.34`; a
    /// person symbol reads smaller than two capitals at the same point size, so it takes a little
    /// more.
    private static let glyphScale: CGFloat = 0.4
}
