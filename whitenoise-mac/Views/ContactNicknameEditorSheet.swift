//
//  ContactNicknameEditorSheet.swift
//  whitenoise-mac
//
//  Set / Edit / Remove a contact's private nickname: the iOS client's nickname prompt, drawn as a
//  sheet in the app's own controls instead of a system alert.
//

import SwiftUI

/// The nickname prompt: one labelled field, the privacy promise under it, and Save.
///
/// The copy is iOS's `ContactNicknameRow` alert word for word; the chrome is the one every small
/// sheet here wears — `AddRelaySheet`'s header, `WNInput`, and a `.wnSecondaryButtonStyle()` /
/// `WNPrimaryButton` footer — in pills, so the field and the button that submits it share a shape.
///
/// It owns its own draft and reports a decision through `onSave`, so it never reads the workspace.
struct ContactNicknameEditorSheet: View {
    /// What the contact calls themselves, kept visible so a private label is never mistaken for it.
    let publishedName: String?
    /// The nickname to store, or nil to remove it.
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The nickname in force when the sheet opened, or nil when there is none. Held as state, not
    /// re-read from the caller: Save writes the store while the sheet is still animating out, and
    /// a live value would flip the closing sheet to Edit, with a Remove button, for a frame.
    @State private var currentNickname: String?
    @State private var draft: String

    init(currentNickname: String?, publishedName: String?, onSave: @escaping (String?) -> Void) {
        self.publishedName = publishedName
        self.onSave = onSave
        _currentNickname = State(initialValue: currentNickname)
        _draft = State(initialValue: currentNickname ?? "")
    }

    private var canSave: Bool {
        Self.canSave(draft: draft, currentNickname: currentNickname)
    }

    /// What Save hands `onSave`: the draft as it would be stored, or nil to remove the nickname.
    /// An emptied field is the remove gesture, the same rule the alert this replaced followed.
    static func nicknameToStore(draft: String) -> String? {
        ContactNicknames.sanitized(draft)
    }

    /// Save is offered only when it would store something different — compared as stored, so
    /// padding a name with spaces is not an edit, and emptying a nickname is.
    static func canSave(draft: String, currentNickname: String?) -> Bool {
        nicknameToStore(draft: draft) != ContactNicknames.sanitized(currentNickname)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string(currentNickname == nil ? "Set Nickname" : "Edit Nickname"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Form {
                Section {
                    TextField(
                        L10n.string("Nickname"),
                        text: $draft,
                        prompt: Text(publishedName ?? L10n.string("Nickname"))
                    )
                    .onSubmit(save)
                } footer: {
                    ContactNicknameEditorNotes(
                        publishedName: currentNickname == nil ? nil : publishedName
                    )
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            ContactNicknameEditorFooter(
                canSave: canSave,
                canRemove: currentNickname != nil,
                onRemove: { finish(with: nil) },
                onCancel: { dismiss() },
                onSave: save
            )
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        guard canSave else { return }
        finish(with: Self.nicknameToStore(draft: draft))
    }

    private func finish(with nickname: String?) {
        dismiss()
        onSave(nickname)
    }
}

/// The two promises under the field: whose name this hides, and who can see it.
private struct ContactNicknameEditorNotes: View {
    let publishedName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let publishedName {
                Text(
                    String(
                        format: L10n.string("Name from profile: %@"),
                        PeerDisplayText.templateFragment(publishedName)
                    )
                )
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Label {
                Text(L10n.string("Only you see this on this device. Clearing it restores their profile name."))
            } icon: {
                Image(systemName: "lock.fill")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContactNicknameEditorFooter: View {
    let canSave: Bool
    let canRemove: Bool
    let onRemove: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Leading and apart from the Cancel / Save pair, so removing the nickname is never
            // confused with the primary completion button.
            if canRemove {
                Button(L10n.string("Remove"), role: .destructive, action: onRemove)
                    .wnSecondaryButtonStyle()
            }

            Spacer()

            Button(L10n.string("Cancel"), role: .cancel, action: onCancel)
                .wnSecondaryButtonStyle()
                .keyboardShortcut(.cancelAction)

            Button(L10n.string("Save"), action: onSave)
                .wnPrimaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .wnSheetFooterButtons()
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

#Preview("Set") {
    ContactNicknameEditorSheet(currentNickname: nil, publishedName: "Satoshi", onSave: { _ in })
}

#Preview("Edit") {
    ContactNicknameEditorSheet(currentNickname: "Sats", publishedName: "Satoshi Nakamoto", onSave: { _ in })
}
