import Foundation
import MarmotKit
import Observation

/// One answer or control this account sent to an agent (kind 1202).
nonisolated struct AgentSentRequest: Hashable, Sendable {
    /// The kind-1202 event id, which an item version's `settles` names once it shows the effect.
    let idHex: String
    let groupIdHex: String
    /// The first event of the item it acts on; nil for a control that names none.
    let targetEventIdHex: String?
    let agentAccountIdHex: String
    /// The plain rendering, as sent: "Allow once", "Stop".
    let label: String
    let sentAt: Date
}

/// The answers and controls this account sends to agents, and who sent the ones others pressed.
///
/// A press is a request: it changes nothing by itself, and stays pending until a later version of
/// some item lists its event id in `settles` (marmot-agents' `answers-and-controls.md`). This
/// ledger keeps the sends; whether one is settled is read from the chat's items
/// (`AgentTranscript`). It also notes the sender of every kind-1202 event that arrives live, so a
/// settled answer can say who gave it. MDK keeps no row for kind 1202, so an answer given while
/// this app was closed can only say it was answered.
///
/// Owned by `AccountScope`: an account switch discards it. Held in memory only; nothing here is
/// ever logged.
@MainActor
@Observable
final class AgentRequestLedger {
    /// Sends by event id.
    private(set) var sent: [String: AgentSentRequest] = [:]
    /// Why the last send in a group failed, until the next send there.
    private(set) var failures: [String: String] = [:]
    /// Presses in flight, by the key `pressKey` makes, so a second click is dropped.
    private(set) var inFlight: Set<String> = []
    /// Items with an answer on its way, by `targetKey`: every other choice for them waits, so a
    /// second tap never sends a conflicting answer.
    private(set) var inFlightTargets: Set<String> = []
    /// A press whose send failed and whose admission MDK could not confirm either way keeps its
    /// client token here, by `pressKey`. The next press reuses it: MDK answers a token it already
    /// admitted with that event and sends nothing, so the control never goes out twice.
    @ObservationIgnored private var unconfirmedTokens: [String: String] = [:]
    /// The sender of each kind-1202 event seen arrive, by event id (others' presses included).
    @ObservationIgnored private(set) var observedSenders: [String: String] = [:]
    /// Bumped when `observedSenders` changes, so rows that name who answered re-render.
    private(set) var observedRevision = 0

    @ObservationIgnored let accountRef: String
    @ObservationIgnored let accountIdHex: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private let makeClientToken: () -> String

    private static let observedLimit = 512

    init(
        accountRef: String,
        accountIdHex: String,
        runtime: (any MarmotRuntime)?,
        makeClientToken: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.accountRef = accountRef
        self.accountIdHex = accountIdHex.lowercased()
        self.runtime = runtime
        self.makeClientToken = makeClientToken
    }

    func start() {
        guard eventsTask == nil, let runtime else { return }
        let subscription = runtime.subscribeEvents()
        eventsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let event = try? await runtime.nextEvent(subscription: subscription) else { return }
                self?.observe(event)
            }
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    func observe(_ event: MarmotEventFfi) {
        guard case .messageReceived(let received) = event,
            received.accountIdHex.lowercased() == accountIdHex,
            received.message.kind == AgentItem.requestKind
        else { return }
        let id = received.message.messageIdHex.lowercased()
        guard observedSenders[id] == nil else { return }
        if observedSenders.count >= Self.observedLimit {
            observedSenders.removeAll(keepingCapacity: true)
        }
        observedSenders[id] = received.message.sender.lowercased()
        observedRevision &+= 1
    }

    /// Who sent the request `idHex`: this account for its own sends, else the sender seen arrive.
    func sender(ofRequest idHex: String) -> String? {
        let id = idHex.lowercased()
        if sent[id] != nil { return accountIdHex }
        return observedSenders[id]
    }

    /// This account's sends in `groupIdHex` that act on `targetEventIdHex`, oldest first.
    func sends(groupIdHex: String, targetEventIdHex: String?) -> [AgentSentRequest] {
        sent.values
            .filter { $0.groupIdHex == groupIdHex && $0.targetEventIdHex == targetEventIdHex }
            .sorted { $0.sentAt < $1.sentAt }
    }

