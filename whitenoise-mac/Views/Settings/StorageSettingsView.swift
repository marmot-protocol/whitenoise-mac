//
//  StorageSettingsView.swift
//  whitenoise-mac
//
//  The Storage page: what the downloaded attachments on this Mac add up to, and how to
//  get the space back.
//

import MarmotKit
import SwiftUI

struct StorageSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showClearConfirmation = false
    /// Mirrors the stored preference, which is not observable; loaded when the pane opens.
    @State private var alwaysAsksWhereToSave = false
    /// The folder row says it cannot be opened only once a refresh has actually found that.
    @State private var hasRefreshedDownloadFolder = false
    @State private var retainedMiB = 2_048
    @State private var reserveMiB = 256
    @State private var transferMiB = 64
    let model: StorageSettingsViewModel

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Storage"),
            subtitle: L10n.string("Downloaded attachments stored on this Mac.")
        ) {
            StorageDownloadsSection(
                destinationPath: workspace.mediaDownloadDestinationPath,
                hasRefreshedDownloadFolder: hasRefreshedDownloadFolder,
                alwaysAsksWhereToSave: Binding(
                    get: { alwaysAsksWhereToSave },
                    set: { asks in
                        alwaysAsksWhereToSave = asks
                        workspace.mediaDownloadDestinationStore.alwaysAsksWhereToSave = asks
                    }
                ),
                onChangeFolder: { workspace.changeMediaDownloadDestination() }
            )

            StorageLimitsSection(
                model: model,
                retainedMiB: $retainedMiB,
                reserveMiB: $reserveMiB,
                transferMiB: $transferMiB
            )

            // What the limits above are spent on, chat by chat, and the bulk removals that give
            // the space back — iOS's Settings → Manage Storage.
            SettingsSection {
                SettingsNavigationRow(page: .manageStorage)
            }

            StorageMediaCacheSection(
                isLoadingFootprint: workspace.isLoadingMediaCacheFootprint,
                isClearingCache: workspace.isClearingMediaCache,
                footprintBytes: workspace.mediaCacheFootprint.byteCount,
                reclaimedBytes: workspace.mediaCacheReclaimedByteCount,
                onRequestClear: { showClearConfirmation = true }
            )
        }
        .task(id: ObjectIdentifier(model)) {
            alwaysAsksWhereToSave = workspace.mediaDownloadDestinationStore.alwaysAsksWhereToSave
            workspace.refreshMediaDownloadDestinationPath()
            hasRefreshedDownloadFolder = true
            await workspace.refreshMediaCacheFootprint()
            await model.load()
        }
        .task(id: model.policy) {
            guard let policy = model.policy else { return }
            let clamped = StorageLimitUnits.mebibytes(from: policy)
            retainedMiB = clamped.retainedMiB
            reserveMiB = clamped.reserveMiB
            transferMiB = clamped.transferMiB
        }
        .confirmationDialog(
            L10n.string("Clear media cache?"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Clear Cache"), role: .destructive) {
                Task { await workspace.clearMediaCache() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                String(
                    format: L10n.string(
                        "This removes %@ of encrypted cached attachments. Visible media will download again when needed."
                    ),
                    StorageLimitUnits.byteCount(workspace.mediaCacheFootprint.byteCount)
                )
            )
        }
    }
}

private struct StorageDownloadsSection: View {
    let destinationPath: String?
    let hasRefreshedDownloadFolder: Bool
    @Binding var alwaysAsksWhereToSave: Bool
    let onChangeFolder: () -> Void

    var body: some View {
        SettingsSection(title: L10n.string("Downloads")) {
            // Downloads until the user picks another folder here; without this row there would
            // be no way to see where files went or to move them elsewhere.
            SettingsValueRow(
                title: L10n.string("Save downloads to"),
                value: destinationPath
                    ?? (hasRefreshedDownloadFolder ? L10n.string("The chosen folder can’t be opened") : ""),
                truncatesMiddle: true
            )

            Button(L10n.string("Change Folder"), systemImage: "folder", action: onChangeFolder)
                .wnSecondaryButtonStyle()

            WNToggle(
                L10n.string("Always ask where to save"),
                systemImage: "questionmark.folder",
                isOn: $alwaysAsksWhereToSave
            )
        }
    }
}

private struct StorageLimitsSection: View {
    let model: StorageSettingsViewModel
    @Binding var retainedMiB: Int
    @Binding var reserveMiB: Int
    @Binding var transferMiB: Int

    private var hasUnsavedChanges: Bool {
        guard let policy = model.policy else { return false }
        let saved = StorageLimitUnits.mebibytes(from: policy)
        return retainedMiB != saved.retainedMiB
            || reserveMiB != saved.reserveMiB
            || transferMiB != saved.transferMiB
    }

