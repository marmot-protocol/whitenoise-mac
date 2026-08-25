//
//  OnboardingSignUpAvatar.swift
//  whitenoise-mac
//
//  The sign-up pane's hero: the face of the identity being created, and the one
//  control that changes it.
//

import SwiftUI

/// The avatar the new identity will have, as the menu of places its picture can come from.
///
/// This stands where the mark stands on the other two panes — see `OnboardingScaffold`. Both the
/// prototype and Flutter put the picture-picking affordance *on* the avatar rather than beside it
/// (`WnAvatar(onEditTap:)`, and the prototype's menu hung off a "Change Photo" pill); the mac's
/// own Settings → Profile page already draws the on-avatar version, so this is that control at
/// hero size rather than a fourth way to do the same thing.
///
/// Pressing it opens `wn-ios-prototype`'s source menu rather than going straight to a window —
/// see `ProfileImageSourceMenu`, which owns both entries and the file import behind one of them.
/// The badge stays a camera because that is the glyph both other clients put here for "change
/// this picture"; nothing on a Mac takes the photo.
struct OnboardingSignUpAvatar: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isBusy: Bool {
        workspace.isAuthenticating || workspace.isUploadingProfileImage
    }

    var body: some View {
        ProfileImageSourceMenu(destination: .signUpDraft, isEnabled: !isBusy) {
            ZStack(alignment: .bottomTrailing) {
                SignUpAvatarView(size: OnboardingLayout.signUpAvatarSize)

                Image(systemName: "camera.fill")
                    .wnFont(.semiBold12)
                    .foregroundStyle(WNColor.fillContentQuaternary)
                    .frame(
                        width: OnboardingLayout.signUpAvatarBadgeSize,
                        height: OnboardingLayout.signUpAvatarBadgeSize
                    )
                    .background(WNColor.overlayTertiary, in: .circle)
            }
            .contentShape(.circle)
        }
        // The hero is centred by a frame rather than by the scaffold, which lays its children out
        // full-width: without this the avatar sits against the pane's leading edge.
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("onboarding.sign-up.photo")
    }
}
