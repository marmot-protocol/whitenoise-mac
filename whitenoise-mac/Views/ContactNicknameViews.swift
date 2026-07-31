//
//  ContactNicknameViews.swift
//  whitenoise-mac
//
//  Set / Edit / Remove a private nickname for one contact. Shared by the contact-details pane
//  and the direct-message details pane so the gesture behaves identically wherever it appears.
//

import SwiftUI

struct ContactNicknameRow: View {
    @Environment(WorkspaceState.self) private var workspace

    let accountIdHex: String
    /// The contact's published name, shown as secondary context while a nickname hides it. Pass
    /// nil when nothing is being overridden or no published name has resolved yet.
    let publishedName: String?

    @State private var isEditingNickname = false
    @State private var nicknameDraft = ""

    private var nickname: String? {
        workspace.contactNickname(forContactAccountIdHex: accountIdHex)
    }

    var body: some View {
        // Absent for one of this device's own accounts: a local account's own label wins, so
        // there is no override to offer rather than a dead control.
        if workspace.canSetContactNickname(forContactAccountIdHex: accountIdHex) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(L10n.string("Nickname")) {
                    HStack(spacing: 10) {
                        if let nickname {
                            Text(nickname)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(L10n.string("None"))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(nickname == nil ? L10n.string("Set…") : L10n.string("Edit…")) {
                            nicknameDraft = nickname ?? ""
                            isEditingNickname = true
                        }

                        if nickname != nil {
                            Button(L10n.string("Remove"), role: .destructive) {
                                workspace.setContactNickname(nil, forContactAccountIdHex: accountIdHex)
                            }
                        }
                    }
                }

                // Never let a private label be silently mistaken for what the contact calls
                // themselves: while a nickname is in force, the published name stays visible.
                if nickname != nil, let publishedName {
                    Text(
                        String(
                            format: L10n.string("Name from profile: %@"),
                            PeerDisplayText.templateFragment(publishedName)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }

                Text(L10n.string("Only you see this on this device. It is never published."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .alert(
                nickname == nil ? L10n.string("Set Nickname") : L10n.string("Edit Nickname"),
                isPresented: $isEditingNickname
            ) {
                TextField(L10n.string("Nickname"), text: $nicknameDraft)
                Button(L10n.string("Save")) {
                    // An emptied field is the remove gesture, so Save and Remove converge on one
                    // code path in `setContactNickname`.
                    workspace.setContactNickname(nicknameDraft, forContactAccountIdHex: accountIdHex)
                }
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("Only you see this on this device. Clearing it restores their profile name."))
            }
        }
    }
}
