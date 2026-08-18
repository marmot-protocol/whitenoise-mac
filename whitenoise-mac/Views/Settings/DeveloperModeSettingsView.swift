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
            Section(L10n.string("Developer")) {
                Toggle(isOn: $workspace.developerMode) {
                    Label(L10n.string("Developer mode"), systemImage: "stethoscope")
                }

                Toggle(isOn: $workspace.streamingDebugMode) {
                    Label(L10n.string("Streaming debug"), systemImage: "waveform.path.ecg")
                }
                .disabled(!workspace.developerMode)
            }

            Section(L10n.string("Storage")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Location"))

                    Text(workspace.storageRootPath)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.storageRootPath, isDirectory: true))
                } label: {
                    Label(L10n.string("Open Storage Folder"), systemImage: "folder")
                }
                .buttonStyle(.wnSecondary)
            }

            Section(L10n.string("Diagnostics")) {
                ForEach(workspace.diagnosticsInfo) { item in
                    LabeledContent(item.title) {
                        Text(item.value)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .textSelection(.enabled)
                    }
                }
            }

        }
    }
}
