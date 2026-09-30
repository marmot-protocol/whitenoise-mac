//
//  GroupDetailsAdvancedSection.swift
//  whitenoise-mac
//
//  Group info's Advanced: the relays the group publishes to, and its id.
//

import SwiftUI

/// The two pieces of technical detail iOS keeps on its details page — the group's relays and
/// its id — without the developer section's full diagnostic dump.
struct GroupDetailsAdvancedSection: View {
    let relays: [String]
    let groupIdHex: String

    var body: some View {
        Section(L10n.string("Advanced")) {
            DisclosureGroup {
                ForEach(relays, id: \.self) { relay in
                    Text(relay)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } label: {
                LabeledContent {
                    Text(relays.count, format: .number)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                } label: {
                    Label(L10n.string("Relays"), systemImage: "network")
                }
            }

            GroupDiagnosticsValueRow(title: L10n.string("Group ID"), value: groupIdHex)
        }
    }
}

#Preview {
    Form {
        GroupDetailsAdvancedSection(
            relays: ["wss://relay.damus.io", "wss://nos.lol"],
            groupIdHex: "8f3c1a0b9e2d4c6f8a1b3c5d7e9f0a2b4c6d8e0f1a3b5c7d9e1f3a5b7c9d1e3f"
        )
    }
    .formStyle(.grouped)
    .environment(WorkspaceState.preview())
    .frame(width: 480, height: 260)
}