    var body: some View {
        SettingsSection(
            title: L10n.string("Storage"),
            footer: L10n.string(
                "Limits apply to this profile. Downloads pause when storage is full; existing files are kept. Remove individual downloads from Message info. Automatic downloads also follow your media and network preferences."
            )
        ) {
            if model.policy == nil {
                if let error = model.error {
                    HStack(spacing: 8) {
                        SettingsStatusNote(text: error.message, intention: .failure)
                        Button(L10n.string("Try Again")) {
                            Task { await model.load() }
                        }
                        .wnSecondaryButtonStyle()
                        .disabled(model.isLoading)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Stepper(value: $retainedMiB, in: max(256, transferMiB)...32_768, step: 256) {
                    LabeledContent(L10n.string("Download storage limit")) {
                        Text(StorageLimitUnits.mebibyteCount(retainedMiB))
                            .monospacedDigit()
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }

                Stepper(value: $reserveMiB, in: 0...8_192, step: 256) {
                    LabeledContent(L10n.string("Keep disk space free")) {
                        Text(StorageLimitUnits.mebibyteCount(reserveMiB))
                            .monospacedDigit()
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }

                Stepper(value: $transferMiB, in: 1...min(512, retainedMiB), step: 1) {
                    LabeledContent(L10n.string("Automatic download size limit")) {
                        Text(StorageLimitUnits.mebibyteCount(transferMiB))
                            .monospacedDigit()
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }

                Button {
                    Task {
                        await model.saveLimits(
                            retainedBytes: StorageLimitUnits.bytes(fromMebibytes: retainedMiB),
                            diskReserve: StorageLimitUnits.bytes(fromMebibytes: reserveMiB),
                            transferLimit: StorageLimitUnits.bytes(fromMebibytes: transferMiB)
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(L10n.string("Save"))
                    }
                }
                .wnPrimaryButtonStyle()
                .disabled(model.isSaving || !hasUnsavedChanges)

                if let error = model.error {
                    SettingsStatusNote(text: error.message, intention: .failure)
                }
            }
        }
    }
}

private struct StorageMediaCacheSection: View {
    let isLoadingFootprint: Bool
    let isClearingCache: Bool
    let footprintBytes: UInt64
    let reclaimedBytes: UInt64?
    let onRequestClear: () -> Void

    var body: some View {
        SettingsSection(
            title: L10n.string("Media Cache"),
            footer: L10n.string(
                "White Noise encrypts cached attachment data on this Mac. Clearing it does not remove accounts, messages, drafts, or settings."
            )
        ) {
            LabeledContent(L10n.string("Cached attachments")) {
                if isLoadingFootprint {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(StorageLimitUnits.byteCount(footprintBytes))
                        .monospacedDigit()
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }

            Button(action: onRequestClear) {
                SettingsBusyLabel(
                    title: isClearingCache ? L10n.string("Clearing...") : L10n.string("Clear Cache"),
                    systemImage: "trash",
                    isBusy: isClearingCache
                )
            }
            // Outline rather than red by explicit request, and with no destructive `role`
            // to contradict that. The confirmation dialog it opens is system-rendered, so the
            // irreversible step is still the one drawn in red.
            .wnSecondaryButtonStyle()
            .disabled(isClearingCache || isLoadingFootprint || footprintBytes == 0)

            if let reclaimed = reclaimedBytes {
                SettingsStatusNote(
                    text: String(
                        format: L10n.string("%@ reclaimed."),
                        StorageLimitUnits.byteCount(reclaimed)
                    )
                )
            }
        }
    }
}

private enum StorageLimitUnits {
    static func mebibytes(from policy: AttachmentDownloadPolicyFfi) -> (
        retainedMiB: Int, reserveMiB: Int, transferMiB: Int
    ) {
        let transfer = min(512, max(1, Int(policy.transferLimit / 1_048_576)))
        let retained = max(transfer, min(32_768, max(256, Int(policy.retainedBytes / 1_048_576))))
        let reserve = min(8_192, max(0, Int(policy.diskReserve / 1_048_576)))
        return (retained, reserve, transfer)
    }

    static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    static func mebibyteCount(_ mebibytes: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(mebibytes) * 1_048_576,
            countStyle: .binary
        )
    }

    static func bytes(fromMebibytes mebibytes: Int) -> UInt64 {
        UInt64(mebibytes) * 1_048_576
    }
}

#Preview("Loading") {
    StorageSettingsView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 720)
}

#if DEBUG
    #Preview("Load error") {
        StorageSettingsView(
            model: .preview(
                policy: nil,
                error: .unavailable("Couldn't load storage usage")
            )
        )
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 720)
    }
#endif
