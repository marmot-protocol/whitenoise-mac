//
//  ProfileSettingsView.swift
//  whitenoise-mac
//
//  The Profile page: native grouped form preserving identity, privacy explanation, editable
//  fields, inline validation, and Save/Cancel actions (S04, G01, C10).
//

import SwiftUI

struct ProfileSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Profile"),
            subtitle: L10n.string("Publish the profile other people see for this identity.")
        ) {
            if let account = workspace.activeAccount {
                SettingsSection {
                    ProfileIdentityHeaderView(
                        account: account,
                        displayName: profilePreviewName(fallback: account)
                    )
                }
            }

            SettingsSection {
                ProfilePrivacyNote(showsContainer: false)
            }

            SettingsSection {
                TextField(
                    L10n.string("Name"),
                    text: $workspace.profileDraft.displayName,
                    prompt: Text(L10n.string("Enter your name"))
                )
                .disabled(!workspace.isProfileFormEnabled)
                .accessibilityIdentifier("settings.profile.name")

                ProfileNostrAddressField()

                TextField(
                    L10n.string("About"),
                    text: $workspace.profileDraft.about,
                    prompt: Text(L10n.string("Introduce yourself")),
                    axis: .vertical
                )
                .lineLimit(OnboardingLayout.aboutFieldLineLimit...6)
                .disabled(!workspace.isProfileFormEnabled)
                .accessibilityIdentifier("settings.profile.about")
            }

            if workspace.hasUnsavedProfileEdits || workspace.isLoadingSettings {
                SettingsSection {
                    ProfileEditingActions()
                }
            }
        }
        .sheet(isPresented: $workspace.isProfileImagePickerPresented) {
            ProfileImagePickerSheet()
                .environment(\.locale, workspace.preferredLocale)
        }
    }

    private func profilePreviewName(fallback account: AccountItem) -> String {
        firstNonBlank([
            workspace.profileDraft.displayName,
            account.displayName,
        ]) ?? account.displayName
    }
}

/// The address field and its verification seal / inline validation feedback.
struct ProfileNostrAddressField: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(
                    L10n.string("Verified Nostr Address"),
                    text: $workspace.profileDraft.nip05,
                    prompt: Text(L10n.string("name@example.com"))
                )
                .autocorrectionDisabled()
                .disabled(!workspace.isProfileFormEnabled)
                .accessibilityValue(Text(accessibilityValue))
                .accessibilityIdentifier("settings.profile.nostr-address")

                VerifiedNostrAddressSeal(verification: workspace.profileNostrAddressSeal)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(WNColor.intentionErrorContent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var validationMessage: String? {
        guard !workspace.isProfileNostrAddressDraftValid else { return nil }
        return L10n.string("Enter an address like name@example.com.")
    }

    private var accessibilityValue: String {
        let address = workspace.profileDraft.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workspace.profileNostrAddressSeal {
        case .none:
            return address
        case .checking:
            return "\(address), \(L10n.string("Checking"))"
        case .verified:
            return "\(address), \(L10n.string("Verified"))"
        case .unverified:
            return "\(address), \(L10n.string("Not verified"))"
        }
    }
}

/// The seal on a verified address: `checkmark.seal.fill` when verified, spinner while checking,
/// and nothing otherwise so unverified state never relies on colour alone.
struct VerifiedNostrAddressSeal: View {
    let verification: NostrAddressVerification

    var body: some View {
        VerifiedNostrAddressSealContent(verification: verification)
            .accessibilityHidden(true)
    }
}

private struct VerifiedNostrAddressSealContent: View {
    let verification: NostrAddressVerification

    var body: some View {
        switch verification {
        case .verified:
            Image(systemName: "checkmark.seal.fill")
                .font(.body)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(width: 20, height: 20)
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        case .none, .unverified:
            EmptyView()
        }
    }
}

/// Trailing-aligned Cancel and Save actions shown once the draft differs from what is published.
struct ProfileEditingActions: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isBusy: Bool {
        workspace.isSavingProfile || workspace.isUploadingProfileImage
    }

    var body: some View {
        HStack(spacing: 10) {
            if workspace.isLoadingSettings {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 0)

            if workspace.hasUnsavedProfileEdits {
                Button(L10n.string("Cancel")) {
                    workspace.discardProfileEdits()
                }
                .wnSecondaryButtonStyle()
                .wnSettingsRowButton()
                .disabled(isBusy)
                .accessibilityIdentifier("settings.profile.cancel")

                Button {
                    Task { await workspace.saveProfile() }
                } label: {
                    HStack(spacing: 6) {
                        if workspace.isSavingProfile {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            workspace.isSavingProfile
                                ? L10n.string("Saving...") : L10n.string("Save")
                        )
                    }
                }
                .wnPrimaryButtonStyle()
                .wnSettingsRowButton()
                .disabled(isBusy || !workspace.canSaveProfileEdits)
                .accessibilityIdentifier("settings.profile.save")
            }
        }
    }
}

/// The top of the profile form: avatar and the native photo source control.
struct ProfileIdentityHeaderView: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem
    let displayName: String

    private let avatarSize: CGFloat = 88

    private var hasPhoto: Bool {
        workspace.profileDraft.sanitizedPictureURL != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: displayName,
                sanitizedPictureURL: workspace.profileDraft.sanitizedPictureURL,
                size: avatarSize,
                isSelected: false
            )

            ProfileImageSourceMenu(
                destination: .activeAccount,
                appearance: .pushButton,
                isEnabled: workspace.isProfileFormEnabled && !workspace.isUploadingProfileImage
            ) {
                Text(L10n.string(hasPhoto ? "Change photo" : "Add photo"))
            }
            .wnSecondaryButtonStyle()
            .wnSettingsRowButton()
            .accessibilityIdentifier("settings.profile.photo")

            if workspace.isUploadingProfileImage {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

#Preview("Profile settings") {
    ProfileSettingsView()
        .environment(WorkspaceState.preview())
        .frame(width: 560, height: 640)
}
