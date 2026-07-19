//
//  MessageEditHistorySheet.swift
//  whitenoise-mac
//
//  The edit-history viewer: the current text on top, then each earlier revision newest-first
//  down to the original, reconstructed client-side from the timeline's retained edit overlays.
//

import SwiftUI

private struct MessageEditHistoryModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace

        content.sheet(item: $workspace.messagePendingEditHistory) { message in
            MessageEditHistoryView(message: message)
                .environment(workspace)
        }
    }
}

extension View {
    func messageEditHistory() -> some View {
        modifier(MessageEditHistoryModifier())
    }
}

private struct MessageEditHistoryView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let message: MessageItem

    var body: some View {
        // Newest first: the current text, earlier revisions, then the original last.
        let versions = workspace.editHistory(for: message).reversed().enumerated().map { index, version in
            (version: version, isLatest: index == 0)
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string("Edit history"))
                    .font(.headline)
                Spacer()
                GlassCircleCloseButton { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if versions.isEmpty {
                        Text(L10n.string("No earlier versions."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(versions, id: \.version.id) { entry in
                        versionRow(entry.version, isLatest: entry.isLatest)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }

    private func versionRow(_ version: MessageEditVersion, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(
                    version.isOriginal
                        ? L10n.string("Original")
                        : (isLatest ? L10n.string("Current") : L10n.string("Edited"))
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isLatest ? Color.accentColor : Color.secondary)
                Spacer()
                Text(DisplayText.messageTimestamp(for: version.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(version.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .glassCard()
        }
    }
}
