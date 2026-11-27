//
//  DetailsDestructiveRow.swift
//  whitenoise-mac
//
//  A full-width red row at the foot of group info: Leave, Remove From This Device.
//

import SwiftUI

/// A terminal destructive action drawn as a native grouped-form row with `.destructive` role
/// semantics (C04, S07, #1042).
struct DetailsDestructiveRow: View {
    let title: String
    let systemImage: String
    var isInProgress = false
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
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
