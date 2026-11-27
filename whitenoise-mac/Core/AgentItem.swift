import Foundation
import MarmotKit

// Agent items (marmot-agents, kinds 1201 and 1202).
//
// An AI agent in a chat sends one kind-1201 item per turn, tool call, approval and so on, and
// edits it in place as it changes. MDK applies the edits and keeps one timeline row per item,
// holding its latest version (`TimelineMessageRecordFfi.agentItem`); this file reads that version
// into app values. People answer approvals and questions, and press controls such as Stop, by
// sending kind 1202 (`AgentRequest`). The shapes are marmot-agents'
// `crates/marmot-agent-events/src/body.rs` and `docs/design/agent-kinds.md`.
//
// Privacy: everything here is message content. Never log it.

/// What a timeline row says about agents: the item it carries, or the agent's words.
nonisolated struct MessageAgentContext: Hashable, Sendable {
    /// The item's latest version, for a kind-1201 row MDK could read.
    var item: AgentItem?
    /// A kind-1201 row MDK could not read as an item, such as the old shape today's Hermes plugin
    /// sends. It shows as a simple row with its plain content, never disappears.
    var isUnreadableItem = false
    /// The turn of the agent's words (a chat message or thread comment with a `turn` tag).
    var wordsTurn: String?
    /// The agent's remark made while it works (`["phase","commentary"]`): drawn quieter, and MDK
    /// never alerts for it.
    var isCommentary = false
    /// Where the row sits in a NIP-22 thread, as MDK placed it; nil outside threads.
    var thread: AgentThreadRef?

    // Set by `AgentTranscript` from the whole window and this account's sends, so a change to
    // any of them changes the row's value and the transcript re-measures it.

    /// This account's presses on this item (or, on the session row, its untargeted controls).
    var requests: [AgentRequestStatus] = []
    /// Who answered this approval or question, once a version settles an answer whose sender is
    /// known.
    var answeredBy: String?
    /// For a subagent's `task` row: what its thread holds.
    var threadSummary: AgentThreadSummary?
    /// An item in a subagent's thread whose `task` row is not loaded, so it shows in the main chat.
    var isOutsideItsThread = false

    var isAgentWords: Bool { wordsTurn != nil || isCommentary }

    static func make(record: TimelineMessageRecordFfi) -> MessageAgentContext? {
        let thread = record.thread.map {
            AgentThreadRef(root: $0.rootMessageIdHex, parent: $0.parentMessageIdHex)
        }
        guard record.kind == AgentItem.itemKind || thread != nil || record.kind == 9 else { return nil }
        if record.kind == AgentItem.itemKind {
            guard !record.deleted, let ffi = record.agentItem else {
                return MessageAgentContext(item: nil, isUnreadableItem: !record.deleted, thread: thread)
            }
            let item = AgentItem(
                ffi: ffi,
                firstEventIdHex: record.messageIdHex,
                senderAccountIdHex: record.sender,
                text: record.plaintext,
                tags: record.tags.map(\.values),
                firstEventMissing: record.agentItemFirstEventMissing
            )
            return MessageAgentContext(item: item, thread: thread)
        }
        let tags = record.tags.map(\.values)
        let turn = AgentItem.tagValue("turn", in: tags)
        let isCommentary = tags.contains { $0.count >= 2 && $0[0] == "phase" && $0[1] == "commentary" }
        guard turn != nil || isCommentary || thread != nil else { return nil }
        return MessageAgentContext(wordsTurn: turn, isCommentary: isCommentary, thread: thread)
    }
}

/// One press of this account's, as a row shows it.
nonisolated struct AgentRequestStatus: Hashable, Sendable {
    let idHex: String
    let label: String
    /// A later item version lists it in `settles`.
    let isSettled: Bool
}

/// What a subagent's thread holds, for its `task` row in the main chat.
nonisolated struct AgentThreadSummary: Hashable, Sendable {
    /// Rows in the thread, nested subagents' included.
    var rowCount = 0
    /// Approvals and questions waiting anywhere in the thread: shown on the row, so they can be
    /// answered from the main chat.
    var waiting: [MessageItem] = []
}

