import SwiftUI

/// What an agent row can do, handed in by the conversation that shows it.
struct AgentRowActions {
    /// Whether a secret question can be answered here: only in a chat of the person and the agent.
    var canAnswerSecret: Bool
    /// A direct chat, where the agent hears every message; in a group it hears one that mentions it.
    var isDirectChat: Bool
    var send: @MainActor (AgentRequest) -> Void
    var isSending: @MainActor (AgentRequest) -> Bool
    var openThread: @MainActor (_ taskFirstEventIdHex: String) -> Void

    static let inert = AgentRowActions(
        canAnswerSecret: true, isDirectChat: true, send: { _ in }, isSending: { _ in false }, openThread: { _ in })
}

/// One agent item (kind 1201) at its latest version: its title, a badge for its state, and a body
/// drawn from its type. Approvals and questions that wait take answers here; a running turn
/// offers Stop. An item this app cannot read falls back to its title and plain text.
struct AgentItemRow: View {
    let message: MessageItem
    let item: AgentItem
    let timeLabel: String
    let actions: AgentRowActions
    /// Drawn inside another row (a waiting item lifted out of a subagent's thread).
    var isNested = false

    private var agent: MessageAgentContext { message.agent ?? MessageAgentContext() }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if item.firstEventMissing {
                    AgentCaption(text: L10n.string("Earlier activity"), systemImage: "clock.arrow.circlepath")
                }
                if agent.isOutsideItsThread {
                    AgentCaption(text: L10n.string("In a subagent’s thread"), systemImage: "arrow.turn.down.right")
                }
                AgentItemHeader(item: item, timeLabel: timeLabel)
                AgentItemBodyView(message: message, item: item, actions: actions)
                AgentRequestStatusList(requests: agent.requests, answeredBy: agent.answeredBy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: isNested ? .infinity : 620, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isNested ? WNColor.backgroundSecondary : WNColor.backgroundMessageIncoming)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(item.state == .waiting ? WNColor.borderPrimary : WNColor.borderTertiary)
            )
            .contextMenu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                } label: {
                    Label(L10n.string("Copy Text"), systemImage: "doc.on.doc")
                }
            }
            Spacer(minLength: isNested ? 0 : 24)
        }
        .padding(.horizontal, isNested ? 0 : 16)
    }
}

struct AgentCaption: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(WNColor.backgroundContentTertiary)
    }
}

private struct AgentItemHeader: View {
    let item: AgentItem
    let timeLabel: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: AgentItemPresentation.systemImage(for: item))
                .font(.callout.weight(.semibold))
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(width: 18)
            Text(verbatim: AgentItemPresentation.title(for: item))
                .font(.callout.weight(.semibold))
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            AgentStateBadge(state: item.state)
            Text(verbatim: timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(WNColor.backgroundContentTertiary)
        }
    }
}

struct AgentStateBadge: View {
    let state: AgentItemState

    var body: some View {
        HStack(spacing: 4) {
            if state == .running {
                ProgressView().controlSize(.mini)
            }
            Text(state.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(background))
        .accessibilityLabel(state.label)
    }

    private var foreground: Color {
        switch state {
        case .failed: WNColor.intentionErrorContent
        case .waiting: WNColor.intentionWarningContent
        default: WNColor.backgroundContentSecondary
        }
    }

    private var background: Color {
        switch state {
        case .failed: WNColor.intentionErrorBackground
        case .waiting: WNColor.intentionWarningBackground
        default: WNColor.fillTertiary
        }
    }
}

/// This account's presses on the item, pending until a version settles them, and who answered.
private struct AgentRequestStatusList: View {
    let requests: [AgentRequestStatus]
    let answeredBy: String?

    var body: some View {
        let pending = requests.filter { !$0.isSettled }
        if !pending.isEmpty || answeredBy != nil {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(pending, id: \.idHex) { request in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(
                            String(
                                format: L10n.string("You sent “%@”. Waiting for the agent…"),
                                request.label))
                    }
                }
                if let answeredBy, pending.isEmpty {
                    Label(
                        String(format: L10n.string("Answered by %@"), answeredBy),
                        systemImage: "checkmark.circle"
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(WNColor.backgroundContentSecondary)
        }
    }
}

// MARK: - Bodies

private struct AgentItemBodyView: View {
    let message: MessageItem
    let item: AgentItem
    let actions: AgentRowActions

