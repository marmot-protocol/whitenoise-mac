//
//  DetailsDisclosureRow.swift
//  whitenoise-mac
//
//  A group info row that opens something: its name, its current value, and a chevron.
//

import SwiftUI

/// A form row that opens a chooser — the name on the leading edge, the current value and a
/// chevron on the trailing one, and the whole row as the target. iOS builds its Settings rows
/// this way (`settingsRow`), so the value is read in the same place it is changed from.
///
/// A row the reader may not change drops the chevron and reads as a plain value, rather than as
/// a disabled control.
struct DetailsDisclosureRow: View {
    let title: String
    let systemImage: String
    let value: String
    /// `nil` makes the row read-only.
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                content(showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            content(showsChevron: false)
        }
    }

    private func content(showsChevron: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .wnFont(.semiBold10)
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .contentShape(.rect)
    }
}

#Preview {
    Form {
        Section {
            DetailsDisclosureRow(title: "Disappearing messages", systemImage: "timer", value: "1 day") {}
            DetailsDisclosureRow(title: "Relays", systemImage: "network", value: "3", action: nil)
        }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 160)
}