nonisolated struct AgentThreadRef: Hashable, Sendable {
    /// The top-level subagent's `task` item (NIP-22's `E`).
    let root: String
    /// The `task` item of the subagent this row belongs to (NIP-22's `e`); the root when top level.
    let parent: String
}

nonisolated enum AgentItemState: String, Hashable, Sendable {
    case running, waiting, done, failed, declined, cancelled

    init(_ ffi: AgentItemStateFfi) {
        switch ffi {
        case .running: self = .running
        case .waiting: self = .waiting
        case .done: self = .done
        case .failed: self = .failed
        case .declined: self = .declined
        case .cancelled: self = .cancelled
        }
    }

    var isOpen: Bool { self == .running || self == .waiting }

    var label: String {
        switch self {
        case .running: L10n.string("Running")
        case .waiting: L10n.string("Waiting")
        case .done: L10n.string("Done")
        case .failed: L10n.string("Failed")
        case .declined: L10n.string("Declined")
        case .cancelled: L10n.string("Cancelled")
        }
    }
}

/// One agent item at its latest version.
nonisolated struct AgentItem: Hashable, Sendable {
    static let itemKind: UInt64 = 1201
    static let requestKind: UInt64 = 1202

    /// The item's first event: what an answer's `e` names, and the row's message id.
    let firstEventIdHex: String
    /// The agent: the item's sender, what an answer's `p` names.
    let agentAccountIdHex: String
    let version: UInt64
    let state: AgentItemState
    let title: String
    /// The plain rendering, readable on its own.
    let text: String
    let harness: String
    let itemId: String
    let seq: UInt64
    /// One of the eleven item types, as sent; unknown types fall back to `title` and `text`.
    let type: String
    let body: AgentItemBody
    let session: String?
    let turn: String?
    let startedByMessageIdHex: String?
    /// The answers and controls (kind 1202 event ids) this version shows the effect of.
    let settles: [String]
    let alerts: Bool
    /// The device does not hold the first event (it began before this member joined): the row
    /// shows "earlier activity" above the latest version.
    let firstEventMissing: Bool
    /// For a subagent's work: the `item_id` of its `task` item.
    let subagent: String?
    /// Fields the core cut to fit 64 KB: `output` → full length, `diffs` → how many, and others.
    let cuts: [String: UInt64]

    init(
        ffi: AgentItemFfi,
        firstEventIdHex: String,
        senderAccountIdHex: String,
        text: String,
        tags: [[String]],
        firstEventMissing: Bool
    ) {
        self.firstEventIdHex = firstEventIdHex
        self.agentAccountIdHex = senderAccountIdHex
        self.version = ffi.version
        self.state = AgentItemState(ffi.state)
        self.title = ffi.title
        self.text = text
        self.harness = ffi.harness
        self.itemId = ffi.itemId
        self.seq = ffi.seq
        self.type = ffi.itemType
        self.body = AgentItemBody.decode(type: ffi.itemType, fieldsJSON: ffi.fieldsJson)
        self.session = ffi.session
        self.turn = ffi.turn
        self.startedByMessageIdHex = ffi.startedByMessageIdHex
        self.settles = ffi.settles.map { $0.lowercased() }
        self.alerts = ffi.alerts
        self.firstEventMissing = firstEventMissing
        self.subagent = Self.tagValue("subagent", in: tags)
        var cuts: [String: UInt64] = [:]
        for tag in tags where tag.count >= 3 && tag[0] == "cut" {
            if let length = UInt64(tag[2]) { cuts[tag[1]] = length }
        }
        self.cuts = cuts
    }

    static func tagValue(_ name: String, in tags: [[String]]) -> String? {
        tags.first { $0.first == name && $0.count >= 2 }?[1]
    }

    /// A `task` item for a subagent: a row with a thread under it.
    var isSubagentTask: Bool {
        if case .task(let task) = body { return task.kind == "subagent" }
        return false
    }
}

// MARK: - Bodies