    var body: some View {
        switch item.body {
        case .turn(let turn):
            AgentTurnBodyView(item: item, turn: turn, actions: actions)
        case .message:
            AgentPlainText(text: item.text)
        case .reasoning:
            AgentCollapsedText(label: L10n.string("Reasoning"), text: item.text, monospaced: false)
        case .tool(let tool):
            AgentToolBodyView(item: item, tool: tool)
        case .approval(let approval):
            AgentApprovalBodyView(message: message, item: item, approval: approval, actions: actions)
        case .question(let question):
            AgentQuestionBodyView(message: message, item: item, question: question, actions: actions)
        case .plan(let plan):
            AgentPlanBodyView(item: item, plan: plan)
        case .task(let task):
            AgentTaskBodyView(message: message, item: item, task: task, actions: actions)
        case .notice(let notice):
            AgentNoticeBodyView(item: item, notice: notice)
        case .error(let error):
            AgentErrorBodyView(item: item, error: error)
        case .session(let session):
            AgentSessionBodyView(item: item, session: session, actions: actions)
        case .unknown:
            AgentPlainText(text: item.text)
        }
    }
}

struct AgentPlainText: View {
    let text: String
    var lineLimit: Int? = 12

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(verbatim: AgentItemPresentation.bounded(trimmed))
                .font(.callout)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Text that starts collapsed: reasoning, command output, a diff.
struct AgentCollapsedText: View {
    let label: String
    let text: String
    var monospaced = true
    var note: String?
    @State private var isExpanded = false

    var body: some View {
        if !text.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    // Bounded at 360 points, so long output scrolls down as well as across.
                    ScrollView(monospaced ? [.horizontal, .vertical] : .vertical) {
                        Text(verbatim: AgentItemPresentation.bounded(text))
                            .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: monospaced, vertical: true)
                            .frame(maxWidth: monospaced ? nil : .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 360)
                    .background(RoundedRectangle(cornerRadius: 6).fill(WNColor.fillQuaternary))
                    if let note {
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(WNColor.intentionWarningContent)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(verbatim: label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}

private struct AgentMonospacedLine: View {
    let text: String
    var lineLimit = 3

    var body: some View {
        Text(verbatim: text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(WNColor.fillQuaternary))
    }
}

private struct AgentDetailLine: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(WNColor.backgroundContentTertiary)
            .lineLimit(2)
    }
}

private struct AgentTurnBodyView: View {
    let item: AgentItem
    let turn: AgentTurnBody
    let actions: AgentRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = AgentItemPresentation.turnSummary(item: item, turn: turn) {
                AgentDetailLine(text: summary)
            }
            AgentPlainText(text: item.text, lineLimit: 4)
            if item.state == .running {
                AgentStopButton(item: item, actions: actions)
            }
        }
    }
}

struct AgentStopButton: View {
    let item: AgentItem
    let actions: AgentRowActions

    private var request: AgentRequest {
        AgentRequest(
            agentAccountIdHex: item.agentAccountIdHex,
            targetEventIdHex: item.firstEventIdHex,
            action: .interrupt,
            content: L10n.string("Stop")
        )
    }

    var body: some View {
        Button(role: .destructive) {
            actions.send(request)
        } label: {
            Label(L10n.string("Stop"), systemImage: "stop.fill")
        }
        .controlSize(.small)
        .disabled(actions.isSending(request))
        .help(L10n.string("Stop the agent’s turn"))
    }
}

private struct AgentToolBodyView: View {
    let item: AgentItem
    let tool: AgentToolBody

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch tool.kind {
            case "command",
                "read" where tool.command != nil:
                if let command = tool.command { AgentMonospacedLine(text: command) }
                if let cwd = tool.cwd { AgentDetailLine(text: cwd) }
            case "edit":
                ForEach(Array((tool.changes ?? []).enumerated()), id: \.offset) { _, change in
                    AgentDetailLine(text: AgentItemPresentation.changeLine(change))
                }
                if tool.changes?.isEmpty ?? true { AgentPlainText(text: item.text, lineLimit: 3) }
            case "search":
                AgentMonospacedLine(text: tool.query ?? item.text)
            case "read":
                AgentMonospacedLine(text: tool.path ?? item.text)
            default:
                if let name = tool.name, !name.isEmpty { AgentDetailLine(text: name) }
                AgentPlainText(text: item.text, lineLimit: 3)
            }
            if let detail = AgentItemPresentation.toolResultLine(tool) {
                AgentDetailLine(text: detail)
            }
            if let error = tool.error, !error.isEmpty {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(WNColor.intentionErrorContent)
                    .lineLimit(4)
            }
            if tool.kind == "edit", let diff = AgentItemPresentation.diff(tool) {
                AgentCollapsedText(
                    label: L10n.string("Diff"), text: diff, note: AgentItemPresentation.diffCutNote(item))
            }
            if let input = tool.input, !input.isEmpty, tool.kind != "command" {
                AgentCollapsedText(label: L10n.string("Input"), text: input)
            }
            if let output = tool.output, !output.isEmpty {
                AgentCollapsedText(
                    label: L10n.string("Output"), text: output, note: AgentItemPresentation.outputCutNote(item, tool))
            } else if let note = AgentItemPresentation.outputCutNote(item, tool) {
                AgentDetailLine(text: note)
            }
        }
    }
}

