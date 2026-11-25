import SwiftUI

/// The in-conversation search strip pinned under the conversation header: the field, where the
/// cursor stands among the matches, and the controls that step through them.
///
/// `⇧⌘G` / ↑ steps to the previous (older / higher) match, `⌘G` / ↓ steps to the next (newer /
/// lower) match, both disabling at their boundaries, and Escape closes.
struct ConversationSearchBar: View {
    @Bindable var model: ConversationSearchViewModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MessagesSearchField(
                text: $model.query,
                accessibilityIdentifier: "conversation.search.field",
                placeholder: L10n.string("Search messages"),
                autofocus: true,
                focusRequest: model.focusRequest
            )
            .frame(maxWidth: .infinity)
            .onSubmit(submitSearch)
            // ↑ / ↓ step like the chevrons beside the field. The field is one line, so the caret
            // loses nothing; at boundaries or with no matches the keys fall through to it.
            .onKeyPress(.upArrow) { step(canStep: model.canGoToOlderMatch, model.goToOlderMatch) }
            .onKeyPress(.downArrow) { step(canStep: model.canGoToNewerMatch, model.goToNewerMatch) }
            .onExitCommand(perform: onClose)

            ConversationSearchStatus(model: model)

            HStack(spacing: 2) {
                ConversationSearchIconButton(
                    systemImage: "chevron.up",
                    help: L10n.string("Previous match"),
                    isDisabled: !model.canGoToOlderMatch,
                    action: model.goToOlderMatch
                )
                .accessibilityIdentifier("conversation.search.previous")

                ConversationSearchIconButton(
                    systemImage: "chevron.down",
                    help: L10n.string("Next match"),
                    isDisabled: !model.canGoToNewerMatch,
                    action: model.goToNewerMatch
                )
                .accessibilityIdentifier("conversation.search.next")
            }

            ConversationSearchIconButton(
                systemImage: "xmark",
                help: L10n.string("Close"),
                isDisabled: false,
                action: onClose
            )
            .accessibilityIdentifier("conversation.search.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("conversation.search")
    }

    private func submitSearch() {
        if model.canGoToOlderMatch {
            model.goToOlderMatch()
        } else if model.canGoToNewerMatch {
            model.goToNewerMatch()
        }
    }

    private func step(canStep: Bool, _ move: () -> Void) -> KeyPress.Result {
        guard canStep else { return .ignored }
        move()
        return .handled
    }
}

/// "3 of 17", or why there is no position to show.
private struct ConversationSearchStatus: View {
    let model: ConversationSearchViewModel

    var body: some View {
        Group {
            if let position = model.displayPosition {
                Text(
                    String(
                        format: L10n.string("%1$lld of %2$lld"),
                        Int64(position),
                        Int64(model.matches.count)
                    )
                )
                .contentTransition(.numericText())
            } else if model.isSearching {
                Text(L10n.string("Searching…"))
            } else if model.didFail {
                Text(L10n.string("Search failed"))
            } else if !model.matches.isEmpty {
                // A recount left no cursor: the total, with no claim about where the reader is.
                Text(L10n.plural("%lld matches", Int64(model.matches.count)))
                    .contentTransition(.numericText())
            } else if model.hasQuery {
                Text(L10n.string("No matches"))
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}

private struct ConversationSearchIconButton: View {
    let systemImage: String
    let help: String
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background {
                    if isHovering, !isDisabled {
                        Circle().fill(Color(nsColor: .quaternarySystemFill))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

#Preview("Stepping through matches") {
    let model = ConversationSearchViewModel { _ in
        ["alpha", "beta", "gamma"].map {
            ConversationSearchEntry(messageId: $0, sender: "peer", searchableText: "lunch at \($0)")
        }
    }
    model.activate()
    model.query = "lunch"
    return ConversationSearchBar(model: model, onClose: {})
        .frame(width: 560)
}
