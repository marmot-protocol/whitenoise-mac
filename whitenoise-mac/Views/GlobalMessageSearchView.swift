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
                        .wnFont(.semiBold18)
                    Text(L10n.string("Search across your visible chats"))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                Spacer()
                Button {
                    workspace.dismissGlobalMessageSearch()
                } label: {
                    Image(systemName: "xmark")
                        .wnFont(.bold14)
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
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
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
                        .wnFont(.semiBold12)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                    Text(result.senderName)
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timestamp)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                }

                highlightedSnippet
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(WNColor.fillSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message.search.result.\(result.messageId)")
    }

    private var highlightedSnippet: Text {
        Text(result.snippet.leading)
            // The matched run takes `intentionInfoContent`, the same token the other clients
            // highlight a search hit with.
            + Text(result.snippet.match).wnFont(.bold12).foregroundColor(WNColor.intentionInfoContent)
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
