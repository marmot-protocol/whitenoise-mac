import SwiftUI

/// A subagent's thread: everything it did, drawn as the main chat draws the agent's own work, and
/// its words. A nested subagent's row opens its own thread on top; Back returns.
struct AgentThreadSheet: View {
    /// The subagent's `task` row, when the window holds it.
    let task: MessageItem?
    let rows: [MessageItem]
    let depth: Int
    let actions: AgentRowActions
    let timeLabel: (MessageItem) -> String
    let onBack: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if depth > 1 {
                    Button(action: onBack) {
                        Label(L10n.string("Back"), systemImage: "chevron.left")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Subagent"))
                        .font(.caption)
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                    Text(verbatim: title)
                        .font(.headline)
                        .lineLimit(2)
                }
                Spacer()
                if let item = task?.agent?.item {
                    AgentStateBadge(state: item.state)
                    if item.state == .running {
                        AgentStopButton(item: item, actions: actions)
                    }
                }
                Button(L10n.string("Done"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if rows.isEmpty {
                Text(L10n.string("Nothing in this thread yet."))
                    .font(.callout)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(rows) { row in
                                AgentThreadRow(message: row, timeLabel: timeLabel(row), actions: actions)
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, 14)
                    }
                    .onAppear { proxy.scrollTo(rows.last?.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 640)
    }

    private var title: String {
        guard let item = task?.agent?.item else { return L10n.string("Subagent") }
        if case .task(let body) = item.body, let description = body.description, !description.isEmpty {
            return AgentItemPresentation.oneLine(description)
        }
        let text = AgentItemPresentation.oneLine(item.text)
        return text.isEmpty ? AgentItemPresentation.title(for: item) : text
    }
}

/// One row of a thread: an item, or words (the subagent's, or a person's reply).
private struct AgentThreadRow: View {
    let message: MessageItem
    let timeLabel: String
    let actions: AgentRowActions

    var body: some View {
        if let item = message.agent?.item {
            AgentItemRow(message: message, item: item, timeLabel: timeLabel, actions: actions)
        } else {
            AgentWordsRow(message: message, timeLabel: timeLabel)
                .padding(.horizontal, 16)
        }
    }
}

/// Words in a thread, or a kind-1201 row MDK could not read: the sender and the plain text.
struct AgentWordsRow: View {
    let message: MessageItem
    let timeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: message.senderName)
                    .font(.caption.weight(.semibold))
                Text(verbatim: timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }
            Text(verbatim: AgentItemPresentation.bounded(message.body))
                .font(.callout)
                .textSelection(.enabled)
                .foregroundStyle(
                    message.agent?.isCommentary == true
                        ? WNColor.backgroundContentSecondary : WNColor.backgroundContentPrimary)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}

#if DEBUG
    #Preview("Subagent thread") {
        let transcript = AgentPreviewFixtures.transcript
        let taskId = AgentPreviewFixtures.eventId(10)
        AgentThreadSheet(
            task: AgentPreviewFixtures.messages.first { $0.id == taskId },
            rows: transcript.threads[taskId] ?? [],
            depth: 1,
            actions: .inert,
            timeLabel: { _ in "14:02" },
            onBack: {},
            onClose: {}
        )
    }
#endif