private struct AgentApprovalBodyView: View {
    let message: MessageItem
    let item: AgentItem
    let approval: AgentApprovalBody
    let actions: AgentRowActions

    var body: some View {
        let hasPending = message.agent?.requests.contains { !$0.isSettled } ?? false
        VStack(alignment: .leading, spacing: 8) {
            if item.state == .waiting {
                AgentMonospacedLine(text: AgentItemPresentation.bounded(item.text), lineLimit: 8)
                AgentChoiceButtons(
                    item: item, choices: approval.choices, actions: actions, isDisabled: hasPending)
            } else {
                AgentPlainText(text: item.text, lineLimit: 4)
            }
        }
    }
}

private struct AgentChoiceButtons: View {
    let item: AgentItem
    let choices: [AgentChoice]
    let actions: AgentRowActions
    let isDisabled: Bool

    var body: some View {
        // Wraps onto as many lines as the labels need: Codex offers four, some long.
        AgentFlowLayout(spacing: 6) {
            ForEach(choices) { choice in
                let request = AgentRequest(
                    agentAccountIdHex: item.agentAccountIdHex,
                    targetEventIdHex: item.firstEventIdHex,
                    action: .choice(choice.id),
                    content: choice.label
                )
                Button(role: choice.effect == "deny" ? .destructive : nil) {
                    actions.send(request)
                } label: {
                    Text(verbatim: choice.label)
                        .lineLimit(2)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isDisabled || actions.isSending(request))
            }
        }
    }
}

private struct AgentQuestionBodyView: View {
    let message: MessageItem
    let item: AgentItem
    let question: AgentQuestionBody
    let actions: AgentRowActions

