//
//  PrivacySecuritySettingsView.swift
//  whitenoise-mac
//
//  The Privacy & Security page: the three things this Mac can be asked to give up — profile
//  pictures fetched from strangers' servers, optional diagnostics sent to White Noise, and
//  the local data itself.
//
//  Laid out after `wn-ios-prototype`'s Privacy & Security (`docs/screens/settings.md` and
//  `docs/screens/diagnostics-and-improvements.md`): one decision per group, each explained by its
//  own footer, with **Device Data** last because erasure is the end of the page in every sense.
//  The prototype's App Security group — app-switcher masking and Face ID — has no macOS
//  counterpart and is deliberately not ported.
//
//  The two data-sharing switches used to sit in a "Data Sharing" group with the audit-log file
//  inventory beside them in a group of its own, which read as two unrelated features. They are one
//  feature — **Diagnostics & Improvements**, the same pair the one-time prompt offers — followed by
//  what those choices left on disk. Per the prototype this page reports only the combined size:
//  the per-file inventory, with names and paths, is a developer's concern and lives on the
//  Developer mode page.
//

import MarmotKit
import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showClearLogsConfirmation = false
    @State private var showEraseAppDataConfirmation = false

    var body: some View {
        SettingsScaffold(title: L10n.string("Privacy & Security")) {
            SettingsSection(
                title: L10n.string("Remote Content"),
                footer: L10n.string(
                    "Off by default. Profile pictures come from URLs other people control, so loading them reveals your IP address and when you're online to whoever sent them. Only secure (https) images are ever loaded."
                )
            ) {
                WNToggle(
                    L10n.string("Load Remote Profile Images"),
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    isOn: Binding(
                        get: { workspace.loadRemoteImages },
                        set: { workspace.loadRemoteImages = $0 }
                    )
                )
            }

            DiagnosticsAndImprovementsSections()

            StoredDiagnosticLogsSection(showClearConfirmation: $showClearLogsConfirmation)

            SettingsSection(
                title: L10n.string("Device Data"),
                footer: L10n.string(
                    "Signs out every account and permanently removes all White Noise data from this Mac."
                )
            ) {
                // Outline rather than red, and with no destructive `role` to contradict that —
                // the same call `StorageSettingsView`'s Clear Cache makes. The irreversible step
                // is the system alert this opens, which is still drawn in red.
                Button {
                    showEraseAppDataConfirmation = true
                } label: {
                    SettingsBusyLabel(
                        title: workspace.isDeletingAllData
                            ? L10n.string("Erasing...") : L10n.string("Erase App Data"),
                        systemImage: "trash",
                        isBusy: workspace.isDeletingAllData
                    )
                }
                .buttonStyle(.wnSecondary)
                .disabled(workspace.isAccountMutationInProgress)
            }
        }
        .task {
            await workspace.loadAuditLogFiles()
        }
        .confirmationDialog(
            L10n.string("Clear diagnostic logs?"),
            isPresented: $showClearLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Clear Logs"), role: .destructive) {
                Task { await workspace.deleteAllAuditLogFiles() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "This permanently removes all recorded diagnostic activity from this Mac. Your logging preference won't change."
                )
            )
        }
        .alert(L10n.string("Erase app data?"), isPresented: $showEraseAppDataConfirmation) {
            Button(L10n.string("Erase App Data"), role: .destructive) {
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

/// The two data-sharing choices, one group each.
///
/// The first group carries the name the pair goes by — "Diagnostics & Improvements", the same
/// words the one-time prompt and the prototype use — so the reader meets it before either switch.
/// The second is left unnamed on purpose: a second heading would split one feature in two, when
/// what the gap between them actually marks is that turning one on says nothing about the other.
/// That is also why the footers are separate — a shared one would have to describe both at once,
/// which is how this pair ended up with no explanation at all.
private struct DiagnosticsAndImprovementsSections: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        SettingsSection(
            title: L10n.string("Diagnostics & Improvements"),
            footer: L10n.string(
                "Shares anonymous reliability, performance, and feature-use data to help improve White Noise. Messages, media, contacts, profile details, and keys are never included."
            )
        ) {
            AnonymousTelemetryToggleRow()
        }

        SettingsSection(
            footer: L10n.string(
                "Sends sanitized technical activity to White Noise to help troubleshoot problems. Message content is excluded and identifiers are obscured."
            )
        ) {
            AuditLoggingToggleRow()

            if workspace.isSavingPrivacySecurity {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("Saving..."))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
        }
    }
}

/// What audit logging has left on this Mac, and the two things that can be done with it.
///
/// One size, not a list of files: the prototype's rule is that this page reports the amount
/// without naming files or paths, because someone deciding whether to keep logs needs to know how
/// much there is, not what it is called. The inventory is on the Developer mode page.
///
/// Absent entirely when nothing is stored. The empty-state card this replaces was a row about
/// nothing — the switch above it already says why there are no logs.
private struct StoredDiagnosticLogsSection: View {
    @Environment(WorkspaceState.self) private var workspace
    @Binding var showClearConfirmation: Bool

    var body: some View {
        if !workspace.auditLogFiles.isEmpty {
            SettingsSection(
                title: L10n.string("Stored Diagnostic Logs"),
                footer: L10n.string("Turning logging off keeps existing logs until you clear them.")
            ) {
                SettingsValueRow(
                    title: L10n.string("On This Mac"),
                    value: AuditLogByteCount.string(storedByteCount),
                    monospaced: true
                )

                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.uploadAuditLogFiles() }
                    } label: {
                        SettingsBusyLabel(
                            title: workspace.isUploadingAuditLogFiles
                                ? L10n.string("Uploading...") : L10n.string("Upload Now"),
                            systemImage: "arrow.up.doc",
                            isBusy: workspace.isUploadingAuditLogFiles
                        )
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(
                        workspace.isUploadingAuditLogFiles
                            || !workspace.privacySecuritySettings.auditLogCredentialsAvailable
                    )

                    Button {
                        showClearConfirmation = true
                    } label: {
                        SettingsBusyLabel(
                            title: workspace.isDeletingAuditLogFiles
                                ? L10n.string("Clearing...") : L10n.string("Clear Logs"),
                            systemImage: "trash",
                            isBusy: workspace.isDeletingAuditLogFiles
                        )
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isDeletingAuditLogFiles)
                }

                if let auditLogUploadStatus = workspace.auditLogUploadStatus {
                    SettingsStatusNote(
                        text: auditLogUploadStatus,
                        intention: .success,
                        systemImage: "checkmark.seal"
                    )
                }
            }
        }
    }

    private var storedByteCount: UInt64 {
        workspace.auditLogFiles.reduce(into: UInt64(0)) { total, file in
            total += file.sizeBytes
        }
    }
}

/// A button's label while its work is running: the spinner takes the place the glyph held, so the
/// button keeps its width and the row does not jump when the work starts.
struct SettingsBusyLabel: View {
    let title: String
    let systemImage: String
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(title)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
    }
}

/// How an audit-log size is written, in the one place both pages read it from.
enum AuditLogByteCount {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
