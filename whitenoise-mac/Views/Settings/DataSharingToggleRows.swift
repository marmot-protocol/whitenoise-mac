//
//  DataSharingToggleRows.swift
//  whitenoise-mac
//
//  The two Data Sharing choices — anonymous relay telemetry and audit logging — as one pair of
//  rows, shared by Privacy & Security and by the one-time "Help Improve White Noise" prompt.
//
//  Both surfaces offer the same two choices, so they read and write the same way: the switches
//  render from `privacySecuritySettings`, which the setters move optimistically and roll back if
//  the relay write fails. Duplicating the bindings would let the prompt drift into writing the
//  preference some other way — an optimistic move without the rollback, say, or a write that
//  skipped the credentials guard.
//
//  Drawn as `SettingsToggleRow`, the shape every switch in settings takes, so the pair reads on
//  the prompt exactly as it does on the page it is a shortcut to. That row is a `Toggle` and its
//  `Label` and nothing else — it carries no page chrome — so it is equally at home in the
//  prompt's own grouped `Form`. Nothing here explains the toggles: that is the enclosing
//  section's footer on the page, and the prompt's own copy on the sheet.
//

import SwiftUI

struct DataSharingToggleRows: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        SettingsToggleRow(
            title: L10n.string("Anonymous Telemetry"),
            systemImage: "waveform.path.ecg",
            isOn: Binding(
                get: { workspace.privacySecuritySettings.relayTelemetryEnabled },
                set: { enabled in
                    Task { await workspace.setRelayTelemetryEnabled(enabled) }
                }
            )
        )
        .disabled(workspace.isSavingPrivacySecurity)

        SettingsToggleRow(
            title: L10n.string("Audit Logging"),
            systemImage: "doc.text.magnifyingglass",
            isOn: Binding(
                get: { workspace.privacySecuritySettings.auditLoggingEnabled },
                set: { enabled in
                    Task { await workspace.setAuditLoggingEnabled(enabled) }
                }
            )
        )
        .disabled(workspace.isSavingPrivacySecurity)

        if workspace.isSavingPrivacySecurity {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Saving..."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}
