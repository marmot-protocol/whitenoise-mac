//
//  GroupDetailsTopBar.swift
//  whitenoise-mac
//
//  The strip above group info: back on the leading edge, the page's name centred, and Edit on
//  the trailing edge for whoever may edit the group.
//

import SwiftUI

/// Native header bar for the trailing inspector, contact drill-down, and shared-media library
/// destination (N06, N07, #1042, #1044).
struct GroupDetailsTopBar: View {
    @Environment(\.locale) private var locale
    let title: String
    var isLoading = false
    /// Where the leading button returns to, as a catalog key.
    var backHelp = "Back to chat"
    /// Leading icon symbol. Defaults to `"chevron.backward"` for drill-down/library destinations;
    /// top-level inspector panes pass `"xmark"` to close the inspector.
    var backSymbol = "chevron.backward"
    let onBack: () -> Void
    /// `nil` when the reader may not edit the group.
    let onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Label(L10n.string(backHelp, locale: locale), systemImage: backSymbol)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(L10n.string(backHelp, locale: locale))
            .accessibilityLabel(L10n.string(backHelp, locale: locale))
            .accessibilityIdentifier("details.topbar.back")

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)

            if let onEdit {
                Button(L10n.string("Edit", locale: locale), action: onEdit)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L10n.string("Edit Group Info", locale: locale))
                    .accessibilityIdentifier("details.topbar.edit")
            } else {
                Color.clear
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#Preview("Admin") {
    GroupDetailsTopBar(title: "Group Info", onBack: {}, onEdit: {})
        .frame(width: 320)
}

#Preview("Member, loading") {
    GroupDetailsTopBar(
        title: "Group Info", isLoading: true, backHelp: "Close", backSymbol: "xmark", onBack: {}, onEdit: nil
    )
    .frame(width: 320)
}
