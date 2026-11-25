//
//  MessageEditHistorySheet.swift
//  whitenoise-mac
//
//  The edit-history viewer. Prepared conversations page accepted versions directly from
//  MarmotKit, so history remains complete when its edit rows are outside the visible window.
//

import MarmotKit
import SwiftUI

private struct MessageEditHistoryModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    let model: ConversationViewModel

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace

        content.sheet(item: $workspace.messagePendingEditHistory) { message in
            MessageEditHistoryView(message: message, model: model)
        }
    }
}

extension View {
    func messageEditHistory(model: ConversationViewModel) -> some View {
        modifier(MessageEditHistoryModifier(model: model))
    }
}

private struct MessageEditHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let message: MessageItem
    let model: ConversationViewModel
    @State private var versions: [TimelineEditVersionFfi] = []
    @State private var cursor: TimelineEditVersionFfi?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        MessageEditHistoryContentView(
            versions: versions,
            isLoading: isLoading,
            errorMessage: errorMessage,
            hasMore: hasMore,
            onLoadMore: { Task { await loadNextPage() } },
            onClose: { dismiss() }
        )
        .task(id: message.id) { await loadNextPage() }
    }

    @MainActor
    private func loadNextPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await model.editHistory(messageIdHex: message.id, before: cursor)
            try Task.checkCancellation()
            let known = Set(versions.map(\.messageIdHex))
            let next = page.versions.reversed().filter { !known.contains($0.messageIdHex) }
            versions.append(contentsOf: next)
            cursor = page.versions.first
            hasMore = page.hasMoreBefore && cursor != nil
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

/// The edit-history sheet layout, taking plain state so it previews and tests without a workspace.
struct MessageEditHistoryContentView: View {
    let versions: [TimelineEditVersionFfi]
    let isLoading: Bool
    let errorMessage: String?
    let hasMore: Bool
    let onLoadMore: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string("Edit history"))
                    .font(.headline)
                    .foregroundStyle(WNColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            FittedSheetScrollView(maximumHeight: 440) {
                VStack(alignment: .leading, spacing: 14) {
                    if versions.isEmpty, !isLoading, errorMessage == nil {
                        Text(L10n.string("No earlier versions."))
                            .font(.subheadline)
                            .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                            .padding(.top, 8)
                    }
                    ForEach(Array(versions.enumerated()), id: \.element.messageIdHex) { index, version in
                        MessageEditHistoryVersionRow(version: version, isLatest: index == 0)
                    }
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(WNColor.intentionErrorContent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if errorMessage != nil || hasMore {
                        Button(
                            errorMessage != nil ? L10n.string("Retry") : L10n.string("Load more"), action: onLoadMore
                        )
                        .wnSecondaryButtonStyle()
                        .disabled(isLoading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.string("Done"), action: onClose)
                    .wnSecondaryButtonStyle()
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .presentationSizing(.fitted)
    }
}

private struct MessageEditHistoryVersionRow: View {
    let version: TimelineEditVersionFfi
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(isLatest ? L10n.string("Current") : L10n.string("Edited"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isLatest ? WNColor.textPrimary : WNColor.messageReceivedSecondaryContent)
                Spacer()
                Text(DisplayText.messageTimestamp(for: Date(timeIntervalSince1970: TimeInterval(version.editedAt))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WNColor.messageReceivedSecondaryContent)
            }
            Text(version.plaintext)
                .font(.body)
                .foregroundStyle(WNColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
                }
        }
    }
}

#if DEBUG
    #Preview("Edit history") {
        MessageEditHistoryContentView(
            versions: [
                TimelineEditVersionFfi(
                    messageIdHex: "v2",
                    editedAt: 1_760_003_600,
                    plaintext: "Meeting moved to 3pm in the north room."
                ),
                TimelineEditVersionFfi(
                    messageIdHex: "v1",
                    editedAt: 1_760_000_000,
                    plaintext: "Meeting moved to 2pm."
                ),
            ],
            isLoading: false,
            errorMessage: nil,
            hasMore: false,
            onLoadMore: {},
            onClose: {}
        )
    }

    #Preview("Edit history – error") {
        MessageEditHistoryContentView(
            versions: [],
            isLoading: false,
            errorMessage: "Storage is temporarily busy. Try again.",
            hasMore: false,
            onLoadMore: {},
            onClose: {}
        )
    }
#endif
