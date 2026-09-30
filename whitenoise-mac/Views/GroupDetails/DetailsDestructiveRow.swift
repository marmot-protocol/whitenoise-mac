//
//  DetailsDestructiveRow.swift
//  whitenoise-mac
//
//  A full-width red row at the foot of group info: Leave, Remove From This Device.
//

import SwiftUI

/// A destructive action drawn as a form row rather than a button, the way iOS closes its
/// details page. The whole row is the target.
///
/// Red text on a plain row, like `SettingsSignOutRow`, because the row only opens the decision:
/// the irreversible step is the confirmation it presents, which is where red belongs. Carries no
/// `.destructive` role — the red is named here, so a style that later reads the role cannot
/// recolour rows that were deliberately left quiet. Something reversible, like stepping down as
/// admin, is not this row.
struct DetailsDestructiveRow: View {
    let title: String
    let systemImage: String
    var isInProgress = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 0)
                if isInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .foregroundStyle(WNColor.backgroundContentDestructive)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Form {
        Section {
            DetailsDestructiveRow(title: "Leave Group", systemImage: "rectangle.portrait.and.arrow.right") {}
            DetailsDestructiveRow(
                title: "Leaving...", systemImage: "rectangle.portrait.and.arrow.right", isInProgress: true
            ) {}
        }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 140)
}
