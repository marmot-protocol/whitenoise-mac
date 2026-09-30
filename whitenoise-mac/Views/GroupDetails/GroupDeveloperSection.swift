//
//  GroupDeveloperSection.swift
//  whitenoise-mac
//
//  Group info's developer-mode section: transcript export and the raw group state.
//

import SwiftUI

struct GroupDeveloperSection: View {
    @Environment(WorkspaceState.self) private var workspace
    let snapshot: GroupDetailsSnapshot

    var body: some View {
        Section(L10n.string("Developer")) {
            HStack(spacing: 10) {
                Button {
                    workspace.startExportSelectedGroupTranscript()
                } label: {
                    Label(
                        workspace.isExportingGroupTranscript
                            ? L10n.string("Exporting Transcript…")
                            : L10n.string("Export Transcript…"),
                        systemImage: "square.and.arrow.down"
                    )
                }
                .disabled(workspace.isExportingGroupTranscript)

                if workspace.isExportingGroupTranscript {
                    ProgressView()
                        .controlSize(.small)
                    Button(L10n.string("Cancel"), role: .cancel) {
                        workspace.cancelGroupTranscriptExport()
                    }
                } else if let status = workspace.groupTranscriptExportStatus {
                    Label(status, systemImage: "checkmark.circle")
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.intentionSuccessContent)
                }
            }

            GroupDiagnosticsValueRow(title: L10n.string("Group ID"), value: snapshot.groupIdHex)
            GroupDiagnosticsValueRow(
                title: L10n.string("Nostr group ID"), value: snapshot.nostrGroupIdHex)
            GroupDiagnosticsValueRow(title: L10n.string("Endpoint"), value: snapshot.endpoint)
            GroupDiagnosticsValueRow(title: L10n.string("Avatar URL"), value: snapshot.avatarURL ?? "")
            GroupDiagnosticsValueRow(
                title: L10n.string("Avatar dimension"), value: snapshot.avatarDimension ?? "")
            GroupDiagnosticsValueRow(
                title: L10n.string("Relays"), value: snapshot.relays.joined(separator: "\n"),
                lineLimit: 4)
            GroupDiagnosticsValueRow(
                title: L10n.string("Admins"), value: snapshot.adminIds.joined(separator: "\n"),
                lineLimit: 4)
            GroupDiagnosticsValueRow(
                title: L10n.string("Self admin"),
                value: snapshot.isSelfAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
            GroupDiagnosticsValueRow(
                title: L10n.string("Last admin"),
                value: snapshot.isLastAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
            GroupDiagnosticsValueRow(
                title: L10n.string("Can invite"),
                value: snapshot.canInvite ? L10n.string("Yes") : L10n.string("No"),
                copyable: false)
            GroupDiagnosticsValueRow(
                title: L10n.string("Can leave"),
                value: snapshot.canLeave ? L10n.string("Yes") : L10n.string("No"),
                copyable: false)
            GroupDiagnosticsValueRow(
                title: L10n.string("Leave request pending"),
                value: snapshot.leaveRequestPending ? L10n.string("Yes") : L10n.string("No"),
                copyable: false)
            GroupDiagnosticsValueRow(
                title: L10n.string("Leave requested at (ms)"),
                value: snapshot.leaveRequestedAtMs.map(String.init) ?? "",
                copyable: false)
            GroupDiagnosticsValueRow(
                title: L10n.string("Pending confirmation"),
                value: snapshot.pendingConfirmation ? L10n.string("Yes") : L10n.string("No"),
                copyable: false)
            GroupDiagnosticsValueRow(
                title: L10n.string("Self membership"),
                value: snapshot.selfMembership.sidebarBadgeLabel ?? L10n.string("Member"),
                copyable: false)
        }
    }
}
