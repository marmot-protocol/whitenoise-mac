//
//  GroupProfileEditorSheet.swift
//  whitenoise-mac
//
//  Editing a group's name and description, opened from group info's Edit menu or its
//  "Add Description" link. Ported from the iOS client's "Edit Group Info" sheet.
//

import SwiftUI

/// The group's name and description, and the Save that publishes them to everyone in it.
///
/// Group info used to carry these as two always-live text fields in the middle of the page, so
/// the first thing a member saw of a group was a form. The iOS client keeps them behind Edit, and
/// so does this: the page reads as the group, and the edit is one click away for whoever may.
struct GroupProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var name: String
    @Binding var description: String
    let isSaving: Bool
    let canSave: Bool
    let error: String?
    /// Publishes the drafts; answers whether they were saved, so the sheet only closes on success
    /// and a failure stays on screen beside the text that caused it.
    let onSave: () async -> Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string("Edit Group Info"))
                .wnFont(.semiBold14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Form {
                SettingsSection(
                    footer: L10n.string(
                        "Everyone in the group will see this name and description. Leave the description blank to remove it."
                    )
                ) {
                    TextField(L10n.string("Group name"), text: $name)
                    TextField(L10n.string("Description"), text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    SettingsErrorView(error: error)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .disabled(isSaving)

            HStack(spacing: 10) {
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(L10n.string("Cancel"), role: .cancel) { dismiss() }
                    .buttonStyle(.wnSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Save")) {
                    Task {
                        if await onSave() { dismiss() }
                    }
                }
                .wnPrimaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 440)
        .interactiveDismissDisabled(isSaving)
    }
}

#Preview {
    @Previewable @State var name = "Design Crew"
    @Previewable @State var description = ""

    GroupProfileEditorSheet(
        name: $name,
        description: $description,
        isSaving: false,
        canSave: true,
        error: nil,
        onSave: { true }
    )
}
