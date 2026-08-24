//
//  ProfileSettingsView.swift
//  whitenoise-mac
//
//  The Profile page: the public profile other people see for this identity, its
//  identity header, and the picker behind the avatar.
//

import SwiftUI
import UniformTypeIdentifiers

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
            Button {
                workspace.showProfileImagePicker()
            } label: {
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
            .buttonStyle(.plain)
            .help(L10n.string("Change profile image"))
            .accessibilityLabel(L10n.string("Change profile image"))

            HStack(spacing: 8) {
                WNCopyCard(
                    displayText: DisplayText.grouped(npub),
                    value: npub,
                    actionDescription: L10n.string("Copy npub")
                )

                PublicIdentityQRCodeButton(
                    accountIdHex: account.accountIdHex,
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

struct ProfileImagePickerSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isFileImporterPresented = false

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 168), spacing: 12)
    ]

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Whichever profile the sheet is filling in — the active account's published
                // picture, or the sign-up draft's staged bytes. On the sign-up path there is no
                // account, so reading `activeAccount` here would leave the header avatar-less
                // exactly when it is most useful: nothing else on screen shows what was picked.
                switch workspace.profileImagePickerDestination {
                case .activeAccount:
                    if let account = workspace.activeAccount {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: account.displayName,
                            sanitizedPictureURL: workspace.profileDraft.sanitizedPictureURL,
                            isOwnAccountImage: true,
                            size: 46,
                            isSelected: false
                        )
                    }
                case .signUpDraft:
                    SignUpAvatarView(size: 46)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Profile image"))
                        .wnFont(.semiBold14)
                    Text(L10n.string("Choose from your Mac or search the web"))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Spacer()

                GlassCircleCloseButton {
                    workspace.closeProfileImagePicker()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            VStack(spacing: 12) {
                HStack {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label(L10n.string("Choose from Mac"), systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isUploadingProfileImage)

                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField(L10n.string("Search images"), text: $workspace.profileImageSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await workspace.searchProfileImages() }
                        }

                    if workspace.isSearchingProfileImages || workspace.isUploadingProfileImage {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await workspace.searchProfileImages() }
                    } label: {
                        Label(L10n.string("Search"), systemImage: "magnifyingglass")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(
                        workspace.profileImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || workspace.isSearchingProfileImages
                            || workspace.isUploadingProfileImage
                    )
                }

                Text(
                    L10n.string("Search terms are sent to Openverse. Selected images are copied to Blossom before use.")
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsErrorView(error: workspace.lastError)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)

                ScrollView {
                    if workspace.profileImageResults.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .wnFont(.medium28)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                            Text(
                                workspace.isSearchingProfileImages ? L10n.string("Searching") : L10n.string("No images")
                            )
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(workspace.profileImageResults) { result in
                                Button {
                                    Task { await workspace.setProfileImage(result) }
                                } label: {
                                    GroupImageResultTile(result: result)
                                }
                                .buttonStyle(.plain)
                                .disabled(workspace.isUploadingProfileImage)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 620, height: 560)
        .background {
            LiquidGlassBackground()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await workspace.setProfileImage(fileURL: url) }
            case .failure(let error):
                workspace.reportUserActionError(error.localizedDescription)
            }
        }
    }
}
