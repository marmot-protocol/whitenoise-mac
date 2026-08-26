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
/// state, which a camera glyph cannot. Drawn as the pane's own secondary tier at a smaller size;
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
                    .wnFont(.medium12)
            }
            // The same tier the welcome pane's `Sign In` wears, handed over rather than named
            // again here: this is a secondary action standing on a bare onboarding pane, which is
            // what `OnboardingActionTier.elevated` is for. It is also what the prototype does —
            // `WelcomeView`'s Sign In and `SignUpView`'s `Add Photo` are both
            // `.buttonStyle(.glass)`, the same button at two sizes — where this pill was the
            // *ringed* tier, `.wnSecondary`, so the flow offered two different-looking secondary
            // buttons one pane apart.
            .onboardingActionTier(.elevated)
            // The size is the only thing that differs from the pane's own buttons, and it differs
            // for the same reason the prototype leaves this control at its default size while its
            // CTA is `.extraLarge`. The pane sets `.large` on the whole scaffold for its 44pt CTA,
            // and a subordinate control at that size is a second full-height button under the hero
            // — it would read as the thing the pane is asking for rather than as the optional step
            // it is. `.small` draws it at 21pt against the CTA's 44, and those 10pt are also
            // height the pane does not have; see `OnboardingLayout.signUpAvatarSize`.
            .controlSize(.small)
            .accessibilityIdentifier("onboarding.sign-up.photo")
        }
        // The hero is centred by a frame rather than by the scaffold, which lays its children out
        // full-width: without this the avatar sits against the pane's leading edge.
        .frame(maxWidth: .infinity)
    }
}
