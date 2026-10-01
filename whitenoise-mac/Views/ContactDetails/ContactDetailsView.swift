//
//  ContactDetailsView.swift
//  whitenoise-mac
//
//  A contact's profile: the pane that slides in over a conversation or group info. Laid out after
//  the iOS client's `ProfileContentView` — identity and actions, then shared groups and blocking.
//

import SwiftUI

struct ContactDetailsView: View {
    @Environment(WorkspaceState.self) private var workspace
    let contact: NewChatRecipient
    let blockedUsersModel: BlockedUsersViewModel

    private var isLocalProfile: Bool {
        workspace.accounts.contains {
            $0.accountIdHex.lowercased() == contact.accountIdHex.lowercased()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupDetailsTopBar(
                title: L10n.string("Profile"),
                isLoading: workspace.isLoadingContactDetails,
                backHelp: "Back",
                onBack: { workspace.closeContactDetails() },
                onEdit: nil
            )

            GlassSeparator(axis: .horizontal)

            Form {
                ContactIdentitySection(
                    contact: contact,
                    isLocalProfile: isLocalProfile,
                    isBlocked: blockedUsersModel.isBlocked(accountID: contact.accountIdHex)
                )

                if workspace.lastError != nil {
                    Section {
                        SettingsErrorView(error: workspace.lastError)
                    }
                }

                GroupsInCommonSection()

                if !isLocalProfile {
                    ContactBlockingSection(model: blockedUsersModel, accountID: contact.accountIdHex)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}