    var body: some View {
        if item.state == .waiting {
            if question.asksSecret && !actions.canAnswerSecret {
                VStack(alignment: .leading, spacing: 6) {
                    AgentQuestionList(question: question)
                    Label(
                        L10n.string("This asks for a secret, and others read this chat. Answer it at the terminal."),
                        systemImage: "lock"
                    )
                    .font(.callout)
                    .foregroundStyle(WNColor.intentionWarningContent)
                }
            } else if question.answeredByMessage {
                VStack(alignment: .leading, spacing: 6) {
                    AgentQuestionList(question: question)
                    Label(
                        actions.isDirectChat
                            ? L10n.string("Reply with a message: the agent takes your next one.")
                            : L10n.string(
                                "Reply with a message that mentions the agent: in a group it hears only those."),
                        systemImage: "text.bubble"
                    )
                    .font(.caption)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            } else {
                AgentQuestionForm(
                    item: item,
                    question: question,
                    actions: actions,
                    isDisabled: message.agent?.requests.contains { !$0.isSettled } ?? false
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                AgentQuestionList(question: question)
                AgentPlainText(text: item.text, lineLimit: 4)
            }
        }
    }
}

/// The questions and their options, read only.
private struct AgentQuestionList: View {
    let question: AgentQuestionBody

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(question.questions) { asked in
                VStack(alignment: .leading, spacing: 2) {
                    AgentAskedHeading(asked: asked)
                    ForEach(asked.offered) { option in
                        Text(verbatim: "• \(option.label)")
                            .font(.callout)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }
            }
        }
    }
}

private struct AgentAskedHeading: View {
    let asked: AgentAsked

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let header = asked.header, !header.isEmpty {
                Text(verbatim: header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }
            HStack(spacing: 4) {
                if asked.isSecret {
                    Image(systemName: "lock.fill").font(.caption)
                }
                Text(verbatim: asked.text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Options to pick, or a box to type in, for each question, and one Send for them all.
private struct AgentQuestionForm: View {
    let item: AgentItem
    let question: AgentQuestionBody
    let actions: AgentRowActions
    let isDisabled: Bool
    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(question.questions) { asked in
                VStack(alignment: .leading, spacing: 6) {
                    AgentAskedHeading(asked: asked)
                    if !asked.offered.isEmpty {
                        AgentFlowLayout(spacing: 6) {
                            ForEach(asked.offered) { option in
                                let isOn = picked[asked.id]?.contains(option.id) == true
                                Toggle(isOn: binding(asked: asked, option: option.id)) {
                                    Text(verbatim: option.label).lineLimit(2)
                                }
                                .toggleStyle(.button)
                                .buttonStyle(.bordered)
                                .help(option.description ?? "")
                                .accessibilityValue(isOn ? L10n.string("Selected") : "")
                            }
                        }
                    }
                    if asked.takesText {
                        Group {
                            if asked.isSecret {
                                SecureField(L10n.string("Answer"), text: textBinding(asked.id))
                            } else {
                                TextField(L10n.string("Answer"), text: textBinding(asked.id), axis: .vertical)
                                    .lineLimit(1...5)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Button(L10n.string("Send Answer")) {
                actions.send(request)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled || replies.isEmpty || actions.isSending(request))
        }
    }

    private var replies: [AgentQuestionReply] {
        question.questions.compactMap { asked in
            let options = asked.offered.map(\.id).filter { picked[asked.id]?.contains($0) == true }
            let text = typed[asked.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let answerText = (text?.isEmpty ?? true) ? nil : typed[asked.id]
            guard !options.isEmpty || answerText != nil else { return nil }
            return AgentQuestionReply(question: asked.id, options: options, text: answerText)
        }
    }

    private var request: AgentRequest {
        AgentRequest(
            agentAccountIdHex: item.agentAccountIdHex,
            targetEventIdHex: item.firstEventIdHex,
            action: .questions(replies),
            // Never the answer itself: a secret one would reach every member.
            content: L10n.string("Answered")
        )
    }

    private func binding(asked: AgentAsked, option: String) -> Binding<Bool> {
        Binding(
            get: { picked[asked.id]?.contains(option) == true },
            set: { isOn in
                var selection = asked.allowsMultiple ? picked[asked.id] ?? [] : []
                if isOn { selection.insert(option) } else { selection.remove(option) }
                picked[asked.id] = selection
            }
        )
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { typed[id] = $0 })
    }
}

private struct AgentPlanBodyView: View {
    let item: AgentItem
    let plan: AgentPlanBody

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let entries = plan.entries, !entries.isEmpty {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: AgentItemPresentation.planSymbol(entry.state))
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                        Text(verbatim: entry.text)
                            .font(.callout)
                            .strikethrough(entry.state == "done", color: WNColor.backgroundContentTertiary)
                            .foregroundStyle(
                                entry.state == "done"
                                    ? WNColor.backgroundContentTertiary : WNColor.backgroundContentPrimary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(AgentItemPresentation.planStateLabel(entry.state))
                }
            } else {
                AgentPlainText(text: plan.text ?? item.text)
            }
        }
    }
}

private struct AgentTaskBodyView: View {
    let message: MessageItem
    let item: AgentItem
    let task: AgentTaskBody
    let actions: AgentRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentPlainText(text: task.description ?? item.text, lineLimit: 4)
            if let usage = task.usage, let line = AgentItemPresentation.usageLine(usage) {
                AgentDetailLine(text: line)
            }
            if item.isSubagentTask || message.agent?.threadSummary != nil {
                let summary = message.agent?.threadSummary ?? AgentThreadSummary()
                HStack(spacing: 10) {
                    Button {
                        actions.openThread(item.firstEventIdHex)
                    } label: {
                        Label(
                            summary.rowCount == 0
                                ? L10n.string("Open Thread")
                                : String(format: L10n.string("Open Thread (%@)"), String(summary.rowCount)),
                            systemImage: "bubble.left.and.text.bubble.right"
                        )
                    }
                    .controlSize(.small)
                    if item.state == .running {
                        AgentStopButton(item: item, actions: actions)
                    }
                }
                if !summary.waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.string("Needs you in this subagent’s thread"), systemImage: "exclamationmark.bubble")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WNColor.intentionWarningContent)
                        ForEach(summary.waiting) { waiting in
                            if let waitingItem = waiting.agent?.item {
                                AgentItemRow(
                                    message: waiting,
                                    item: waitingItem,
                                    timeLabel: "",
                                    actions: actions,
                                    isNested: true
                                )
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(WNColor.intentionWarningBackground))
                }
            }
        }
    }
}

private struct AgentNoticeBodyView: View {
    let item: AgentItem
    let notice: AgentNoticeBody

