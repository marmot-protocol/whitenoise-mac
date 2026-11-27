import Foundation

/// A conversation window as the agent parts of the transcript read it: which rows go in the main
/// chat, what each subagent's thread holds, which of this account's presses are settled and who
/// answered what, the running turn and the agent's session.
///
/// A pure projection of the window's rows and this account's sends, rebuilt whenever either
/// changes. It decorates the rows themselves (`MessageAgentContext`), so a press, a settle or a
/// change in a thread changes the row's value and the transcript re-measures it.
nonisolated struct AgentTranscript {
    /// The rows the main chat shows: everything but the rows in a loaded subagent thread, and no
    /// kind 1202 (MDK hides those already).
    let mainItems: [TimelineMessageDisplayItem]
    /// Each subagent thread's rows, oldest first, by the first event of its `task` item.
    let threads: [String: [MessageItem]]
    /// The latest top-level turn still running, for Stop.
    let runningTurn: AgentItem?
    /// The latest top-level session item: the agent's settings, actions and commands.
    let session: AgentItem?
    /// Approvals and questions waiting anywhere in the window, oldest first.
    let waiting: [AgentItem]
    /// The `task` row whose thread holds each row in `threads`, by the row's id.
    let threadOwners: [String: String]

    var hasAgentActivity: Bool { session != nil || runningTurn != nil || !waiting.isEmpty }

    /// The ids of the rows the main chat shows, oldest first: where its reader is measured from.
    var mainMessageIds: [String] { mainItems.map(\.message.id) }

    /// The threads to open, outermost first, to show `messageId`; nil when the main chat shows it.
    /// A nested subagent's thread opens on top of its parent's.
    func threadPath(to messageId: String) -> [String]? {
        var path: [String] = []
        var id = messageId
        while let owner = threadOwners[id], path.count < 16 {
            path.insert(owner, at: 0)
            id = owner
        }
        return path.isEmpty ? nil : path
    }

    /// The main chat's row for `messageId`: itself, or the outermost `task` row of the thread that
    /// holds it. The unread divider and an open's first scroll anchor there.
    func mainChatRow(for messageId: String) -> String {
        threadPath(to: messageId)?.first ?? messageId
    }

    /// `sends` gives this account's requests for an item's first event (nil for untargeted
    /// controls); `requestSender` names who sent a request id, when known.
    static func build(
        displayItems: [TimelineMessageDisplayItem],
        localAccountIdHex: String,
        sends: (_ targetEventIdHex: String?) -> [AgentSentRequest],
        requestSender: (_ requestIdHex: String) -> String?
    ) -> AgentTranscript {
        let rows = displayItems.filter { $0.message.timelineKind != AgentItem.requestKind }
        guard rows.contains(where: { $0.message.agent != nil }) else {
            return AgentTranscript(
                mainItems: rows, threads: [:], runningTurn: nil, session: nil, waiting: [], threadOwners: [:])
        }

        var itemsById: [String: AgentItem] = [:]
        var settled: Set<String> = []
        var names: [String: String] = [localAccountIdHex.lowercased(): L10n.string("You")]
        for row in rows {
            let message = row.message
            if let item = message.agent?.item {
                itemsById[message.id] = item
                settled.formUnion(item.settles)
            } else if message.presentation.isChatBubble {
                names[message.senderAccountIdHex.lowercased()] = message.senderName
            }
        }

        // A row is in a subagent's thread when MDK placed it under a loaded `task` item, the only
        // row that opens a thread: its parent's, else its root's. Anything else stays in the main
        // chat, so nothing whose `task` row is not loaded, or that answers a tool or plan, disappears.
        func ownsThread(_ id: String) -> Bool {
            guard case .task = itemsById[id]?.body else { return false }
            return true
        }
        func threadOwner(of message: MessageItem) -> String? {
            guard let thread = message.agent?.thread else { return nil }
            if ownsThread(thread.parent) { return thread.parent }
            if ownsThread(thread.root) { return thread.root }
            return nil
        }

        var threadRowIds: [String: [String]] = [:]
        var threadOwners: [String: String] = [:]
        for row in rows {
            if let owner = threadOwner(of: row.message), owner != row.message.id {
                threadRowIds[owner, default: []].append(row.message.id)
                threadOwners[row.message.id] = owner
            }
        }
        let inThread = Set(threadOwners.keys)

        func decorated(_ message: MessageItem) -> MessageItem {
            guard var agent = message.agent else { return message }
            if let item = agent.item {
                agent.requests = sends(item.firstEventIdHex).map {
                    AgentRequestStatus(idHex: $0.idHex, label: $0.label, isSettled: settled.contains($0.idHex))
                }
                if item.state != .waiting, Self.isAnswerable(item) {
                    agent.answeredBy =
                        item.settles
                        .compactMap { requestSender($0).flatMap { names[$0] ?? DisplayText.short($0) } }
                        .first
                }
                agent.isOutsideItsThread = agent.thread != nil && !inThread.contains(message.id)
            }
            var copy = message
            copy.agent = agent
            return copy
        }

        var decoratedById: [String: MessageItem] = [:]
        for row in rows { decoratedById[row.message.id] = decorated(row.message) }

        // The session row also carries the controls that name no item (new session, settings).
        let topLevelItems = rows.compactMap { row -> AgentItem? in
            inThread.contains(row.message.id) ? nil : row.message.agent?.item
        }
        let session = topLevelItems.last { $0.type == "session" }
        if let session, var message = decoratedById[session.firstEventIdHex] {
            // Only this agent's: with two agents in the chat, a setting sent to one never shows on
            // the other's session.
            let agent = session.agentAccountIdHex.lowercased()
            let untargeted = sends(nil).filter { $0.agentAccountIdHex.lowercased() == agent }.map {
                AgentRequestStatus(idHex: $0.idHex, label: $0.label, isSettled: settled.contains($0.idHex))
            }
            message.agent?.requests += untargeted
            decoratedById[session.firstEventIdHex] = message
        }

        func subtree(of owner: String, depth: Int = 0) -> [MessageItem] {
            guard depth < 16 else { return [] }
            return (threadRowIds[owner] ?? []).flatMap { id -> [MessageItem] in
                guard let message = decoratedById[id] else { return [] }
                return [message] + subtree(of: id, depth: depth + 1)
            }
        }

        var threads: [String: [MessageItem]] = [:]
        for (owner, ids) in threadRowIds {
            threads[owner] = ids.compactMap { decoratedById[$0] }
            let all = subtree(of: owner)
            guard var task = decoratedById[owner] else { continue }
            task.agent?.threadSummary = AgentThreadSummary(
                rowCount: all.count,
                waiting: all.filter { $0.agent?.item.map(Self.awaitsAnswer) == true }
            )
            decoratedById[owner] = task
        }
        // Re-read thread rows after task rows took their summaries (a nested task row is both).
        for (owner, ids) in threadRowIds {
            threads[owner] = ids.compactMap { decoratedById[$0] }
        }

        // A day's divider rides on its first row; when that row moved into a thread, the next row
        // the main chat keeps carries it instead.
        var mainItems: [TimelineMessageDisplayItem] = []
        var carriedDayLabel: String?
        for row in rows {
            guard !inThread.contains(row.message.id), let message = decoratedById[row.message.id] else {
                carriedDayLabel = row.dayLabel ?? carriedDayLabel
                continue
            }
            mainItems.append(TimelineMessageDisplayItem(message: message, dayLabel: row.dayLabel ?? carriedDayLabel))
            carriedDayLabel = nil
        }

        let allItems = rows.compactMap { $0.message.agent?.item }
        return AgentTranscript(
            mainItems: mainItems,
            threads: threads,
            runningTurn: topLevelItems.last { $0.type == "turn" && $0.state == .running },
            session: session,
            waiting: allItems.filter(awaitsAnswer),
            threadOwners: threadOwners
        )
    }

    /// An approval or a question a person can answer now.
    static func awaitsAnswer(_ item: AgentItem) -> Bool {
        item.state == .waiting && isAnswerable(item)
    }

    /// An approval or a question: the items a person answers, as against controls such as Stop.
    static func isAnswerable(_ item: AgentItem) -> Bool {
        switch item.body {
        case .approval, .question: return true
        default: return false
        }
    }
}
