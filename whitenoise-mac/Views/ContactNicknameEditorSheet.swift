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
/// sheet here wears — `AddRelaySheet`'s header, `WNInput`, and a `.wnSecondary` / `WNPrimaryButton`
/// footer — in pills, so the field and the button that submits it share a shape.
///
/// It owns its own draft and reports a decision through `onSave`, so it never reads the workspace.
struct ContactNicknameEditorSheet: View {
    /// The nickname in force when the sheet opened, or nil when there is none.
    let currentNickname: String?
    /// What the contact calls themselves, kept visible so a private label is never mistaken for it.
    let publishedName: String?
    /// The nickname to store, or nil to remove it.
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(currentNickname: String?, publishedName: String?, onSave: @escaping (String?) -> Void) {
        self.currentNickname = currentNickname
        self.publishedName = publishedName
        self.onSave = onSave
        _draft = State(initialValue: currentNickname ?? "")
    }

    /// The draft as it would be stored. An emptied field is the remove gesture, the same rule the
    /// alert this replaced followed.
    private var sanitizedDraft: String? {
        ContactNicknames.sanitized(draft)
    }

    private var canSave: Bool {
        Self.canSave(draft: draft, currentNickname: currentNickname)
    }

    /// Save is offered only when it would store something different — compared as stored, so
    /// padding a name with spaces is not an edit, and emptying a nickname is.
    static func canSave(draft: String, currentNickname: String?) -> Bool {
        ContactNicknames.sanitized(draft) != ContactNicknames.sanitized(currentNickname)
    }

    var body: some View {
        VStack(spacing: 0) {
            ContactNicknameEditorHeader(
                title: L10n.string(currentNickname == nil ? "Set Nickname" : "Edit Nickname"),
                onClose: { dismiss() }
            )

            VStack(alignment: .leading, spacing: 12) {
                WNInput(
                    label: L10n.string("Nickname"),
                    prompt: publishedName ?? L10n.string("Nickname"),
                    text: $draft
                )
                .onSubmit(save)

                ContactNicknameEditorNotes(
                    publishedName: currentNickname == nil ? nil : publishedName
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)

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
        .wnButtonShape(.capsule)
    }

    private func save() {
        guard canSave else { return }
        finish(with: sanitizedDraft)
    }

    private func finish(with nickname: String?) {
        dismiss()
        onSave(nickname)
    }
}

private struct ContactNicknameEditorHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .wnFont(.semiBold16)
            Spacer()
            GlassCircleCloseButton(appearance: .outline, action: onClose)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(2)
            }

            Label {
                Text(L10n.string("Only you see this on this device. Clearing it restores their profile name."))
            } icon: {
                Image(systemName: "lock.fill")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(WNColor.backgroundContentTertiary)
        }
        .wnFont(.medium12)
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
            // Leading and apart from the Cancel / Save pair, so the one action that throws the
            // nickname away is never the button a reader's eye lands on last.
            if canRemove {
                Button(L10n.string("Remove"), action: onRemove)
                    .buttonStyle(.wnSecondary)
            }

            Spacer()

            Button(L10n.string("Cancel"), action: onCancel)
                .buttonStyle(.wnSecondary)
                .keyboardShortcut(.cancelAction)

            WNPrimaryButton(size: .small, action: onSave) {
                Text(L10n.string("Save")).frame(minWidth: 72)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

#Preview("Set") {
    ContactNicknameEditorSheet(currentNickname: nil, publishedName: "Satoshi", onSave: { _ in })
}

#Preview("Edit") {
    ContactNicknameEditorSheet(currentNickname: "Sats", publishedName: "Satoshi Nakamoto", onSave: { _ in })
}
