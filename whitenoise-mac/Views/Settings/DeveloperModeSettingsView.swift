//
//  DeveloperModeSettingsView.swift
//  whitenoise-mac
//
//  The Developer mode page: the storage, diagnostics and KeyPackages only a developer needs.
//

import AppKit
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

struct DeveloperModeSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    let model: DiagnosticsSettingsViewModel

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Developer mode"),
            subtitle: L10n.string("Storage and diagnostics.")
        ) {
            SettingsSection(title: L10n.string("Developer")) {
                WNToggle(
                    L10n.string("Developer mode"),
                    systemImage: "stethoscope",
                    isOn: $workspace.developerMode
                )

                WNToggle(
                    L10n.string("Streaming debug"),
                    systemImage: "waveform.path.ecg",
                    isOn: $workspace.streamingDebugMode
                )
                .disabled(!workspace.developerMode)
            }

            // Key Packages is a destination of this page rather than a drawer row beside
            // Profile and Relays, and it is hidden rather than disabled while the master
            // toggle is off. Both are `wn-ios-prototype`'s: it keeps Key Packages as an
            // isolated navigation row inside Developer Tools, and its technical sections do
            // not appear at all until Developer Tools is enabled for the profile.
            if workspace.developerMode {
                SettingsSection {
                    SettingsNavigationRow(page: .keyPackages)
                    SettingsNavigationRow(page: .quarantinedGroups)
                }
            }

            // The path sits under the button that opens it rather than in a row of its own: it
            // is what the group is about, not a setting beside one. Selectable, because a
            // developer reading this page wants it in a terminal.
            SettingsSection(
                title: L10n.string("Storage"),
                footer: workspace.storageRootPath,
                isFooterSelectable: true
            ) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.storageRootPath, isDirectory: true))
                } label: {
                    Label(L10n.string("Open Storage Folder"), systemImage: "folder")
                }
                .buttonStyle(.wnSecondary)
            }

            SettingsSection(title: L10n.string("Diagnostics")) {
                ForEach(workspace.diagnosticsInfo) { item in
                    SettingsValueRow(title: item.title, value: item.value, isSelectable: true)
                }
            }

            AuditLogFilesSection(model: model)

            AuditDeliveryStatusSection(model: model.delivery)

        }
    }
}

/// Every account's v5 audit delivery figures (MarmotKit 0.16.0), for working out why logs are not
/// arriving. Privacy & Security shows the one-line summary of the same data.
struct AuditDeliveryStatusSection: View {
    let model: AuditDeliveryStatusViewModel

