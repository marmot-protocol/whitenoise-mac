//
//  ProfileChooserView.swift
//  whitenoise-mac
//
//  "Choose a profile": what the detail pane shows after the active profile was deleted while other
//  signed-in profiles remain on this Mac. Ported from `whitenoise-ios`, whose account exit asks for
//  an explicit choice (`AccountExitProfileChooser` / `SignedOutProfilesView`) instead of quietly
//  moving the user into whichever identity happens to be listed first.
//

import SwiftUI

/// Lists the signed-in profiles left on this Mac, and offers to add another one.
///
/// Takes everything through `init`: the shell decides what choosing a profile does. The one
/// workspace read left is `CopyableKeyLabel`'s npub encoding in each row.
struct ProfileChooserView: View {
    let accounts: [AccountItem]
    /// Disables the rows while another account change is still running.
    var isBusy = false
    let onChoose: (AccountItem) -> Void
    let onAddProfile: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                ProfileChooserHeader()
            }

            Section {
                ForEach(accounts) { account in
                    Button {
                        onChoose(account)
                    } label: {
                        ProfileChooserRow(account: account)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
            }

            Section {
                WNPrimaryButton(
                    L10n.string("Add Profile", locale: locale),
                    systemImage: "person.crop.circle.badge.plus",
                    action: onAddProfile
                )
                .frame(maxWidth: .infinity)
                .disabled(isBusy)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The chooser's opening: what happened and what to do next, in iOS's words.
private struct ProfileChooserHeader: View {
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .wnFont(.medium28)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .accessibilityHidden(true)
            Text(L10n.string("Choose a profile", locale: locale))
                .wnFont(.semiBold18)
                .foregroundStyle(WNColor.backgroundContentPrimary)
            Text(L10n.string("Choose a signed-in profile, or add a new one.", locale: locale))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// One signed-in profile: avatar, name and the start and end of its key.
private struct ProfileChooserRow: View {
    let account: AccountItem

    var body: some View {
        HStack(spacing: 10) {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: account.initials,
                sanitizedPictureURL: account.sanitizedPictureURL,
                size: MessagesLayout.settingsProfileAvatarSize,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .wnFont(.medium14)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                    .lineLimit(1)
                CopyableKeyLabel(
                    accountIdHex: account.accountIdHex, head: 8, tail: 6, showsCopyButton: false)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    ProfileChooserView(
        accounts: AccountItem.samples,
        onChoose: { _ in },
        onAddProfile: {}
    )
    .frame(width: 640, height: 520)
    // `CopyableKeyLabel` encodes each row's npub through the workspace.
    .environment(WorkspaceState.preview())
}
