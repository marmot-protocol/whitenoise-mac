//
//  StorageSettingsView.swift
//  whitenoise-mac
//
//  The Storage page: what the downloaded attachments on this Mac add up to, and how to
//  get the space back.
//

import SwiftUI

struct StorageSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showClearConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Storage"),
            subtitle: L10n.string("Downloaded attachments stored on this Mac.")
        ) {
            // The folder is granted by the panel on the first download, so without this row there
            // would be no way to see where files went or to move them somewhere else.
            Section(L10n.string("Downloads")) {
                LabeledContent(L10n.string("Save downloads to")) {
                    Text(
                        workspace.mediaDownloadDestinationPath
                            ?? L10n.string("Chosen the first time you download")
                    )
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Button(L10n.string("Change Folder"), systemImage: "folder") {
                    workspace.changeMediaDownloadDestination()
                }
                .buttonStyle(.wnSecondary)
            }

            Section(L10n.string("Media Cache")) {
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

                Text(
                    L10n.string(
                        "White Noise encrypts cached attachment data on this Mac. Clearing it does not remove accounts, messages, drafts, or settings."
                    )
                )
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)

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
                    Label(
                        String(
                            format: L10n.string("%@ reclaimed."),
                            byteCount(reclaimed)
                        ),
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(WNColor.intentionSuccessContent)
                }
            }
        }
        .task {
            workspace.refreshMediaDownloadDestinationPath()
            await workspace.refreshMediaCacheFootprint()
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
}