nonisolated enum AgentItemBody: Hashable, Sendable {
    case turn(AgentTurnBody)
    case message(AgentMessageBody)
    case reasoning
    case tool(AgentToolBody)
    case approval(AgentApprovalBody)
    case question(AgentQuestionBody)
    case plan(AgentPlanBody)
    case task(AgentTaskBody)
    case notice(AgentNoticeBody)
    case error(AgentErrorBody)
    case session(AgentSessionBody)
    /// An item type or a body this app cannot read: drawn from `title` and the plain text.
    case unknown

    /// `fieldsJSON` is `{"type": ..., "body": {...}}`. The type MDK read wins over the JSON's.
    static func decode(type: String, fieldsJSON: String) -> AgentItemBody {
        guard fieldsJSON.utf8.count <= 128 * 1024,
            let data = fieldsJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        let body = root["body"] as? [String: Any] ?? [:]
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let decoder = JSONDecoder()
        func read<T: Decodable>(_ type: T.Type) -> T? { try? decoder.decode(T.self, from: bodyData) }
        switch type {
        case "turn": return read(AgentTurnBody.self).map(AgentItemBody.turn) ?? .unknown
        case "message": return read(AgentMessageBody.self).map(AgentItemBody.message) ?? .unknown
        case "reasoning": return .reasoning
        case "tool":
            guard var tool = read(AgentToolBody.self) else { return .unknown }
            tool.input = (body["input"]).flatMap(AgentToolBody.prettyJSON)
            return .tool(tool)
        case "approval": return read(AgentApprovalBody.self).map(AgentItemBody.approval) ?? .unknown
        case "question": return read(AgentQuestionBody.self).map(AgentItemBody.question) ?? .unknown
        case "plan": return read(AgentPlanBody.self).map(AgentItemBody.plan) ?? .unknown
        case "task": return read(AgentTaskBody.self).map(AgentItemBody.task) ?? .unknown
        case "notice": return read(AgentNoticeBody.self).map(AgentItemBody.notice) ?? .unknown
        case "error": return read(AgentErrorBody.self).map(AgentItemBody.error) ?? .unknown
        case "session": return read(AgentSessionBody.self).map(AgentItemBody.session) ?? .unknown
        default: return .unknown
        }
    }
}

nonisolated struct AgentUsage: Codable, Hashable, Sendable {
    var input_tokens: UInt64?
    var output_tokens: UInt64?
}

nonisolated struct AgentTurnBody: Codable, Hashable, Sendable {
    /// `user`, `agent` or `control`.
    var started_by: String?
    var duration_ms: UInt64?
    var usage: AgentUsage?
}

nonisolated struct AgentMessageBody: Codable, Hashable, Sendable {
    var phase: String?
}

nonisolated struct AgentToolChange: Codable, Hashable, Sendable {
    var path: String
    var diff: String
    /// `add`, `update` or `delete`.
    var change: String?
}

nonisolated struct AgentToolBody: Codable, Hashable, Sendable {
    /// `command`, `edit`, `read`, `search`, `fetch`, `mcp`, `subagent` or `other`.
    var kind: String
    var name: String?
    var command: String?
    var cwd: String?
    var exit_code: Int64?
    var duration_ms: UInt64?
    var output: String?
    var changes: [AgentToolChange]?
    var query: String?
    var path: String?
    var error: String?
    /// The tool's input, as pretty JSON. Read separately: it is the harness's own JSON.
    var input: String?

    enum CodingKeys: String, CodingKey {
        case kind, name, command, cwd, exit_code, duration_ms, output, changes, query, path, error
    }

    static func prettyJSON(_ value: Any) -> String? {
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated struct AgentChoice: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    /// `allow` or `deny`.
    var effect: String?
}

nonisolated struct AgentApprovalBody: Codable, Hashable, Sendable {
    struct Answer: Codable, Hashable, Sendable { var choice: String? }
    var subject: String?
    var choices: [AgentChoice]
    var answer: Answer?
}

nonisolated struct AgentOffered: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var description: String?
}

