//
//  DataSharingToggleRows.swift
//  whitenoise-mac
//
//  The two Data Sharing choices — anonymous relay telemetry and audit logging — as rows shared by
//  Privacy & Security and by the one-time "Help Improve White Noise" prompt.
//
//  Both surfaces offer the same two choices, so they read and write the same way: the switches
//  render from `privacySecuritySettings`, which the setters move optimistically and roll back if
//  the relay write fails. Duplicating the bindings would let the prompt drift into writing the
//  preference some other way — an optimistic move without the rollback, say, or a write that
//  skipped the credentials guard.
//
//  Each row is offered separately as well as together, because the two surfaces group them
//  differently. The prompt asks both questions at once inside one card, so it takes the pair. The
//  settings page gives each choice a group of its own so each can carry the footer that explains
//  it — a single footer under both would have to describe two independent choices in one
//  paragraph. Same rows either way, so the two surfaces cannot drift apart.
//
//  Drawn as `WNToggle`, the app's switch, so a row reads on the prompt exactly as it does on the
//  page it is a shortcut to. That component is a switch and its `Label` and nothing else — it
//  carries no page chrome — so it is equally at home in the prompt's own grouped `Form`, and it
//  names its own `fillPrimary` tint rather than inheriting one, which is what keeps the sheet's
//  copy of these two switches off the blue system accent. Nothing here explains the toggles: that
//  is the enclosing section's footer on the page, and the prompt's own copy on the sheet.
//

import SwiftUI

struct AnonymousTelemetryToggleRow: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        WNToggle(
            L10n.string("Anonymous Telemetry"),
            systemImage: "waveform.path.ecg",
            isOn: Binding(
                get: { workspace.privacySecuritySettings.relayTelemetryEnabled },
                set: { enabled in
                    Task { await workspace.setRelayTelemetryEnabled(enabled) }
                }
            )
        )
        .disabled(workspace.isSavingPrivacySecurity)
    }
}

struct AuditLoggingToggleRow: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        WNToggle(
            L10n.string("Audit Logging"),
            systemImage: "doc.text.magnifyingglass",
            isOn: Binding(
                get: { workspace.privacySecuritySettings.auditLoggingEnabled },
                set: { enabled in
                    Task { await workspace.setAuditLoggingEnabled(enabled) }
                }
            )
        )
        .disabled(workspace.isSavingPrivacySecurity)
    }
}

/// Both choices in reading order, for the prompt, which asks them together in one card.
struct DataSharingToggleRows: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        AnonymousTelemetryToggleRow()
        AuditLoggingToggleRow()

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
