import MarmotKit
import SwiftUI

struct BlockedUsersSettingsView: View {
    let model: BlockedUsersViewModel?

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Blocked Users"),
            back: SettingsBackDestination(
                route: .page(.privacySecurity),
                help: "Back to settings"
            )
        ) {
            SettingsSection(
                footer: L10n.string(
                    "Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained."
                )
            ) {
                if model?.users.isEmpty != false {
                    Label(L10n.string("No blocked users"), systemImage: "checkmark.shield")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                } else {
                    ForEach(model?.users ?? [], id: \.publicKey) { user in
                        BlockedUserSettingsRow(
                            user: user,
                            isSaving: model?.mutatingUserIDs.contains(user.publicKey.lowercased()) == true,
                            onUnblock: {
                                Task { await model?.setBlocked(false, accountID: user.publicKey) }
                            }
                        )
                    }
                }
            }

            if let error = model?.error {
                SettingsSection {
                    SettingsErrorView(error: error)
                }
            }
        }
    }
}

private struct BlockedUserSettingsRow: View {
    let user: BlockedUserFfi
    let isSaving: Bool
    let onUnblock: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .wnFont(.medium18)

            Text(DisplayText.short(user.publicKey, head: 12, tail: 8))
                .font(.callout.monospaced())
                .textSelection(.enabled)

            Spacer(minLength: 12)

            Button(action: onUnblock) {
                SettingsBusyLabel(
                    title: L10n.string("Unblock User"),
                    systemImage: "person.crop.circle.badge.checkmark",
                    isBusy: isSaving
                )
            }
            .wnSecondaryButtonStyle()
            .disabled(isSaving)
        }
    }
}

#Preview {
    BlockedUsersSettingsView(model: nil)
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 640)
}
