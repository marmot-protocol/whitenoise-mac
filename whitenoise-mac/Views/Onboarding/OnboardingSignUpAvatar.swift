//
//  OnboardingSignUpAvatar.swift
//  whitenoise-mac
//
//  The sign-up pane's hero: the face of the identity being created, and the one
//  control that changes it.
//

import SwiftUI

/// The avatar the new identity will have, as a button that opens the image picker.
///
/// This stands where the mark stands on the other two panes — see `OnboardingScaffold`. Both the
/// prototype and Flutter put the picture-picking affordance *on* the avatar rather than beside it
/// (`WnAvatar(onEditTap:)`, and the prototype's menu hung off a "Change Photo" pill); the mac's
/// own Settings → Profile page already draws the on-avatar version, so this is that control at
/// hero size rather than a fourth way to do the same thing.
struct OnboardingSignUpAvatar: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isBusy: Bool {
        workspace.isAuthenticating || workspace.isUploadingProfileImage
    }

    var body: some View {
        Button {
            workspace.showSignUpImagePicker()
        } label: {
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
        .buttonStyle(.plain)
        .disabled(isBusy)
        // The hero is centred by a frame rather than by the scaffold, which lays its children out
        // full-width: without this the avatar sits against the pane's leading edge.
        .frame(maxWidth: .infinity)
        .help(L10n.string("Change profile image"))
        .accessibilityLabel(L10n.string("Change profile image"))
        .accessibilityIdentifier("onboarding.sign-up.photo")
    }
}