    var body: some View {
        SettingsSection(
            title: L10n.string("Audit Delivery"),
            footer: L10n.string(
                "Read from this Mac's delivery records. Upload Now on Privacy & Security resumes a paused account.")
        ) {
            Button {
                Task { await model.load() }
            } label: {
                Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.wnSecondary)

            // After a failed read the error below says what happened; "no records" would not be true.
            if model.statuses.isEmpty, model.error == nil {
                Text(L10n.string("No delivery records yet."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(model.statuses, id: \.accountRef) { status in
                    AuditDeliveryStatusRows(status: status)
                }
            }

            if let error = model.error {
                SettingsErrorView(error: error)
            }
        }
    }
}

/// One account's delivery figures.
struct AuditDeliveryStatusRows: View {
    let status: AuditDeliveryStatusV5Ffi

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsValueRow(
                title: L10n.string("Account"),
                value: status.accountRef,
                monospaced: true,
                truncatesMiddle: true,
                isSelectable: true
            )
            SettingsValueRow(title: L10n.string("Destination"), value: destination)
            SettingsValueRow(title: L10n.string("Last success"), value: Self.relative(status.lastSuccessAtMs))
            if let failure = status.lastFailure {
                SettingsValueRow(title: L10n.string("Last failure"), value: Self.failure(failure))
            }
            SettingsValueRow(
                title: L10n.string("Consecutive failures"), value: String(status.consecutiveFailures), monospaced: true)
            SettingsValueRow(
                title: L10n.string("Rejected batches"), value: String(status.rejectedBatches), monospaced: true)
            if let backlog = status.backlog {
                SettingsValueRow(
                    title: L10n.string("Undelivered"),
                    value: "\(AuditLogByteCount.string(backlog.undeliveredBytes)) · \(backlog.undeliveredSegments) · "
                        + "\(backlog.gaps)",
                    monospaced: true
                )
                .help(L10n.string("Bytes · segments · gaps"))
                if let oldest = backlog.oldestUndeliveredAtMs {
                    SettingsValueRow(title: L10n.string("Oldest undelivered"), value: Self.relative(oldest))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var destination: String {
        guard status.destinationConfigured else { return L10n.string("Not configured") }
        return status.paused ? L10n.string("Paused") : L10n.string("Sending")
    }

    private static func relative(_ ms: UInt64?) -> String {
        guard let ms else { return L10n.string("Never") }
        return Date(unixMilliseconds: ms).formatted(.relative(presentation: .named).locale(AppLanguage.currentLocale))
    }

    private static func failure(_ failure: AuditDeliveryFailureV5Ffi) -> String {
        var parts = [AuditDeliveryFailurePresentation.label(failure.kind)]
        if let http = failure.httpStatus {
            parts.append("HTTP \(http)")
        }
        parts.append(relative(failure.atMs))
        return parts.joined(separator: " · ")
    }
}

#Preview("Audit delivery") {
    Form {
        AuditDeliveryStatusSection(
            model: .preview([
                AuditDeliveryStatusV5Ffi(
                    accountRef: "npub1preview",
                    destinationConfigured: true,
                    lastSuccessAtMs: 1_800_000_000_000,
                    lastFailure: AuditDeliveryFailureV5Ffi(
                        kind: .receiverBlocked, httpStatus: 401, atMs: 1_800_000_100_000),
                    consecutiveFailures: 3,
                    rejectedBatches: 1,
                    paused: true,
                    backlog: AuditDeliveryBacklogV5Ffi(
                        undeliveredBytes: 4_200_000,
                        undeliveredSegments: 12,
                        gaps: 0,
                        oldestUndeliveredAtMs: 1_799_990_000_000,
                        observedAtMs: 1_800_000_100_000
                    )
                )
            ])
        )
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 520)
}

/// The audit-log files themselves: names, sizes, timestamps and paths.
///
/// This is here rather than on Privacy & Security because of what the two pages are for.
/// Privacy & Security answers "how much is stored, and can I get rid of it" — it reports the
/// combined size and owns the clear action. What each file is called and where it sits on disk
/// answers a different question, one only somebody about to open a terminal is asking, and
/// putting it on the privacy page buried the choice under an inventory. Turning logging on and
/// off, and clearing what it wrote, stay on Privacy & Security; this group only looks.
struct AuditLogFilesSection: View {
    let model: DiagnosticsSettingsViewModel
    @State private var exportingPath: String?
    @State private var exportError: String?

    var body: some View {
        SettingsSection(
            title: L10n.string("Audit Log Files"),
            footer: L10n.string("Turn audit logging on or off, and clear these files, in Privacy & Security.")
        ) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.loadAuditLogs() }
                } label: {
                    SettingsBusyLabel(
                        title: L10n.string("Refresh"),
                        systemImage: "arrow.clockwise",
                        isBusy: model.isLoadingAuditLogs
                    )
                }
                .buttonStyle(.wnSecondary)
                .disabled(model.isLoadingAuditLogs)

                if DiagnosticLogExport.latestFile(in: model.auditLogFiles) != nil {
                    Button {
                        Task { await exportLog(path: nil) }
                    } label: {
                        SettingsBusyLabel(
                            title: L10n.string("Export"),
                            systemImage: "square.and.arrow.up",
                            isBusy: exportingPath == ""
                        )
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(exportingPath != nil)
                }
            }

            if model.auditLogFiles.isEmpty {
                Text(L10n.string("There are no logs."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(model.auditLogFiles, id: \.path) { file in
                    HStack(spacing: 10) {
                        AuditLogFileRow(file: file)
                        Button {
                            Task { await exportLog(path: file.path) }
                        } label: {
                            if exportingPath == file.path {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(file.sizeBytes == 0 || exportingPath != nil)
                        .help("\(L10n.string("Export")) \(file.fileName)")
                    }
                }
            }

            if let exportError {
                SettingsErrorView(error: exportError)
            }
        }
        .task {
            await model.loadAuditLogs()
        }
    }

    private func exportLog(path: String?) async {
        guard exportingPath == nil else { return }
        exportingPath = path ?? ""
        defer { exportingPath = nil }
        do {
            let snapshot = try await model.diagnosticLogExport(path: path)
            let panel = NSSavePanel()
            panel.title = L10n.string("Export")
            panel.prompt = L10n.string("Export")
            panel.nameFieldStringValue = snapshot.fileName
            panel.allowedContentTypes = [.json, .plainText, .data]
            panel.allowsOtherFileTypes = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try snapshot.data.write(to: url, options: .atomic)
            exportError = nil
        } catch is CancellationError {
            return
        } catch {
            exportError = L10n.string("Something went wrong")
        }
    }
}

struct AuditLogFileRow: View {
    let file: AuditLogFileFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(file.fileName)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(AuditLogByteCount.string(file.sizeBytes))
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            Text(details)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)

            Text(file.path)
                .font(.caption2.monospaced())
                .foregroundStyle(WNColor.backgroundContentTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        var parts = [shortAccountRef(file.accountRef)]
        if let modifiedAtMs = file.modifiedAtMs {
            let date = Date(timeIntervalSince1970: TimeInterval(modifiedAtMs) / 1_000)
            parts.append(DisplayText.dateTimeTimestamp(for: date))
        }
        return parts.joined(separator: " - ")
    }

    private func shortAccountRef(_ ref: String) -> String {
        let capped = String(ref.prefix(64))
        guard capped.count > 14 else { return capped }
        return "\(capped.prefix(8))...\(capped.suffix(6))"
    }
}

#Preview {
    DeveloperModeSettingsView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 640)
}
