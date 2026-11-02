//
//  OnboardingSignUpAvatar.swift
//  whitenoise-mac
//
//  The sign-up pane's hero: the face of the identity being created, and the one
//  control that changes it.
//

import SwiftUI

/// The avatar the new identity will have, over the pill that changes it.
///
/// This stands where the mark stands on the other two panes — see `OnboardingScaffold`.
///
/// **The affordance is a pill under the avatar, not a badge on it.** That is what
/// `wn-ios-prototype`'s `SignUpView` draws: the face is inert, and a capsule beneath it reads
/// `Add Photo` before a picture has been chosen and `Change Photo` after — the label carrying the
/// state, which a camera glyph cannot. Drawn as the pane's own secondary tier;
/// see the two modifiers on it. Settings → Profile keeps the on-avatar badge, because that
/// page has no room under its avatar for a control and its picture is already published; this pane
/// is asking for one.
///
/// Pressing it opens `wn-ios-prototype`'s source menu rather than going straight to a window —
/// see `ProfileImageSourceMenu`, which owns both entries, the file import behind one of them, and
/// the two appearances the two screens ask for.
struct OnboardingSignUpAvatar: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isBusy: Bool {
        workspace.isAuthenticating || workspace.isUploadingProfileImage
    }

    private var hasPhoto: Bool {
        workspace.signUpDraft.image != nil
    }

    var body: some View {
        VStack(spacing: OnboardingLayout.signUpAvatarToPickerSpacing) {
            SignUpAvatarView(size: OnboardingLayout.signUpAvatarSize)

            ProfileImageSourceMenu(
                destination: .signUpDraft, appearance: .pushButton, isEnabled: !isBusy
            ) {
                Text(L10n.string(hasPhoto ? "Change photo" : "Add photo"))
                    .wnFont(OnboardingLayout.signUpPhotoPillTextStyle)
            }
            // The same tier the welcome pane's `Sign In` wears, handed over rather than named
            // again here: this is a secondary action standing on a bare onboarding pane, which is
            // what `OnboardingActionTier.secondary` is for. It is also what the prototype does —
            // `WelcomeView`'s Sign In and `SignUpView`'s `Add Photo` are both
            // `.buttonStyle(.glass)`, the same button at two sizes — where this pill used to be
            // drawn by a second, ringed secondary style, so the flow offered two
            // different-looking secondary buttons one pane apart.
            .onboardingActionTier(.secondary)
            // A full pill, as `whitenoise-ios` draws its photo button — see
            // `OnboardingLayout.signUpPhotoPillControlSize`.
            .controlSize(OnboardingLayout.signUpPhotoPillControlSize)
            .accessibilityIdentifier("onboarding.sign-up.photo")
        }
        // The hero is centred by a frame rather than by the scaffold, which lays its children out
        // full-width: without this the avatar sits against the pane's leading edge.
        .frame(maxWidth: .infinity)
    }
}
