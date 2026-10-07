//
//  ContactNicknameViews.swift
//  whitenoise-mac
//
//  Set / Edit / Remove a private nickname for one contact: a form row for the direct-message
//  details pane, header controls for a contact's profile, and the one sheet both open
//  (`ContactNicknameEditorSheet`).
//

import SwiftUI

struct ContactNicknameRow: View {
    @Environment(WorkspaceState.self) private var workspace

    let accountIdHex: String
    /// The contact's published name, shown as secondary context while a nickname hides it. Pass
    /// nil when nothing is being overridden or no published name has resolved yet.
    let publishedName: String?

    @State private var isEditingNickname = false

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
                isPresented: $isEditingNickname, accountIdHex: accountIdHex, publishedName: publishedName)
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
    /// The contact's published name, restated in the editor while a nickname hides it.
    var publishedName: String?

    @State private var isEditingNickname = false

    private var nickname: String? {
        workspace.contactNickname(forContactAccountIdHex: accountIdHex)
    }

    var body: some View {
        if workspace.canSetContactNickname(forContactAccountIdHex: accountIdHex) {
            let editTitle = L10n.string(nickname == nil ? "Set Nickname" : "Edit Nickname")
            HStack(spacing: 6) {
                Button(editTitle, systemImage: "pencil") {
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
                isPresented: $isEditingNickname, accountIdHex: accountIdHex, publishedName: publishedName)
        }
    }
}

extension View {
    /// The Set / Edit Nickname sheet, seeded with the nickname in force when it opens.
    func contactNicknameEditor(
        isPresented: Binding<Bool>,
        accountIdHex: String,
        publishedName: String?
    ) -> some View {
        modifier(
            ContactNicknameEditor(
                isPresented: isPresented, accountIdHex: accountIdHex, publishedName: publishedName))
    }
}

private struct ContactNicknameEditor: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    @Binding var isPresented: Bool
    let accountIdHex: String
    let publishedName: String?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ContactNicknameEditorSheet(
                currentNickname: workspace.contactNickname(forContactAccountIdHex: accountIdHex),
                publishedName: publishedName
            ) { nickname in
                workspace.setContactNickname(nickname, forContactAccountIdHex: accountIdHex)
            }
            // Sheets are hosted outside this view's hierarchy and inherit nothing from it, so
            // the app-language locale has to be handed over again.
            .environment(\.locale, workspace.preferredLocale)
        }
    }
}
