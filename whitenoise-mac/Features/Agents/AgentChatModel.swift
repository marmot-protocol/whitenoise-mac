import Foundation
import Observation

/// The agent side of one open conversation: its transcript projection, the presses sent from it,
/// and which subagent thread is open. Owned by `ConversationViewModel`; the sends themselves live
/// on the account's `AgentRequestLedger`, so a pending press survives switching chats.
@MainActor
@Observable
final class AgentChatModel {
    let groupIdHex: String
    /// The subagent threads open, outermost first: each is a `task` item's first event.
    var threadPath: [String] = []

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

    func openThread(_ taskFirstEventIdHex: String) {
        if let index = threadPath.firstIndex(of: taskFirstEventIdHex) {
            threadPath = Array(threadPath.prefix(through: index))
        } else {
            threadPath.append(taskFirstEventIdHex)
        }
    }

    func closeThread() {
        guard !threadPath.isEmpty else { return }
        threadPath.removeLast()
    }

    func closeAllThreads() { threadPath = [] }
}
