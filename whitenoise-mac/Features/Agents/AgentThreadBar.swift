import SwiftUI

/// The bar over the conversation pane while a subagent's thread fills it: Back, the subagent's
/// task, its state and Stop. The thread's rows draw in the conversation's own transcript, so
/// everything the main chat does (reading, images, sheets, search) works the same there. A nested
/// subagent's row opens its own thread; Back returns one level, to the main chat last.
struct AgentThreadBar: View {
    /// The subagent's `task` row, when the window holds it.
    let task: MessageItem?
    let isEmpty: Bool
    let actions: AgentRowActions
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Label(L10n.string("Back"), systemImage: "chevron.left")
                }
                .help(L10n.string("Back"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string("Subagent"))
                        .font(.caption)
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                    Text(verbatim: Self.title(for: task))
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                if let item = task?.agent?.item {
                    AgentStateBadge(state: item.state)
                    if item.state == .running {
                        AgentStopButton(item: item, actions: actions)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if isEmpty {
                Text(L10n.string("Nothing in this thread yet."))
                    .font(.callout)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
    }

    /// The subagent's task description, else its text, else its type.
    static func title(for task: MessageItem?) -> String {
        guard let item = task?.agent?.item else { return L10n.string("Subagent") }
        if case .task(let body) = item.body, let description = body.description, !description.isEmpty {
            return AgentItemPresentation.oneLine(description)
        }
        let text = AgentItemPresentation.oneLine(item.text)
        return text.isEmpty ? AgentItemPresentation.title(for: item) : text
    }
}

#if DEBUG
    #Preview("Subagent thread bar") {
        let taskId = AgentPreviewFixtures.eventId(10)
        VStack(spacing: 0) {
            AgentThreadBar(
                task: AgentPreviewFixtures.messages.first { $0.id == taskId },
                isEmpty: false,
                actions: .inert,
                onBack: {}
            )
            Spacer()
        }
        .frame(width: 640, height: 200)
    }
#endif
