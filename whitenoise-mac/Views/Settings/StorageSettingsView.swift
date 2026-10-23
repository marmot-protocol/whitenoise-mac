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
    @State private var retainedMiB = 2_048
    @State private var reserveMiB = 256
    @State private var transferMiB = 64
    let model: StorageSettingsViewModel

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Storage"),
            subtitle: L10n.string("Downloaded attachments stored on this Mac.")
        ) {
            // The folder is granted by the panel on the first download, so without this row there
            // would be no way to see where files went or to move them somewhere else.
            SettingsSection(title: L10n.string("Downloads")) {
                SettingsValueRow(
                    title: L10n.string("Save downloads to"),
                    value: workspace.mediaDownloadDestinationPath
                        ?? L10n.string("Chosen the first time you download"),
                    truncatesMiddle: true
                )

                Button(L10n.string("Change Folder"), systemImage: "folder") {
                    workspace.changeMediaDownloadDestination()
                }
                .buttonStyle(.wnSecondary)
            }

            SettingsSection(
                title: L10n.string("Storage"),
                footer: L10n.string(
                    "Limits apply to this profile. Downloads pause when storage is full; existing files are kept. Remove individual downloads from Message info. Automatic downloads also follow your media and network preferences."
                )
            ) {
                if model.policy == nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Stepper(value: $retainedMiB, in: max(256, transferMiB)...32_768, step: 256) {
                        LabeledContent(
                            L10n.string("Download storage limit"),
                            value: mebibyteCount(retainedMiB)
                        )
                    }

                    Stepper(value: $reserveMiB, in: 0...8_192, step: 256) {
                        LabeledContent(
                            L10n.string("Keep disk space free"),
                            value: mebibyteCount(reserveMiB)
                        )
                    }

                    Stepper(value: $transferMiB, in: 1...min(512, retainedMiB), step: 1) {
                        LabeledContent(
                            L10n.string("Automatic download size limit"),
                            value: mebibyteCount(transferMiB)
                        )
                    }

                    Button(L10n.string("Save")) {
                        Task {
                            await model.saveLimits(
                                retainedBytes: bytes(fromMebibytes: retainedMiB),
                                diskReserve: bytes(fromMebibytes: reserveMiB),
                                transferLimit: bytes(fromMebibytes: transferMiB)
                            )
                        }
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(model.isSaving)

                    if let error = model.error {
                        SettingsStatusNote(text: error.message, intention: .failure)
                    }
                }
            }

            // What the limits above are spent on, chat by chat, and the bulk removals that give
            // the space back — iOS's Settings → Manage Storage.
            SettingsSection {
                SettingsNavigationRow(page: .manageStorage)
            }

            SettingsSection(
                title: L10n.string("Media Cache"),
                footer: L10n.string(
                    "White Noise encrypts cached attachment data on this Mac. Clearing it does not remove accounts, messages, drafts, or settings."
                )
            ) {
                LabeledContent(L10n.string("Cached attachments")) {
                    if workspace.isLoadingMediaCacheFootprint {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(byteCount(workspace.mediaCacheFootprint.byteCount))
                            .monospacedDigit()
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }

                Button {
                    showClearConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        if workspace.isClearingMediaCache {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label(
                            workspace.isClearingMediaCache ? L10n.string("Clearing...") : L10n.string("Clear Cache"),
                            systemImage: "trash"
                        )
                    }
                }
                // Outline rather than red by explicit request, and with no destructive `role`
                // to contradict that. The confirmation dialog it opens is system-rendered, so the
                // irreversible step is still the one drawn in red.
                .buttonStyle(.wnSecondary)
                .disabled(
                    workspace.isClearingMediaCache
                        || workspace.isLoadingMediaCacheFootprint
                        || workspace.mediaCacheFootprint.byteCount == 0
                )

                if let reclaimed = workspace.mediaCacheReclaimedByteCount {
                    SettingsStatusNote(
                        text: String(
                            format: L10n.string("%@ reclaimed."),
                            byteCount(reclaimed)
                        )
                    )
                }
            }
        }
        .task {
            workspace.refreshMediaDownloadDestinationPath()
            await workspace.refreshMediaCacheFootprint()
            await model.load()
        }
        .task(id: model.policy) {
            guard let policy = model.policy else { return }
            retainedMiB = min(32_768, max(256, Int(policy.retainedBytes / 1_048_576)))
            reserveMiB = min(8_192, max(0, Int(policy.diskReserve / 1_048_576)))
            transferMiB = min(512, max(1, Int(policy.transferLimit / 1_048_576)))
            retainedMiB = max(retainedMiB, transferMiB)
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
                    byteCount(workspace.mediaCacheFootprint.byteCount)
                )
            )
        }
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func mebibyteCount(_ mebibytes: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(mebibytes) * 1_048_576,
            countStyle: .binary
        )
    }

    private func bytes(fromMebibytes mebibytes: Int) -> UInt64 {
        UInt64(mebibytes) * 1_048_576
    }
}

#Preview {
    StorageSettingsView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 720)
}
