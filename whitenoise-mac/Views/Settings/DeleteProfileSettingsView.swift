//
//  DeleteProfileSettingsView.swift
//  whitenoise-mac
//
//  Settings → Delete Profile, ported from `whitenoise-ios`'s deletion form (`SignOutForm` with
//  `intent: .deleteProfile`): who is being deleted, what deletion takes with it and what it
//  cannot reach, then the typed confirmation and the one button that acts.
//
//  A page rather than a sheet because that is what iOS does — the row pushes a destination — and
//  because the explanation is the point of the page: six labelled consequences do not fit in the
//  sign-out sheet, whose wipe toggle stays the quick way to leave and erase at once.
//

import SwiftUI

struct DeleteProfileSettingsView: View {
    let model: DeleteProfileViewModel
    let account: AccountItem
    let isAccountMutationInProgress: Bool

    private var challenge: String {
        AccountWipeConfirmation.challenge(
            displayName: account.displayName,
            accountRef: account.accountRef,
            fallback: L10n.string("WIPE")
        )
    }

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Delete Profile"),
            subtitle: L10n.string("This signs you out and permanently removes this profile’s data from this device.")
        ) {
            SettingsSection {
                DeleteProfileIdentityRow(account: account)
            }

            SettingsSection {
                ForEach(DeleteProfileConsequence.all) { consequence in
                    DeleteProfileConsequenceRow(consequence: consequence)
                }
            }

            SettingsSection {
                DeleteProfileConfirmationForm(
                    model: model,
                    account: account,
                    challenge: challenge,
                    isAccountMutationInProgress: isAccountMutationInProgress
                )
            }
        }
    }
}

/// The profile the page deletes, named on the page that deletes it — with several identities on
/// this Mac, "Delete Profile" alone does not say which one goes.
private struct DeleteProfileIdentityRow: View {
    let account: AccountItem

    var body: some View {
        HStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: account.initials,
                sanitizedPictureURL: account.sanitizedPictureURL,
                size: 48,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .wnFont(.semiBold14)
                    .lineLimit(1)
                CopyableKeyLabel(accountIdHex: account.accountIdHex)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One thing deletion does, as iOS words it. Catalog keys, localized at the row.
struct DeleteProfileConsequence: Identifiable, Equatable {
    let title: String
    let detail: String

    var id: String { title }

    static let all: [DeleteProfileConsequence] = [
        DeleteProfileConsequence(
            title: "Chats and media",
            detail: "Your local chats, media, and drafts will be deleted. Signing in again won’t restore them."
        ),
        DeleteProfileConsequence(
            title: "Secret key",
            detail: "Your secret key will be removed from this device. You’ll need a saved copy to sign in again."
        ),
        DeleteProfileConsequence(
            title: "Groups",
            detail: "You’ll leave your groups and need new invitations to rejoin."
        ),
        DeleteProfileConsequence(
            title: "Profile settings",
            detail: "This profile’s local settings will be removed. Your other profiles are unaffected."
        ),
        DeleteProfileConsequence(
            title: "Copies elsewhere",
            detail: "Messages and profile information held by other people or independent relays may remain."
        ),
        DeleteProfileConsequence(
            title: "If you sign in again",
            detail:
                "You can sign in again with a saved secret key and keep the same Nostr identity. Your deleted chats and media won’t be restored, and you’ll need new invitations to rejoin groups."
        ),
    ]
}

private struct DeleteProfileConsequenceRow: View {
    let consequence: DeleteProfileConsequence

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(consequence.title))
                .wnFont(.semiBold14)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.string(consequence.detail))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// The gate and the button. The phrase is typed exactly — see `ProfileDeletionConfirmation`.
struct DeleteProfileConfirmationForm: View {
    @Bindable var model: DeleteProfileViewModel
    let account: AccountItem
    let challenge: String
    let isAccountMutationInProgress: Bool

    private var canDelete: Bool {
        model.canDelete(challenge: challenge, isAccountMutationInProgress: isAccountMutationInProgress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WNInput(
                label: L10n.string("Profile name"),
                prompt: challenge,
                text: $model.confirmation,
                isEnabled: !model.isDeleting,
                disablesAutocorrection: true
            )
            .onSubmit(submit)

            Text(DeleteProfileConfirmationHint.text(challenge: challenge))
                .wnFont(.medium12)
                .fixedSize(horizontal: false, vertical: true)

            if model.showsExtraWhitespaceHint(challenge: challenge) {
                Text(L10n.string("Remove extra spaces before or after the profile name."))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsErrorView(error: model.error)

            Button(action: submit) {
                HStack(spacing: 8) {
                    if model.isDeleting {
                        ProgressView().controlSize(.small)
                    }
                    Text(L10n.string(model.isDeleting ? "Deleting…" : "Delete Profile"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.wnDestructive)
            .controlSize(.large)
            .disabled(!canDelete)
        }
        .padding(.vertical, 4)
    }

    private func submit() {
        guard canDelete else { return }
        Task {
            await model.delete(
                account: account,
                challenge: challenge,
                isAccountMutationInProgress: isAccountMutationInProgress
            )
        }
    }
}

/// "Type <name> to confirm.", with the name drawn in the primary ink so it reads as the thing to
/// type even where the same name also appears in the surrounding sentence.
enum DeleteProfileConfirmationHint {
    static func text(challenge: String) -> AttributedString {
        let placeholder = "\u{FFFC}"
        var hint = AttributedString(String(format: L10n.string("Type %@ to confirm."), placeholder))
        hint.foregroundColor = WNColor.backgroundContentSecondary
        if let range = hint.range(of: placeholder) {
            var name = AttributedString(challenge)
            name.foregroundColor = WNColor.backgroundContentPrimary
            hint.replaceSubrange(range, with: name)
        }
        return hint
    }
}

#Preview {
    DeleteProfileSettingsView(
        model: .preview(),
        account: AccountItem.samples[0],
        isAccountMutationInProgress: false
    )
    .environment(WorkspaceState.preview())
    .frame(width: 640, height: 820)
}
