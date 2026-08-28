//
//  DeveloperModeSettingsView.swift
//  whitenoise-mac
//
//  The Developer mode page: the storage and diagnostics only a developer needs.
//

import AppKit
import SwiftUI

struct DeveloperModeSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

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

        }
    }
}
