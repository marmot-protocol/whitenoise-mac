import MarmotKit
import SwiftUI

/// The two device-wide diagnostics decisions share one feature model on both the settings page
/// and the first-run prompt. MarmotKit owns the usage consent receipt; audit-log recording remains
/// an independent choice because it controls durable group diagnostics on this Mac.
///
/// Each switch says what it shares in its own row, in the words iOS uses, so the reader does not
/// have to find the explanation in a footer that describes both at once.
struct DataSharingToggleRows: View {
    let model: DiagnosticsSettingsViewModel

    var body: some View {
        WNToggle(
            isOn: Binding(
                get: { model.settings?.decision == .granted },
                set: { enabled in Task { await model.setEnabled(enabled) } }
            )
        ) {
            DataSharingToggleLabel(
                title: L10n.string("Share usage and telemetry"),
                detail: L10n.string(
                    "Automatically shares feature-use counts and app performance with White Noise."
                ),
                systemImage: "waveform.path.ecg"
            )
        }
        .disabled(model.settings == nil || model.isLoading || model.isSavingUsage)

        WNToggle(
            isOn: Binding(
                get: { model.auditSettings?.enabled == true },
                set: { enabled in Task { await model.setAuditEnabled(enabled) } }
            )
        ) {
            DataSharingToggleLabel(
                title: L10n.string("Share group diagnostic logs"),
                detail: L10n.string(
                    "Automatically shares technical group logs, including group and message identifiers. May include logs already on this device."
                ),
                systemImage: "doc.text.magnifyingglass"
            )
        }
        .disabled(model.auditSettings == nil || model.isLoading || model.isSavingAudit)

        if model.isSavingUsage || model.isSavingAudit {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Saving..."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}

#Preview {
    Form {
        DataSharingToggleRows(model: .preview())
    }
    .frame(width: 520, height: 240)
}
