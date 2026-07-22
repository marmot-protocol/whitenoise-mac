//
//  GlobalMessageSearchView.swift
//  whitenoise-mac
//

import SwiftUI

struct GlobalMessageSearchView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Search all messages"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("Search across your visible chats"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    workspace.dismissGlobalMessageSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background { MessagesCircleControlBackground() }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(L10n.string("Close"))
            }
            .padding(20)

            MessagesSearchField(
                text: $workspace.globalMessageSearchQuery,
                accessibilityIdentifier: "message.search.all",
                placeholder: L10n.string("Search message history"),
                autofocus: true
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            GlassSeparator(axis: .horizontal)

            searchContent
        }
        .frame(width: 680, height: 560)
        .background { MessagesSidebarBackground(level: .drawer) }
        .onChange(of: workspace.globalMessageSearchQuery) { _, _ in
            workspace.scheduleGlobalMessageSearch()
        }
        .onDisappear {
            workspace.dismissGlobalMessageSearch()
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if workspace.globalMessageSearchQuery.isEmpty {
            GlobalMessageSearchEmptyState(
                systemImage: "text.magnifyingglass",
                title: L10n.string("Find a message"),
                detail: L10n.string("Results include the newest 50 matches from your visible chats.")
            )
        } else if workspace.isSearchingAllMessages {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.string("Searching message history…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = workspace.globalMessageSearchError {
            GlobalMessageSearchEmptyState(
                systemImage: "exclamationmark.triangle",
                title: L10n.string("Search failed"),
                detail: error
            )
        } else if workspace.globalMessageSearchResults.isEmpty {
            GlobalMessageSearchEmptyState(
                systemImage: "magnifyingglass",
                title: L10n.string("No messages found"),
                detail: L10n.string("Try different words or check another account.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(workspace.globalMessageSearchResults) { result in
                        GlobalMessageSearchResultRow(result: result)
                    }
                }
                .padding(12)
            }
            .accessibilityIdentifier("message.search.results")
        }
    }
}

private struct GlobalMessageSearchResultRow: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let result: GlobalMessageSearchResult

    var body: some View {
        Button {
            Task { await workspace.openGlobalMessageSearchResult(result) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(result.chatTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(result.senderName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                highlightedSnippet
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message.search.result.\(result.messageId)")
    }

    private var highlightedSnippet: Text {
        Text(result.snippet.leading)
            + Text(result.snippet.match).bold().foregroundColor(.primary)
            + Text(result.snippet.trailing)
    }

    private var timestamp: String {
        DisplayText.dateTimeTimestamp(
            for: Date(timeIntervalSince1970: TimeInterval(result.timelineAt)),
            locale: locale
        )
    }
}

private struct GlobalMessageSearchEmptyState: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
