//
//  ProfileSettingsView.swift
//  whitenoise-mac
//
//  The Profile page: the public profile other people see for this identity, its
//  identity header, and the picker behind the avatar.
//

import SwiftUI

struct ProfileSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsStackScaffold(
            title: L10n.string("Profile"),
            subtitle: L10n.string("Publish the profile other people see for this identity.")
        ) {
            if let account = workspace.activeAccount {
                ProfileIdentityHeaderView(
                    account: account,
                    displayName: profilePreviewName(fallback: account)
                )
            }

            WNCallout(
                title: L10n.string("Your profile is public"),
                message: L10n.string(
                    "Name, photo, and bio are visible on the global Nostr network. Use what you're comfortable sharing."
                ),
                intent: .info
            )

            SettingsLabeledField(label: L10n.string("Name")) {
                TextField(L10n.string("Enter your name"), text: $workspace.profileDraft.displayName)
            }

            SettingsLabeledField(label: L10n.string("About"), minHeight: 88) {
                TextField(
                    L10n.string("Introduce yourself"),
                    text: $workspace.profileDraft.about,
                    axis: .vertical
                )
                .lineLimit(3...6)
            }

            HStack {
                WNPrimaryButton(
                    workspace.isSavingProfile ? L10n.string("Saving...") : L10n.string("Save profile"),
                    systemImage: "checkmark.circle",
                    size: .large
                ) {
                    Task { await workspace.saveProfile() }
                }
                .disabled(workspace.isSavingProfile || workspace.activeAccount == nil)

                if workspace.isLoadingSettings {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $workspace.isProfileImagePickerPresented) {
            ProfileImagePickerSheet()
        }
    }

    private func profilePreviewName(fallback account: AccountItem) -> String {
        firstNonBlank([
            workspace.profileDraft.displayName,
            account.displayName,
        ]) ?? account.displayName
    }
}

/// The top of the profile form: the avatar, centred and large enough to be the subject of the
/// page, over the npub and its QR code. The name is not repeated here — the Name field is the
/// next thing on the page and carries the same value live.
struct ProfileIdentityHeaderView: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem
    let displayName: String

    private let avatarSize: CGFloat = 96

    private var npub: String {
        workspace.npub(forAccountIdHex: account.accountIdHex)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Closed during an upload, the way the sign-up hero is — see `OnboardingSignUpAvatar`.
            // `beginProfileImageSelection()` refuses a second selection while one is in flight and
            // sets no error, so without this the popover and the file panel both open and the
            // chosen file is dropped in silence, with nothing on this page drawing the upload it
            // was dropped for.
            ProfileImageSourceMenu(
                destination: .activeAccount,
                isEnabled: !workspace.isUploadingProfileImage
            ) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: displayName,
                        sanitizedPictureURL: workspace.profileDraft.sanitizedPictureURL,
                        isOwnAccountImage: true,
                        size: avatarSize,
                        isSelected: false
                    )

                    Image(systemName: "camera.fill")
                        .wnFont(.semiBold12)
                        .foregroundStyle(WNColor.fillContentQuaternary)
                        .frame(width: 30, height: 30)
                        .background(WNColor.overlayTertiary, in: .circle)
                }
                .contentShape(.circle)
            }

            HStack(spacing: 8) {
                WNCopyCard(
                    displayText: DisplayText.grouped(npub),
                    value: npub,
                    actionDescription: L10n.string("Copy npub")
                )

                PublicIdentityQRCodeButton(
                    account: account,
                    displayName: displayName,
                    style: .tile
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }
}
