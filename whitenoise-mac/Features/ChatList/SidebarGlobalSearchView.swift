import SwiftUI

/// Named sidebar search mode displaying individual global message matches across visible chats
/// (N08, C13, E01–E03, #1043). Provides an explicit Back/Done return to the chat list without
/// touching the chat list's filter, query, or bulk-selection state.
struct SidebarGlobalSearchView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: SidebarGlobalSearchViewModel
    let onBack: () -> Void
    let onOpenResult: (GlobalMessageSearchResult, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SidebarGlobalSearchHeader(
                resultCount: model.showsResults ? model.results.count : nil,
                onBack: onBack
            )

            MessagesSearchField(
                text: $model.query,
                accessibilityIdentifier: "message.search.all",
                placeholder: L10n.string("Search message history", locale: locale),
                autofocus: true,
                focusRequest: model.focusRequest
            )
            .onKeyPress(.downArrow) { model.moveSelection(down: true) ? .handled : .ignored }
            .onKeyPress(.upArrow) { model.moveSelection(down: false) ? .handled : .ignored }
            .onSubmit {
                if let result = model.selectedResult() {
                    onOpenResult(result, model.query)
                }
            }
            .onExitCommand(perform: onBack)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            SidebarGlobalSearchBody(
                model: model,
                onOpenResult: { result in
                    onOpenResult(result, model.query)
                }
            )
        }
        .accessibilityIdentifier("sidebar.globalSearch")
    }
}

private struct SidebarGlobalSearchHeader: View {
    @Environment(\.locale) private var locale
    let resultCount: Int?
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label(L10n.string("Back", locale: locale), systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Back", locale: locale))
            .accessibilityLabel(L10n.string("Back", locale: locale))
            .accessibilityIdentifier("sidebar.globalSearch.back")

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Search all messages", locale: locale))
                    .font(.headline)
                    .lineLimit(1)

                if let resultCount {
                    Text(L10n.plural("%lld matches", Int64(resultCount), locale: locale))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button(L10n.string("Done", locale: locale), action: onBack)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sidebar.globalSearch.done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct SidebarGlobalSearchBody: View {
    @Environment(\.locale) private var locale
    let model: SidebarGlobalSearchViewModel
    let onOpenResult: (GlobalMessageSearchResult) -> Void

    var body: some View {
        if !model.hasQuery {
            ContentUnavailableView {
                Label(
                    L10n.string("Find a message", locale: locale),
                    systemImage: "text.magnifyingglass"
                )
            } description: {
                Text(
                    L10n.string(
                        "Results include the newest 50 matches from your visible chats.",
                        locale: locale
                    )
                )
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isSearching {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Searching message history…", locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            ContentUnavailableView {
                Label(L10n.string("Search failed", locale: locale), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.string("Try Again", locale: locale)) {
                    model.retry()
                }
                .wnSecondaryButtonStyle()
                .controlSize(.small)
                .accessibilityIdentifier("sidebar.globalSearch.retry")
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.results.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("No messages found", locale: locale), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.string("Try different words or check another account.", locale: locale))
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SidebarGlobalSearchResultsList(
                results: model.results,
                selectedResultID: model.selectedResultID,
                isTruncated: model.isTruncated,
                onSelect: { model.selectedResultID = $0.id },
                onOpen: onOpenResult
            )
        }
    }
}

private struct SidebarGlobalSearchResultsList: View {
    @Environment(\.locale) private var locale
    let results: [GlobalMessageSearchResult]
    let selectedResultID: String?
    let isTruncated: Bool
    let onSelect: (GlobalMessageSearchResult) -> Void
    let onOpen: (GlobalMessageSearchResult) -> Void
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(results) { result in
                    SidebarGlobalSearchRow(
                        result: result,
                        isSelected: result.id == selectedResultID,
                        onOpen: {
                            onSelect(result)
                            onOpen(result)
                        }
                    )
                }

                if isTruncated {
                    Text(
                        L10n.string(
                            "Results include the newest 50 matches from your visible chats.",
                            locale: locale
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("sidebar.globalSearch.truncated")
                }
            }
            .scrollTargetLayout()
            .padding(8)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: selectedResultID) { _, selected in
            guard let selected else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                scrollPosition.scrollTo(id: selected)
            }
        }
        .accessibilityIdentifier("message.search.results")
    }
}

private struct SidebarGlobalSearchRow: View {
    @Environment(\.locale) private var locale
    let result: GlobalMessageSearchResult
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.chatTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(
                        DisplayText.dateTimeTimestamp(
                            for: Date(timeIntervalSince1970: TimeInterval(result.timelineAt)),
                            locale: locale
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Text(result.senderName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                SearchMatchHighlightStyle.text(result.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18) : .clear)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
}

#Preview("Sidebar global search — results") {
    let model = SidebarGlobalSearchViewModel(debounce: .zero) { _, _ in
        [
            GlobalMessageSearchResult(
                messageId: "m1",
                groupId: "g1",
                chatTitle: "Design Crew",
                senderName: "Ana",
                timelineAt: 1_760_000_000,
                snippet: GlobalMessageSearchSnippet(leading: "Meet for ", match: "lunch", trailing: " at noon?")
            ),
            GlobalMessageSearchResult(
                messageId: "m2",
                groupId: "g2",
                chatTitle: "Book Club",
                senderName: "Ben",
                timelineAt: 1_759_900_000,
                snippet: GlobalMessageSearchSnippet(leading: "Bringing ", match: "lunch", trailing: " tomorrow.")
            ),
        ]
    }
    model.activate(initialQuery: "lunch")
    return SidebarGlobalSearchView(model: model, onBack: {}, onOpenResult: { _, _ in })
        .frame(width: 280, height: 480)
}

#Preview("Sidebar global search — empty") {
    let model = SidebarGlobalSearchViewModel(debounce: .zero)
    model.activate()
    return SidebarGlobalSearchView(model: model, onBack: {}, onOpenResult: { _, _ in })
        .frame(width: 280, height: 480)
}