nonisolated struct AgentAsked: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var header: String?
    var text: String
    var options: [AgentOffered]?
    var multiple: Bool?
    var allow_text: Bool?
    var secret: Bool?

    var offered: [AgentOffered] { options ?? [] }
    var allowsMultiple: Bool { multiple ?? false }
    var isSecret: Bool { secret ?? false }
    /// A question with no options takes only free text.
    var takesText: Bool { (allow_text ?? false) || offered.isEmpty }
}

nonisolated struct AgentAnswered: Codable, Hashable, Sendable {
    var question: String
    var options: [String]?
    var text: String?
}

nonisolated struct AgentQuestionBody: Codable, Hashable, Sendable {
    /// `request`: answered by a kind-1202 answer. `message`: by the person's next chat message.
    var answer_via: String?
    var subject: String?
    var questions: [AgentAsked]
    var answer: [AgentAnswered]?

    var answeredByMessage: Bool { answer_via == "message" }
    var asksSecret: Bool { questions.contains(where: \.isSecret) }
}

nonisolated struct AgentPlanEntry: Codable, Hashable, Sendable {
    var text: String
    /// `pending`, `running` or `done`.
    var state: String
}

nonisolated struct AgentPlanBody: Codable, Hashable, Sendable {
    var text: String?
    var entries: [AgentPlanEntry]?
}

nonisolated struct AgentTaskBody: Codable, Hashable, Sendable {
    var kind: String
    var description: String?
    var subject: String?
    var usage: AgentUsage?
}

nonisolated struct AgentNoticeBody: Codable, Hashable, Sendable {
    /// `compaction`, `waiting`, `retry`, `warning`, `model_changed`, `command_output` or `refused`.
    var kind: String
    var duration_ms: UInt64?
    var reason: String?
}

nonisolated struct AgentErrorBody: Codable, Hashable, Sendable {
    var request: String?
    var code: Int64?
    var will_retry: Bool?
}

nonisolated struct AgentSetting: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var value: String?
    var options: [String]?
    var approve: Bool?
}

nonisolated struct AgentAction: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var description: String?
}

nonisolated struct AgentCommand: Codable, Hashable, Sendable {
    var name: String
    var description: String?
    var hint: String?
}

nonisolated struct AgentSessionBody: Codable, Hashable, Sendable {
    var harness_version: String?
    var settings: [AgentSetting]?
    var actions: [AgentAction]?
    var commands: [AgentCommand]?
}

// MARK: - Answers and controls (kind 1202)

nonisolated struct AgentQuestionReply: Hashable, Sendable {
    let question: String
    let options: [String]
    let text: String?
}

/// An answer or a control, as a person's app sends it (`carrier::request` in marmot-agents).
nonisolated struct AgentRequest: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case choice(String)
        case questions([AgentQuestionReply])
        case interrupt
        case newSession
        case set(setting: String, value: String)
        case own(String)
    }

    /// The agent it is for (`p`).
    let agentAccountIdHex: String
    /// The first event of the item it acts on (`e`), when it names one.
    let targetEventIdHex: String?
    let action: Action
    /// The plain rendering: "Allow once", "Stop".
    let content: String

    var detailsJSON: String {
        var details: [String: Any]
        switch action {
        case .choice(let id):
            details = ["action": "choice", "choice": id]
        case .questions(let replies):
            details = [
                "action": "questions",
                "questions": replies.map { reply -> [String: Any] in
                    var entry: [String: Any] = ["question": reply.question, "options": reply.options]
                    if let text = reply.text { entry["text"] = text }
                    return entry
                },
            ]
        case .interrupt:
            details = ["action": "interrupt"]
        case .newSession:
            details = ["action": "new_session"]
        case .set(let setting, let value):
            details = ["action": "set", "setting": setting, "value": value]
        case .own(let id):
            details = ["action": "own", "id": id]
        }
        let data =
            (try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    var tags: [[String]] {
        var tags: [[String]] = [["p", agentAccountIdHex], ["details", detailsJSON]]
        if let targetEventIdHex { tags.append(["e", targetEventIdHex]) }
        return tags
    }
}
