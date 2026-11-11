import SwiftUI

/// The in-conversation search strip pinned under the conversation header: the field, where the
/// cursor stands among the matches, and the controls that step through them.
///
/// Return and ⌘G step to the next older match, ⇧⌘G to the next newer one, and Escape closes.
struct ConversationSearchBar: View {
    @Bindable var model: ConversationSearchViewModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MessagesSearchField(
                text: $model.query,
                accessibilityIdentifier: "conversation.search.field",
                placeholder: L10n.string("Search messages"),
                autofocus: true,
                focusRequest: model.focusRequest
            )
            .onSubmit(model.goToOlderMatch)
            .onExitCommand(perform: onClose)

            ConversationSearchStatus(model: model)

            HStack(spacing: 6) {
                ConversationSearchControlButton(
                    systemImage: "chevron.up",
                    help: L10n.string("Previous match"),
                    shortcut: KeyboardShortcut("g", modifiers: .command),
                    action: model.goToOlderMatch
                )
                ConversationSearchControlButton(
                    systemImage: "chevron.down",
                    help: L10n.string("Next match"),
                    shortcut: KeyboardShortcut("g", modifiers: [.command, .shift]),
                    action: model.goToNewerMatch
                )
            }
            .disabled(!model.canStep)

            ConversationSearchControlButton(
                systemImage: "xmark",
                help: L10n.string("Close"),
                shortcut: nil,
                action: onClose
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityIdentifier("conversation.search")
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
        .wnFont(.medium12)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(WNColor.backgroundContentSecondary)
    }
}

private struct ConversationSearchControlButton: View {
    let systemImage: String
    let help: String
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .wnFont(.bold12)
                .frame(width: 28, height: 28)
                .background { MessagesCircleControlBackground() }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
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
