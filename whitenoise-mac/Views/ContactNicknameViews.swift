//
//  ContactNicknameViews.swift
//  whitenoise-mac
//
//  Set / Edit / Remove a private nickname for one contact: a form row for the direct-message
//  details pane, header controls for a contact's profile, and the one prompt both open.
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
                                .foregroundStyle(WNColor.backgroundContentSecondary)
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
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(2)
                }

                Text(L10n.string("Only you see this on this device. It is never published."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }
            .contactNicknameEditor(
                isPresented: $isEditingNickname, draft: $nicknameDraft, accountIdHex: accountIdHex)
        }
    }
}

/// Set / Edit / Remove beside a contact's name, for the profile header: a pencil, and — while a
/// nickname is in force — a way back to the name they published.
///
/// Icon-only because they sit beside a 20pt title and must not read as part of it; each still
/// carries its title for VoiceOver and as a tooltip.
struct ContactNicknameHeaderActions: View {
    @Environment(WorkspaceState.self) private var workspace

    let accountIdHex: String

    @State private var isEditingNickname = false
    @State private var nicknameDraft = ""

    private var nickname: String? {
        workspace.contactNickname(forContactAccountIdHex: accountIdHex)
    }

    var body: some View {
        if workspace.canSetContactNickname(forContactAccountIdHex: accountIdHex) {
            let editTitle = L10n.string(nickname == nil ? "Set Nickname" : "Edit Nickname")
            HStack(spacing: 6) {
                Button(editTitle, systemImage: "pencil") {
                    nicknameDraft = nickname ?? ""
                    isEditingNickname = true
                }
                .help(editTitle)

                if nickname != nil {
                    Button(L10n.string("Remove Nickname"), systemImage: "xmark.circle") {
                        workspace.setContactNickname(nil, forContactAccountIdHex: accountIdHex)
                    }
                    .help(L10n.string("Remove Nickname"))
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .wnFont(.semiBold14)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .contactNicknameEditor(
                isPresented: $isEditingNickname, draft: $nicknameDraft, accountIdHex: accountIdHex)
        }
    }
}

extension View {
    /// The Set / Edit Nickname prompt. The caller seeds `draft` before presenting it.
    func contactNicknameEditor(
        isPresented: Binding<Bool>,
        draft: Binding<String>,
        accountIdHex: String
    ) -> some View {
        modifier(ContactNicknameEditor(isPresented: isPresented, draft: draft, accountIdHex: accountIdHex))
    }
}

private struct ContactNicknameEditor: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    @Binding var isPresented: Bool
    @Binding var draft: String
    let accountIdHex: String

    func body(content: Content) -> some View {
        let hasNickname = workspace.contactNickname(forContactAccountIdHex: accountIdHex) != nil
        content.alert(
            L10n.string(hasNickname ? "Edit Nickname" : "Set Nickname"),
            isPresented: $isPresented
        ) {
            TextField(L10n.string("Nickname"), text: $draft)
            Button(L10n.string("Save")) {
                // An emptied field is the remove gesture, so Save and Remove converge on one
                // code path in `setContactNickname`.
                workspace.setContactNickname(draft, forContactAccountIdHex: accountIdHex)
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("Only you see this on this device. Clearing it restores their profile name."))
        }
    }
}
