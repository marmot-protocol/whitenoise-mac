//
//  GlobalMessageSearchView.swift
//  whitenoise-mac
//

import SwiftUI

struct GlobalMessageSearchView: View {
    @Environment(WorkspaceState.self) private var workspace
    /// The result ↓ / ↑ highlight and Return opens; see `GlobalMessageSearchSelection`.
    @State private var selectedResultID: String?

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
            .onKeyPress(.downArrow) { moveSelection(down: true) }
            .onKeyPress(.upArrow) { moveSelection(down: false) }
            .onSubmit(openSelectedResult)
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
        .onChange(of: resultIDs) { _, ids in
            selectedResultID = GlobalMessageSearchSelection.reanchored(
                selectedResultID,
                in: ids,
                whileSearching: workspace.isSearchingAllMessages
            )
        }
        .onDisappear {
            workspace.dismissGlobalMessageSearch()
        }
    }

    private var resultIDs: [String] {
        workspace.globalMessageSearchResults.map(\.id)
    }

    /// Results are only navigable while they are what the pane shows.
    private var showsResults: Bool {
        !workspace.globalMessageSearchQuery.isEmpty
            && !workspace.isSearchingAllMessages
            && workspace.globalMessageSearchError == nil
            && !workspace.globalMessageSearchResults.isEmpty
    }

    private func moveSelection(down: Bool) -> KeyPress.Result {
        guard showsResults else { return .ignored }
        let ids = resultIDs
        let target =
            down
            ? GlobalMessageSearchSelection.next(after: selectedResultID, in: ids)
            : GlobalMessageSearchSelection.previous(before: selectedResultID, in: ids)
        guard let target else { return .ignored }
        selectedResultID = target
        return .handled
    }

    private func openSelectedResult() {
        guard showsResults,
            let selectedResultID,
            let result = workspace.globalMessageSearchResults.first(where: { $0.id == selectedResultID })
        else { return }
        open(result)
    }

    private func open(_ result: GlobalMessageSearchResult) {
        Task { await workspace.openGlobalMessageSearchResult(result) }
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
            GlobalMessageSearchResultList(
                results: workspace.globalMessageSearchResults,
                selectedResultID: selectedResultID,
                onOpen: open
            )
        }
    }
}

/// The result rows, scrolled so the keyboard-selected one stays in view.
struct GlobalMessageSearchResultList: View {
    let results: [GlobalMessageSearchResult]
    let selectedResultID: String?
    let onOpen: (GlobalMessageSearchResult) -> Void
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(results) { result in
                    GlobalMessageSearchResultRow(
                        result: result,
                        isSelected: result.id == selectedResultID,
                        onOpen: { onOpen(result) }
                    )
                }
            }
            .scrollTargetLayout()
            .padding(12)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: selectedResultID) { _, selected in
            guard let selected else { return }
            // No anchor: scroll only as far as it takes to bring the row fully into view.
            withAnimation(.easeOut(duration: 0.15)) {
                scrollPosition.scrollTo(id: selected)
            }
        }
        .accessibilityIdentifier("message.search.results")
    }
}

private struct GlobalMessageSearchResultRow: View {
    @Environment(\.locale) private var locale
    let result: GlobalMessageSearchResult
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
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
                    .fill(isSelected ? WNColor.fillSecondaryActive : WNColor.fillSecondary)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(WNColor.borderPrimary, lineWidth: 1)
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message.search.result.\(result.messageId)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

#Preview("Keyboard-selected result") {
    let results = ["alpha", "beta", "gamma"].map { id in
        GlobalMessageSearchResult(
            messageId: id,
            groupId: "group",
            chatTitle: "Weekend plans",
            senderName: "Ana",
            timelineAt: 1_760_000_000,
            snippet: GlobalMessageSearchSnippet(leading: "Lunch at ", match: id, trailing: " tomorrow?")
        )
    }
    GlobalMessageSearchResultList(results: results, selectedResultID: "group:beta", onOpen: { _ in })
        .frame(width: 680, height: 320)
}
