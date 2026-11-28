import Foundation

/// The words and symbols an agent row draws from its item. Pure, so tests can read them.
nonisolated enum AgentItemPresentation {
    /// The most of any one text a row lays out; the rest is left for Copy Text.
    static let maxDisplayedCharacters = 20_000

    static func bounded(_ text: String) -> String {
        guard text.count > maxDisplayedCharacters else { return text }
        return String(text.prefix(maxDisplayedCharacters)) + "…"
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    static func title(for item: AgentItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return L10n.string("Agent activity")
    }

    static func systemImage(for item: AgentItem) -> String {
        switch item.body {
        case .turn: return "arrow.triangle.2.circlepath"
        case .message: return "text.bubble"
        case .reasoning: return "brain"
        case .tool(let tool):
            switch tool.kind {
            case "command": return "terminal"
            case "edit": return "pencil"
            case "read": return "doc.text"
            case "search": return "magnifyingglass"
            case "fetch": return "globe"
            case "mcp": return "puzzlepiece.extension"
            case "subagent": return "person.2"
            default: return "wrench.and.screwdriver"
            }
        case .approval: return "hand.raised"
        case .question: return "questionmark.bubble"
        case .plan: return "checklist"
        case .task: return "person.2"
        case .notice(let notice): return notice.kind == "refused" ? "hand.raised.slash" : "info.circle"
        case .error: return "exclamationmark.triangle"
        case .session: return "slider.horizontal.3"
        case .unknown: return "waveform.path"
        }
    }

    /// Started: who or what started it. Ended: how it ended, how long it took, what it used.
    static func turnSummary(item: AgentItem, turn: AgentTurnBody) -> String? {
        var parts: [String] = []
        if item.state.isOpen {
            switch turn.started_by {
            case "user": parts.append(L10n.string("Started by a message"))
            case "agent": parts.append(L10n.string("Started by the agent"))
            case "control": parts.append(L10n.string("Started by a control"))
            default: break
            }
        } else {
            switch item.state {
            case .done: parts.append(L10n.string("Finished"))
            case .failed: parts.append(L10n.string("Failed"))
            case .cancelled: parts.append(L10n.string("Stopped"))
            case .declined: parts.append(L10n.string("Declined"))
            case .running, .waiting: break
            }
            if let duration = turn.duration_ms { parts.append(durationText(milliseconds: duration)) }
            if let usage = turn.usage, let line = usageLine(usage) { parts.append(line) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func usageLine(_ usage: AgentUsage) -> String? {
        switch (usage.input_tokens, usage.output_tokens) {
        case (let input?, let output?):
            return String(
                format: L10n.string("%@ tokens in, %@ out"), compactNumber(input), compactNumber(output))
        case (let input?, nil):
            return String(format: L10n.string("%@ tokens in"), compactNumber(input))
        case (nil, let output?):
            return String(format: L10n.string("%@ tokens out"), compactNumber(output))
        case (nil, nil):
            return nil
        }
    }

    static func compactNumber(_ value: UInt64) -> String {
        Int(clamping: value).formatted(.number.notation(.compactName))
    }

    static func durationText(milliseconds: UInt64) -> String {
        let duration = Duration.milliseconds(Int64(clamping: milliseconds))
        if milliseconds < 1_000 {
            return duration.formatted(.units(allowed: [.milliseconds], width: .narrow))
        }
        return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    /// Exit code and duration, once a tool has finished.
    static func toolResultLine(_ tool: AgentToolBody) -> String? {
        var parts: [String] = []
        if let exitCode = tool.exit_code {
            parts.append(String(format: L10n.string("Exit code %@"), String(exitCode)))
        }
        if let duration = tool.duration_ms, duration > 0 { parts.append(durationText(milliseconds: duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func changeLine(_ change: AgentToolChange) -> String {
        switch change.change {
        case "add": return String(format: L10n.string("Added %@"), change.path)
        case "delete": return String(format: L10n.string("Deleted %@"), change.path)
        default: return String(format: L10n.string("Changed %@"), change.path)
        }
    }

    static func diff(_ tool: AgentToolBody) -> String? {
        let changes = tool.changes ?? []
        guard !changes.isEmpty else { return nil }
        return changes.map { "--- \($0.path)\n\($0.diff)" }.joined(separator: "\n")
    }

    /// Where the core cut a command's output to fit the 64 KB limit (`cut` tag `output`).
    static func outputCutNote(_ item: AgentItem, _ tool: AgentToolBody) -> String? {
        guard let full = item.cuts["output"] else { return nil }
        let shown = tool.output?.count ?? 0
        return String(
            format: L10n.string("Output cut: showing %@ of %@ characters."), compactNumber(UInt64(shown)),
            compactNumber(full))
    }

    static func diffCutNote(_ item: AgentItem) -> String? {
        if let cut = item.cuts["diffs"] {
            return String(format: L10n.string("Diffs cut to fit: %@"), String(cut))
        }
        if let cut = item.cuts["changes"] {
            return String(format: L10n.string("Only some of %@ changed files are shown."), String(cut))
        }
        return nil
    }

    static func refusedLine(item: AgentItem, notice: AgentNoticeBody) -> String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        switch notice.reason {
        case "not_allowed": return L10n.string("Not acted on: not allowed.")
        case "busy": return L10n.string("Not acted on: the agent is busy.")
        case "not_supported": return L10n.string("Not acted on: not supported by this agent.")
        case "no_effect": return L10n.string("Not acted on: it had no effect.")
        default: return L10n.string("Not acted on.")
        }
    }

    static func errorDetail(_ error: AgentErrorBody) -> String? {
        var parts: [String] = []
        if let request = error.request, !request.isEmpty { parts.append(request) }
        if let code = error.code { parts.append(String(format: L10n.string("Code %@"), String(code))) }
        if error.will_retry == true { parts.append(L10n.string("Retrying")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func planSymbol(_ state: String) -> String {
        switch state {
        case "done": "checkmark.circle.fill"
        case "running": "circle.dotted.circle"
        default: "circle"
        }
    }

    static func planStateLabel(_ state: String) -> String {
        switch state {
        case "done": L10n.string("Done")
        case "running": L10n.string("Running")
        default: L10n.string("Not started")
        }
    }

    static func commandLine(_ command: AgentCommand) -> String {
        var line = "/\(command.name)"
        if let hint = command.hint, !hint.isEmpty { line += " \(hint)" }
        if let description = command.description, !description.isEmpty { line += "  — \(description)" }
        return line
    }
}
