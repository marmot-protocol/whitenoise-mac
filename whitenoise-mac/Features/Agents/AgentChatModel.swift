import Foundation
import Observation

/// The agent side of one open conversation: its transcript projection, the presses sent from it,
/// and what fills the conversation pane (the main chat, or a subagent's thread) with the scroll
/// request for it. Owned by `ConversationViewModel`; the sends themselves live on the account's
/// `AgentRequestLedger`, so a pending press survives switching chats.
@MainActor
@Observable
final class AgentChatModel {
    let groupIdHex: String
    /// The subagent threads open, outermost first: each is a `task` item's first event. Empty is
    /// the main chat.
    private(set) var threadPath: [String] = []
    /// The scroll request for the view `threadPath` names. The two only change together, so a
    /// table made for a new view takes that view's request on its first frame, never the last
    /// view's (a stale "foot" there would mark the main chat's newest messages read).
    private(set) var scrollRequest: TranscriptScrollRequest?

    @ObservationIgnored let ledger: AgentRequestLedger?

    init(groupIdHex: String, ledger: AgentRequestLedger?) {
        self.groupIdHex = groupIdHex
        self.ledger = ledger
    }

    var failure: String? { ledger?.failures[groupIdHex] }

    func dismissFailure() { ledger?.dismissFailure(groupIdHex: groupIdHex) }

    /// The window as the agent rows read it. Reads the ledger's sends, so a press or a newly seen
    /// answer re-renders the transcript.
    func transcript(displayItems: [TimelineMessageDisplayItem], localAccountIdHex: String) -> AgentTranscript {
        guard let ledger else {
            return AgentTranscript.build(
                displayItems: displayItems,
                localAccountIdHex: localAccountIdHex,
                sends: { _ in [] },
                requestSender: { _ in nil }
            )
        }
        _ = ledger.observedRevision
        let groupIdHex = groupIdHex
        let sent = ledger.sent.values.filter { $0.groupIdHex == groupIdHex }.sorted { $0.sentAt < $1.sentAt }
        let byTarget = Dictionary(grouping: sent) { $0.targetEventIdHex ?? "" }
        return AgentTranscript.build(
            displayItems: displayItems,
            localAccountIdHex: localAccountIdHex,
            sends: { byTarget[$0 ?? ""] ?? [] },
            requestSender: { ledger.sender(ofRequest: $0) }
        )
    }

    /// `memberCount` is MDK's count of the chat's member accounts, nil when unknown.
    func actions(
        memberCount: UInt64?, isDirect: Bool, copyText: @escaping @MainActor (String) -> Void
    ) -> AgentRowActions {
        let groupIdHex = groupIdHex
        let ledger = ledger
        return AgentRowActions(
            // A secret is answered from the chat only where the person and the agent are alone.
            canAnswerSecret: memberCount.map { $0 == 2 } ?? isDirect,
            isDirectChat: isDirect,
            send: { request in
                guard let ledger else { return }
                Task { await ledger.send(request, groupIdHex: groupIdHex) }
            },
            isSending: { request in ledger?.isInFlight(groupIdHex: groupIdHex, request: request) ?? false },
            openThread: { [weak self] id in self?.openThread(id) },
            copyText: copyText
        )
    }

    /// Shows `path`'s view (the main chat for `[]`) and applies `request` there.
    func scroll(_ request: TranscriptScrollRequest, inThreads path: [String]) {
        threadPath = path
        scrollRequest = request
    }

    /// Opens a `task` row's thread at its newest row; one already open on the path comes back to
    /// the top.
    func openThread(_ taskFirstEventIdHex: String) {
        let path =
            threadPath.firstIndex(of: taskFirstEventIdHex).map { Array(threadPath.prefix(through: $0)) }
            ?? threadPath + [taskFirstEventIdHex]
        scroll(TranscriptScrollRequest(target: .bottom), inThreads: path)
    }

    /// Back one level, to the row the thread was opened from.
    func closeThread() {
        guard let closed = threadPath.last else { return }
        scroll(TranscriptScrollRequest(target: .center(id: closed)), inThreads: Array(threadPath.dropLast()))
    }

    /// Back to the main chat, at the outermost thread's row.
    func closeAllThreads() {
        guard let outermost = threadPath.first else { return }
        scroll(TranscriptScrollRequest(target: .center(id: outermost)), inThreads: [])
    }

    /// Forgets the pane's view and request when its conversation leaves the screen, so a cached
    /// model comes back to the main chat with nothing stale to apply.
    func leavePane() {
        threadPath = []
        scrollRequest = nil
    }
}