    var body: some View {
        if notice.kind == "refused" {
            Label {
                Text(verbatim: AgentItemPresentation.refusedLine(item: item, notice: notice))
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.callout)
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .lineLimit(3)
        } else {
            Text(verbatim: AgentItemPresentation.oneLine(item.text))
                .font(.callout)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
                .help(item.text)
        }
    }
}

private struct AgentErrorBodyView: View {
    let item: AgentItem
    let error: AgentErrorBody

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: AgentItemPresentation.bounded(item.text.isEmpty ? item.title : item.text))
                .font(.callout)
                .foregroundStyle(WNColor.intentionErrorContent)
                .textSelection(.enabled)
            if let line = AgentItemPresentation.errorDetail(error) {
                AgentDetailLine(text: line)
            }
        }
    }
}

/// The session's settings, actions and slash commands, kept compact: each setting is a menu of
/// the values it accepts, each action a button, the commands a collapsed list.
private struct AgentSessionBodyView: View {
    let item: AgentItem
    let session: AgentSessionBody
    let actions: AgentRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentSessionControls(item: item, session: session, actions: actions)
            if let commands = session.commands, !commands.isEmpty {
                AgentCollapsedText(
                    label: String(format: L10n.string("Slash commands: %@"), String(commands.count)),
                    text: commands.map(AgentItemPresentation.commandLine).joined(separator: "\n")
                )
            }
        }
    }
}

/// The session's settings and actions, and New Session. Shared by the session row and the bar
/// above the composer.
struct AgentSessionControls: View {
    let item: AgentItem
    let session: AgentSessionBody
    let actions: AgentRowActions

    var body: some View {
        AgentFlowLayout(spacing: 6) {
            ForEach(session.settings ?? []) { setting in
                AgentSettingMenu(item: item, setting: setting, actions: actions)
            }
            ForEach(session.actions ?? []) { action in
                Button(action.label) {
                    actions.send(
                        AgentRequest(
                            agentAccountIdHex: item.agentAccountIdHex,
                            targetEventIdHex: nil,
                            action: .own(action.id),
                            content: action.label
                        ))
                }
                .help(action.description ?? "")
                .controlSize(.small)
            }
            Button {
                actions.send(
                    AgentRequest(
                        agentAccountIdHex: item.agentAccountIdHex,
                        targetEventIdHex: nil,
                        action: .newSession,
                        content: L10n.string("New session")
                    ))
            } label: {
                Label(L10n.string("New Session"), systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
        }
    }
}

private struct AgentSettingMenu: View {
    let item: AgentItem
    let setting: AgentSetting
    let actions: AgentRowActions
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        let title = "\(setting.label): \(setting.value ?? "—")"
        Group {
            if let options = setting.options, !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button {
                            send(option)
                        } label: {
                            if option == setting.value {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(verbatim: option)
                            }
                        }
                    }
                } label: {
                    Text(verbatim: title)
                }
                .menuStyle(.button)
            } else {
                Button {
                    draft = setting.value ?? ""
                    isEditing = true
                } label: {
                    Text(verbatim: title)
                }
                .popover(isPresented: $isEditing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: setting.label).font(.headline)
                        TextField(setting.label, text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                            .onSubmit(submitDraft)
                        HStack {
                            Spacer()
                            Button(L10n.string("Cancel")) { isEditing = false }
                            Button(L10n.string("Set"), action: submitDraft)
                                .keyboardShortcut(.defaultAction)
                                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .controlSize(.small)
        .help(setting.approve == true ? L10n.string("Changing this needs the right to approve") : "")
    }

    private func submitDraft() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        isEditing = false
        send(value)
    }

    private func send(_ value: String) {
        actions.send(
            AgentRequest(
                agentAccountIdHex: item.agentAccountIdHex,
                targetEventIdHex: nil,
                action: .set(setting: setting.id, value: value),
                content: "\(setting.label): \(value)"
            ))
    }
}

/// Lays its children out left to right, wrapping onto new lines.
struct AgentFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = added
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#if DEBUG
    #Preview("Agent items") {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AgentPreviewFixtures.transcript.mainItems) { row in
                    if let item = row.message.agent?.item {
                        AgentItemRow(message: row.message, item: item, timeLabel: "14:02", actions: .inert)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .frame(width: 720, height: 900)
    }
#endif