    /// One press per agent, item and details: the same untargeted control (a setting, a new
    /// session) sent to two agents in one chat is two presses.
    static func pressKey(groupIdHex: String, request: AgentRequest) -> String {
        "\(groupIdHex)|\(request.agentAccountIdHex.lowercased())|\(request.targetEventIdHex ?? "")|\(request.detailsJSON)"
    }

    static func targetKey(groupIdHex: String, request: AgentRequest) -> String? {
        request.targetEventIdHex.map { "\(groupIdHex)|\($0.lowercased())" }
    }

    /// Whether this press, or any answer to the same item, is on its way.
    func isInFlight(groupIdHex: String, request: AgentRequest) -> Bool {
        if inFlight.contains(Self.pressKey(groupIdHex: groupIdHex, request: request)) { return true }
        return Self.targetKey(groupIdHex: groupIdHex, request: request).map(inFlightTargets.contains) ?? false
    }

    /// Sends `request` to `groupIdHex` as kind 1202, crash-safely under a fresh client token.
    /// Returns the sent request, or nil when it failed (the reason is in `failures`).
    @discardableResult
    func send(_ request: AgentRequest, groupIdHex: String, now: Date = Date()) async -> AgentSentRequest? {
        guard let runtime else { return nil }
        guard !isInFlight(groupIdHex: groupIdHex, request: request) else { return nil }
        let key = Self.pressKey(groupIdHex: groupIdHex, request: request)
        let target = Self.targetKey(groupIdHex: groupIdHex, request: request)
        inFlight.insert(key)
        if let target { inFlightTargets.insert(target) }
        failures[groupIdHex] = nil
        defer {
            inFlight.remove(key)
            if let target { inFlightTargets.remove(target) }
        }
        let clientToken = unconfirmedTokens[key] ?? makeClientToken()
        let messageIdHex: String
        do {
            messageIdHex = try await runtime.sendCustomEventWithClientToken(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                kind: AgentItem.requestKind,
                tags: request.tags,
                content: request.content,
                clientToken: clientToken
            ).messageIdHex
        } catch {
            // An interrupted await can race MDK's durable admission. Ask by the same token, so a
            // press that went out stays pending instead of being sent again as a second control.
            let admission = Self.admission(runtime, accountRef, groupIdHex, clientToken)
            if case .admitted(let admitted) = admission {
                messageIdHex = admitted
            } else {
                // Unconfirmed: keep the token for the next press. Refused: the next press is new.
                if case .unknown = admission {
                    unconfirmedTokens[key] = clientToken
                } else {
                    unconfirmedTokens[key] = nil
                }
                if !(error is CancellationError) {
                    failures[groupIdHex] = UserFacingError.message(for: error)
                }
                return nil
            }
        }
        unconfirmedTokens[key] = nil
        let sentRequest = AgentSentRequest(
            idHex: messageIdHex.lowercased(),
            groupIdHex: groupIdHex,
            targetEventIdHex: request.targetEventIdHex,
            agentAccountIdHex: request.agentAccountIdHex,
            label: request.content,
            sentAt: now
        )
        sent[sentRequest.idHex] = sentRequest
        return sentRequest
    }

    private enum Admission {
        case admitted(String)
        /// MDK refused it, or holds nothing under the token: a new press may use a new token.
        case notAdmitted
        /// The status could not be read: the send may have gone out.
        case unknown
    }

    /// What MDK did with the send under `clientToken`.
    private static func admission(
        _ runtime: any MarmotRuntime, _ accountRef: String, _ groupIdHex: String, _ clientToken: String
    ) -> Admission {
        let status: LocalSendStatusFfi?
        do {
            status = try runtime.localSendStatus(
                accountRef: accountRef, groupIdHex: groupIdHex, clientToken: clientToken)
        } catch {
            return .unknown
        }
        switch status {
        case .queued(let messageIdHex), .engineOwned(let messageIdHex):
            return .admitted(messageIdHex)
        case .completed(let summary):
            return summary.messageIds.first.map(Admission.admitted) ?? .unknown
        case .rejected, .refusedNewMembers, nil:
            return .notAdmitted
        }
    }

    func dismissFailure(groupIdHex: String) {
        failures[groupIdHex] = nil
    }
}
