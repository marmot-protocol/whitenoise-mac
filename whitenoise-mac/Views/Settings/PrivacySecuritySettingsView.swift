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
    let model: DiagnosticsSettingsViewModel
    @State private var showClearLogsConfirmation = false
    @State private var showEraseAppDataConfirmation = false

    var body: some View {
        SettingsScaffold(title: L10n.string("Privacy & Security")) {
            SettingsSection {
                SettingsNavigationRow(page: .blockedUsers)
            }

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

            RemoteGIFLoadingSection(preference: .shared)

            DiagnosticsAndImprovementsSections(model: model)

            StoredDiagnosticLogsSection(
                model: model,
                showClearConfirmation: $showClearLogsConfirmation
            )

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
            await model.load()
        }
        .confirmationDialog(
            L10n.string("Clear diagnostic logs?"),
            isPresented: $showClearLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Clear Logs"), role: .destructive) {
                Task { await model.deleteAllAuditLogs() }
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

/// Whether a received GIF loads from GIPHY without a click. Its own group rather than a second row
/// under Remote Content, because that group's footer is about profile pictures and this one needs a
/// footer of its own saying what it gives away.
struct RemoteGIFLoadingSection: View {
    let preference: RemoteGIFLoadingPreference

    var body: some View {
        SettingsSection(
            footer: L10n.string(
                "When enabled, opening a conversation can tell GIPHY your IP address and which GIF was requested. Otherwise, received GIFs load only when you tap them."
            )
        ) {
            WNToggle(
                L10n.string("Automatically Load Remote GIFs"),
                systemImage: "play.rectangle",
                isOn: Binding(
                    get: { preference.automaticallyLoads },
                    set: { preference.setAutomaticallyLoads($0) }
                )
            )
        }
    }
}

#Preview("Remote GIF loading") {
    Form {
        RemoteGIFLoadingSection(
            preference: RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: "gif-settings-preview")!)
        )
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 200)
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
    let model: DiagnosticsSettingsViewModel

    var body: some View {
        SettingsSection(
            title: L10n.string("Diagnostics & Improvements"),
            footer: L10n.string(
                "Shares anonymous reliability, performance, and feature-use data to help improve White Noise. Messages, media, contacts, profile details, and keys are never included."
            )
        ) {
            DataSharingToggleRows(model: model)

            if let status = model.status {
                SettingsValueRow(
                    title: L10n.string("Status"),
                    value: exporterSummary(status)
                )
            }
        }

        if let error = model.error {
            SettingsSection {
                SettingsErrorView(error: error.message)
            }
        }
    }

    private func exporterSummary(_ status: UsageDiagnosticsStatusFfi) -> String {
        String(
            format: L10n.string("Usage: %@. Diagnostics: %@."),
            exporterLabel(status.productAnalytics),
            exporterLabel(status.telemetry)
        )
    }

    private func exporterLabel(_ status: DiagnosticsExporterStatusFfi) -> String {
        switch status {
        case .disabled: L10n.string("Off")
        case .consentRequired: L10n.string("Permission needed")
        case .unconfigured: L10n.string("Not configured")
        case .unsupportedBuild: L10n.string("Unavailable in this build")
        case .ready: L10n.string("Ready to share")
        case .configurationRejected: L10n.string("Configuration rejected")
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
    let model: DiagnosticsSettingsViewModel
    @Binding var showClearConfirmation: Bool

    var body: some View {
        if !model.auditLogFiles.isEmpty {
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
                        Task { await model.uploadAuditLogs() }
                    } label: {
                        SettingsBusyLabel(
                            title: model.isUploadingAuditLogs
                                ? L10n.string("Uploading...") : L10n.string("Upload Now"),
                            systemImage: "arrow.up.doc",
                            isBusy: model.isUploadingAuditLogs
                        )
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(model.isUploadingAuditLogs)

                    Button {
                        showClearConfirmation = true
                    } label: {
                        SettingsBusyLabel(
                            title: model.isDeletingAuditLogs
                                ? L10n.string("Clearing...") : L10n.string("Clear Logs"),
                            systemImage: "trash",
                            isBusy: model.isDeletingAuditLogs
                        )
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(model.isDeletingAuditLogs)
                }

                if let auditLogUploadStatus = model.auditUploadStatus {
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
        model.auditLogFiles.reduce(into: UInt64(0)) { total, file in
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
