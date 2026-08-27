//
//  PrivacySecuritySettingsView.swift
//  whitenoise-mac
//
//  The Privacy & Security page: relay telemetry and audit logging, both off until they
//  are turned on here, and the rows for the audit-log files themselves.
//

import MarmotKit
import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showDeleteAuditLogsConfirmation = false
    @State private var showDeleteAllDataConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Privacy & Security"),
            subtitle: L10n.string("Telemetry and audit logs stay off until you enable them.")
        ) {
            SettingsSection(
                title: L10n.string("Remote Content"),
                footer: L10n.string(
                    "Off by default. Profile pictures come from URLs other people control, so loading them reveals your IP address and when you're online to whoever sent them. Leave this off unless you trust the senders. Only secure (https) images are ever loaded."
                )
            ) {
                SettingsToggleRow(
                    title: L10n.string("Load Remote Profile Images"),
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    isOn: Binding(
                        get: { workspace.loadRemoteImages },
                        set: { workspace.loadRemoteImages = $0 }
                    )
                )
            }

            // The same rows the one-time "Help Improve White Noise" prompt shows. See
            // `DataSharingToggleRows`.
            SettingsSection(title: L10n.string("Data Sharing")) {
                DataSharingToggleRows()
            }

            SettingsSection(title: L10n.string("Audit Log Files")) {
                HStack {
                    if workspace.isLoadingAuditLogFiles {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await workspace.loadAuditLogFiles() }
                    } label: {
                        Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isLoadingAuditLogFiles)
                }

                if workspace.auditLogFiles.isEmpty {
                    HStack {
                        Spacer()

                        ContentUnavailableView("No audit logs", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: 320)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(workspace.auditLogFiles, id: \.path) { file in
                        AuditLogFileRow(file: file)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.uploadAuditLogFiles() }
                    } label: {
                        Label(
                            workspace.isUploadingAuditLogFiles
                                ? L10n.string("Uploading...") : L10n.string("Upload Now"), systemImage: "arrow.up.doc")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(
                        workspace.isUploadingAuditLogFiles
                            || !workspace.privacySecuritySettings.auditLogCredentialsAvailable
                    )

                    Button(role: .destructive) {
                        showDeleteAuditLogsConfirmation = true
                    } label: {
                        Label(
                            workspace.isDeletingAuditLogFiles ? L10n.string("Deleting...") : L10n.string("Delete All"),
                            systemImage: "trash")
                    }
                    .disabled(workspace.auditLogFiles.isEmpty || workspace.isDeletingAuditLogFiles)
                }

                if let auditLogUploadStatus = workspace.auditLogUploadStatus {
                    SettingsStatusNote(
                        text: auditLogUploadStatus,
                        intention: .success,
                        systemImage: "checkmark.seal"
                    )
                }
            }

            SettingsSection(
                title: L10n.string("Reset"),
                footer: L10n.string("Reset White Noise to a newly installed state on this Mac.")
            ) {
                Button(role: .destructive) {
                    showDeleteAllDataConfirmation = true
                } label: {
                    Label(
                        workspace.isDeletingAllData ? L10n.string("Deleting...") : L10n.string("Delete All Data"),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(WNColor.fillDestructive)
                .disabled(workspace.isAccountMutationInProgress)
            }

        }
        .task {
            await workspace.loadAuditLogFiles()
        }
        .confirmationDialog(
            L10n.string("Delete all audit logs?"),
            isPresented: $showDeleteAuditLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Delete All Audit Logs"), role: .destructive) {
                Task { await workspace.deleteAllAuditLogFiles() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("This permanently removes every local audit JSONL file on this Mac."))
        }
        .alert(L10n.string("Delete all data?"), isPresented: $showDeleteAllDataConfirmation) {
            Button(L10n.string("Delete All Data"), role: .destructive) {
                Task { await workspace.deleteAllData() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "This clears all accounts, chats, and messages from this Mac and resets White Noise to a newly installed state. This cannot be undone."
                )
            )
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
                Text(byteCount(file.sizeBytes))
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

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func shortAccountRef(_ ref: String) -> String {
        let capped = String(ref.prefix(64))
        guard capped.count > 14 else { return capped }
        return "\(capped.prefix(8))...\(capped.suffix(6))"
    }
}
