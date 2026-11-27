import SwiftUI

/// A subagent's thread: its header (title, state, Stop, Back, Done) above `content`, which the
/// conversation fills with its own transcript of the thread's rows, so a reply's attachments,
/// stickers, reactions and reply previews draw exactly as in the main chat. A nested subagent's
/// row opens its own thread on top; Back returns.
struct AgentThreadSheet<Content: View>: View {
    /// The subagent's `task` row, when the window holds it.
    let task: MessageItem?
    let isEmpty: Bool
    let depth: Int
    let actions: AgentRowActions
    let onBack: () -> Void
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

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
                    Text(verbatim: AgentThreadSheetTitle.text(for: task))
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
            if isEmpty {
                Text(L10n.string("Nothing in this thread yet."))
                    .font(.callout)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content()
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 640)
    }
}

/// The sheet's title: the subagent's task description, else its text, else its type.
nonisolated enum AgentThreadSheetTitle {
    static func text(for task: MessageItem?) -> String {
        guard let item = task?.agent?.item else { return L10n.string("Subagent") }
        if case .task(let body) = item.body, let description = body.description, !description.isEmpty {
            return AgentItemPresentation.oneLine(description)
        }
        let text = AgentItemPresentation.oneLine(item.text)
        return text.isEmpty ? AgentItemPresentation.title(for: item) : text
    }
}

#if DEBUG
    #Preview("Subagent thread") {
        let transcript = AgentPreviewFixtures.transcript
        let taskId = AgentPreviewFixtures.eventId(10)
        let rows = transcript.threads[taskId] ?? []
        AgentThreadSheet(
            task: AgentPreviewFixtures.messages.first { $0.id == taskId },
            isEmpty: rows.isEmpty,
            depth: 1,
            actions: .inert,
            onBack: {},
            onClose: {},
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            if let item = row.agent?.item {
                                AgentItemRow(message: row, item: item, timeLabel: "14:02", actions: .inert)
                            }
                        }
                    }
                    .padding(.vertical, 14)
                }
            })
    }
#endif
