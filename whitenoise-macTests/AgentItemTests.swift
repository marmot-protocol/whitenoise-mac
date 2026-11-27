import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Agent items (marmot-agents kinds 1201 and 1202): reading MDK's latest version of each item,
/// building answers and controls exactly as `marmot-agent-chat` sends them, and the transcript's
/// threads, pending presses and settles.
@MainActor
struct AgentItemTests {
    private typealias F = AgentPreviewFixtures

    /// Recorded Codex events (`fixtures/recordings/codex/expected/approval_allowed.jsonl` in
    /// marmot-agents), with their native payloads left out.
    private static let approvalAllowed = [
        #"{"harness":"codex","session":"s1","turn":"t1","item":"exec-1","seq":5,"type":"tool","state":"running","title":"Running a command","text":"/usr/bin/zsh -lc 'python3 greet.py'","body":{"kind":"command","name":"shell","command":"/usr/bin/zsh -lc 'python3 greet.py'","cwd":"/work/demo"}}"#,
        #"{"harness":"codex","session":"s1","turn":"t1","item":"approval:t1:0","seq":6,"type":"approval","state":"waiting","title":"Allow this command?","text":"/usr/bin/zsh -lc 'python3 greet.py'","body":{"subject":"exec-1","choices":[{"id":"c0","label":"Allow once","effect":"allow"},{"id":"c1","label":"Allow, and don't ask again for this command","effect":"allow"},{"id":"c2","label":"Deny and stop","effect":"deny"},{"id":"c3","label":"Deny","effect":"deny"}]}}"#,
        #"{"harness":"codex","session":"s1","turn":"t1","item":"approval:t1:0","seq":7,"type":"approval","state":"done","title":"Allow this command?","text":"Answered: Allow once","body":{"subject":"exec-1","choices":[{"id":"c0","label":"Allow once","effect":"allow"}],"answer":{"choice":"c0"}}}"#,
        #"{"harness":"codex","session":"s1","turn":"t1","item":"exec-1","seq":8,"type":"tool","state":"done","title":"Ran a command","text":"/usr/bin/zsh -lc 'python3 greet.py'","body":{"kind":"command","name":"shell","command":"/usr/bin/zsh -lc 'python3 greet.py'","cwd":"/work/demo","exit_code":0,"duration_ms":0,"output":"Hello, world\n"}}"#,
        #"{"harness":"codex","session":"s1","turn":"t1","item":"turn:t1","seq":10,"type":"turn","state":"done","title":"Finished","text":"","body":{"started_by":"user","duration_ms":9341,"usage":{"input_tokens":31085,"output_tokens":71}}}"#,
    ]

    private static func event(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    private static func items(_ records: [TimelineMessageRecordFfi]) -> [MessageItem] {
        MessageItem.timeline(
            from: TimelinePageFfi(messages: records, hasMoreBefore: false, hasMoreAfter: false),
            activeAccountIdHex: F.person
        )
    }

    private static func transcript(
        _ records: [TimelineMessageRecordFfi],
        sends: [AgentSentRequest] = [],
        senders: [String: String] = [:]
    ) -> AgentTranscript {
        AgentTranscript.build(
            displayItems: TimelineMessageDisplayItem.make(from: items(records)),
            localAccountIdHex: F.person,
            sends: { target in sends.filter { $0.targetEventIdHex == target } },
            requestSender: { id in
                sends.contains { $0.idHex == id } ? F.person : senders[id]
            }
        )
    }

    // MARK: Reading items

    /// A tool row goes from running to done in place: one row, at the first event, showing the
    /// latest version's output.
    @Test func aToolRowShowsItsLatestVersionInPlace() throws {
        let id = F.eventId(1)
        let running = Self.items([F.record(id: id, event: Self.event(Self.approvalAllowed[0]))])
        let done = Self.items([F.record(id: id, event: Self.event(Self.approvalAllowed[3]), version: 2)])

        let before = try #require(running.first?.agent?.item)
        let after = try #require(done.first?.agent?.item)
        #expect(before.state == .running)
        #expect(after.state == .done)
        #expect(after.firstEventIdHex == id)
        guard case .tool(let tool) = after.body else {
            Issue.record("not a tool")
            return
        }
        #expect(tool.kind == "command")
        #expect(tool.command == "/usr/bin/zsh -lc 'python3 greet.py'")
        #expect(tool.output == "Hello, world\n")
        #expect(tool.exit_code == 0)
        #expect(running.first != done.first, "a new version is a changed row")
    }

    @Test func eachTypeReadsItsBody() throws {
        let messages = F.messages
        func body(_ n: Int) -> AgentItemBody? { messages.first { $0.id == F.eventId(n) }?.agent?.item?.body }

        guard case .session(let session) = body(1) else { throw Failure("session") }
        #expect(session.settings?.map(\.id) == ["model", "approval_policy"])
        #expect(session.settings?.first?.options == ["gpt-6.1-sol", "gpt-6.2-sol"])
        #expect(session.settings?.last?.approve == true)
        #expect(session.actions?.map(\.id) == ["compact"])
        guard case .approval(let approval) = body(5) else { throw Failure("approval") }
        #expect(approval.choices.map(\.id) == ["c0", "c1", "c2", "c3"])
        #expect(approval.choices.map(\.effect) == ["allow", "allow", "deny", "deny"])
        guard case .tool(let edit) = body(6) else { throw Failure("edit") }
        #expect(edit.changes?.first?.path == "/work/demo/greet.py")
        guard case .plan(let plan) = body(7) else { throw Failure("plan") }
        #expect(plan.entries?.map(\.state) == ["done", "running", "pending"])
        guard case .question(let question) = body(9) else { throw Failure("question") }
        #expect(question.asksSecret)
        #expect(question.questions.first?.offered.map(\.id) == ["o0", "o1"])
        #expect(question.questions.last?.takesText == true)
        guard case .task(let task) = body(10) else { throw Failure("task") }
        #expect(task.kind == "subagent")
        guard case .notice(let notice) = body(12) else { throw Failure("notice") }
        #expect(notice.kind == "refused")
        guard case .error(let error) = body(13) else { throw Failure("error") }
        #expect(error.code == 400)
    }

    /// An unknown type or a body this app cannot read falls back to the title and plain text.
    @Test func anUnknownTypeFallsBackToTitleAndText() throws {
        let unknown = Self.items([
            F.record(id: F.eventId(1), event: ["type": "hologram", "title": "Projecting", "text": "Beep"]),
            F.record(id: F.eventId(2), event: ["type": "tool", "title": "Odd tool", "text": "x", "body": ["kind": 3]]),
        ])
        let first = try #require(unknown.first?.agent?.item)
        #expect(first.body == .unknown)
        #expect(first.title == "Projecting")
        #expect(first.text == "Beep")
        #expect(unknown.last?.agent?.item?.body == .unknown)
    }

    /// Today's Hermes plugin sends kind 1201 in an older shape MDK no longer reads as an item:
    /// the row stays, as a simple row with its plain content.
    @Test func anOldShapeItemStillShowsItsPlainContent() throws {
        let rows = Self.items([
            timelineMessage(
                id: F.eventId(1), groupIdHex: F.groupIdHex, sender: F.agent, plaintext: "Tool: terminal",
                kind: AgentItem.itemKind, recordedAt: 1)
        ])
        let row = try #require(rows.first)
        #expect(row.agent?.item == nil)
        #expect(row.agent?.isUnreadableItem == true)
        #expect(row.presentation == .agentActivity)
        #expect(row.body == "Tool: terminal")
        let transcript = Self.transcript([
            timelineMessage(
                id: F.eventId(1), groupIdHex: F.groupIdHex, sender: F.agent, plaintext: "Tool: terminal",
                kind: AgentItem.itemKind, recordedAt: 1)
        ])
        #expect(transcript.mainItems.map(\.id) == [F.eventId(1)])
    }

    @Test func anItemWhoseFirstEventIsMissingSaysSo() throws {
        let rows = Self.items([
            F.record(id: F.eventId(1), event: Self.event(Self.approvalAllowed[3]), version: 3, firstEventMissing: true)
        ])
        #expect(rows.first?.agent?.item?.firstEventMissing == true)
    }

    @Test func outputCutToFitIsNoted() throws {
        let rows = Self.items([
            F.record(
                id: F.eventId(1), event: Self.event(Self.approvalAllowed[3]),
                extraTags: [["cut", "output", "250000"]])
        ])
        let item = try #require(rows.first?.agent?.item)
        guard case .tool(let tool) = item.body else { throw Failure("tool") }
        #expect(item.cuts["output"] == 250_000)
        #expect(AgentItemPresentation.outputCutNote(item, tool) != nil)
    }

    /// The agent's words are ordinary chat; a remark made while it works is marked as one.
    @Test func theAgentsWordsAreChatAndCommentaryIsMarked() {
        let rows = Self.items([
            F.words(id: F.eventId(1), text: "Working on it", commentary: true),
            F.words(id: F.eventId(2), text: "Done: it printed Hello"),
            timelineMessage(
                id: F.eventId(3), groupIdHex: F.groupIdHex, sender: F.person, plaintext: "hi", recordedAt: 1),
        ])
        #expect(rows.map(\.presentation) == [.chat, .chat, .chat])
        #expect(rows[0].agent?.isCommentary == true)
        #expect(rows[1].agent?.isCommentary == false)
        #expect(rows[1].agent?.wordsTurn == "t1")
        #expect(rows[2].agent == nil, "an older agent's answers and people's messages are untouched")
    }

    // MARK: Answers and controls

    private static func details(_ request: AgentRequest) -> NSDictionary? {
        guard let json = request.tags.first(where: { $0.first == "details" })?.last else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? NSDictionary
    }

    @Test func anApprovalAnswerNamesTheAgentTheItemAndTheChoice() {
        let request = AgentRequest(
            agentAccountIdHex: F.agent, targetEventIdHex: F.eventId(5), action: .choice("c0"), content: "Allow once")
        #expect(request.tags.first == ["p", F.agent])
        #expect(request.tags.contains(["e", F.eventId(5)]))
        #expect(request.tags.count == 3)
        #expect(Self.details(request) == ["action": "choice", "choice": "c0"])
        #expect(request.content == "Allow once")
    }

    @Test func eachControlCarriesItsDetails() {
        func make(_ action: AgentRequest.Action, target: String? = nil) -> AgentRequest {
            AgentRequest(agentAccountIdHex: F.agent, targetEventIdHex: target, action: action, content: "x")
        }
        #expect(Self.details(make(.interrupt, target: F.eventId(2))) == ["action": "interrupt"])
        #expect(make(.interrupt, target: F.eventId(2)).tags.contains(["e", F.eventId(2)]))
        #expect(Self.details(make(.newSession)) == ["action": "new_session"])
        #expect(!make(.newSession).tags.contains { $0.first == "e" })
        #expect(
            Self.details(make(.set(setting: "model", value: "gpt-6.2-sol")))
                == ["action": "set", "setting": "model", "value": "gpt-6.2-sol"])
        #expect(Self.details(make(.own("compact"))) == ["action": "own", "id": "compact"])
        #expect(
            Self.details(
                make(
                    .questions([
                        AgentQuestionReply(question: "q0", options: ["o1"], text: nil),
                        AgentQuestionReply(question: "q1", options: [], text: "hunter2"),
                    ])))
                == [
                    "action": "questions",
                    "questions": [
                        ["question": "q0", "options": ["o1"]],
                        ["question": "q1", "options": [], "text": "hunter2"],
                    ],
                ])
    }

    @Test func aPressIsSentAsKind1202AndRemembered() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let ledger = AgentRequestLedger(accountRef: "me", accountIdHex: F.person, runtime: runtime)
        let request = AgentRequest(
            agentAccountIdHex: F.agent, targetEventIdHex: F.eventId(5), action: .choice("c3"), content: "Deny")

        let sent = try #require(await ledger.send(request, groupIdHex: F.groupIdHex))

        let wire = try #require(runtime.sentCustomEvents.first)
        #expect(wire.kind == 1202)
        #expect(wire.groupIdHex == F.groupIdHex)
        #expect(wire.tags == request.tags)
        #expect(wire.content == "Deny")
        #expect(!wire.clientToken.isEmpty)
        #expect(ledger.sender(ofRequest: sent.idHex) == F.person)
        #expect(ledger.sends(groupIdHex: F.groupIdHex, targetEventIdHex: F.eventId(5)) == [sent])
        #expect(ledger.failures[F.groupIdHex] == nil)
    }

    @Test func aFailedPressSaysWhy() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.sendCustomEventError = MarmotKitError.StorageClosed(details: "closed")
        let ledger = AgentRequestLedger(accountRef: "me", accountIdHex: F.person, runtime: runtime)
        let request = AgentRequest(
            agentAccountIdHex: F.agent, targetEventIdHex: nil, action: .newSession, content: "New session")

        let sent = await ledger.send(request, groupIdHex: F.groupIdHex)

        #expect(sent == nil)
        #expect(ledger.failures[F.groupIdHex] != nil)
        #expect(ledger.sent.isEmpty)
    }

    /// The await can fail after MDK durably admitted the send. The press is asked after by its
    /// token and stays pending, so pressing again never sends a second control.
    @Test func aPressAdmittedBeforeItsAwaitFailedStaysPending() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.sendCustomEventError = MarmotKitError.StorageClosed(details: "closed")
        runtime.localSendStatuses["token-1"] = .queued(messageIdHex: "ADMITTED")
        let ledger = AgentRequestLedger(
            accountRef: "me", accountIdHex: F.person, runtime: runtime, makeClientToken: { "token-1" })
        let request = AgentRequest(
            agentAccountIdHex: F.agent, targetEventIdHex: nil, action: .newSession, content: "New session")

        let sent = try #require(await ledger.send(request, groupIdHex: F.groupIdHex))

        #expect(sent.idHex == "admitted")
        #expect(ledger.sends(groupIdHex: F.groupIdHex, targetEventIdHex: nil) == [sent])
        #expect(ledger.failures[F.groupIdHex] == nil)
    }

    @Test func anotherMembersPressIsAttributedOnceSeen() {
        let ledger = AgentRequestLedger(accountRef: "me", accountIdHex: F.person, runtime: nil)
        let alice = String(repeating: "cc", count: 32)
        ledger.observe(
            .messageReceived(
                received: RuntimeMessageReceivedFfi(
                    accountIdHex: F.person, accountLabel: "me",
                    message: ReceivedMessageFfi(
                        messageIdHex: "REQ", groupIdHex: F.groupIdHex, sender: alice, senderDisplayName: nil,
                        plaintext: "Allow once", contentTokens: emptyMarkdownDocument(), kind: 1202, tags: [],
                        sticker: nil, sourceEpoch: 1, retentionSeconds: nil, retentionExpiresAt: nil,
                        recordedAt: 1, receivedAt: 1))))
        #expect(ledger.sender(ofRequest: "req") == alice)
    }

    // MARK: The transcript

    /// After a press the answer is pending until a later version of some item lists it in
    /// `settles`; then it is settled, and says who answered.
    @Test func aPressIsPendingUntilAnItemSettlesIt() throws {
        let approvalId = F.eventId(5)
        let press = AgentSentRequest(
            idHex: "f1", groupIdHex: F.groupIdHex, targetEventIdHex: approvalId, agentAccountIdHex: F.agent,
            label: "Allow once", sentAt: Date())
        let waiting = Self.transcript(
            [F.record(id: approvalId, event: Self.event(Self.approvalAllowed[1]))], sends: [press])
        let pendingRow = try #require(waiting.mainItems.first?.message.agent)
        #expect(pendingRow.requests == [AgentRequestStatus(idHex: "f1", label: "Allow once", isSettled: false)])
        #expect(waiting.waiting.map(\.firstEventIdHex) == [approvalId])

        let answered = Self.transcript(
            [F.record(id: approvalId, event: Self.event(Self.approvalAllowed[2]), version: 2, settles: ["F1"])],
            sends: [press])
        let settledRow = try #require(answered.mainItems.first?.message.agent)
        #expect(settledRow.requests.map(\.isSettled) == [true])
        #expect(settledRow.answeredBy == L10n.string("You"))
        #expect(answered.waiting.isEmpty)
    }

    @Test func anAnswerFromSomeoneElseNamesThem() {
        let alice = String(repeating: "cc", count: 32)
        let records = [
            timelineMessage(id: F.eventId(1), groupIdHex: F.groupIdHex, sender: alice, plaintext: "go", recordedAt: 1),
            F.record(id: F.eventId(5), event: Self.event(Self.approvalAllowed[2]), version: 2, settles: ["a1"]),
        ]
        let transcript = Self.transcript(records, senders: ["a1": alice])
        let name = Self.items(records).first?.senderName
        #expect(transcript.mainItems.last?.message.agent?.answeredBy == name)
    }

    /// Stop settles on the turn it stopped, which shows the press settled but names nobody as
    /// having "answered" it: only approvals and questions are answered.
    @Test func aSettledControlOnATurnNamesNoAnswerer() throws {
        let stop = AgentSentRequest(
            idHex: "s1", groupIdHex: F.groupIdHex, targetEventIdHex: F.eventId(2), agentAccountIdHex: F.agent,
            label: "Stop", sentAt: Date())
        let transcript = Self.transcript(
            [F.record(id: F.eventId(2), event: Self.event(Self.approvalAllowed[4]), version: 2, settles: ["s1"])],
            sends: [stop])
        let turn = try #require(transcript.mainItems.first?.message.agent)
        #expect(turn.requests.map(\.isSettled) == [true])
        #expect(turn.answeredBy == nil)
    }

    /// A day's divider rides on its first row; when that row moves into a subagent's thread, the
    /// next row the main chat keeps carries it.
    @Test func aDayDividerSurvivesItsRowMovingIntoAThread() {
        let task = F.eventId(1)
        let threadRow = TimelineMessageDisplayItem(
            message: Self.items([
                F.record(
                    id: F.eventId(2), event: Self.event(Self.approvalAllowed[1]),
                    thread: TimelineThreadRefFfi(rootMessageIdHex: task, parentMessageIdHex: task))
            ])[0],
            dayLabel: "Today")
        let rows = [
            TimelineMessageDisplayItem(
                message: Self.items([
                    F.record(
                        id: task,
                        event: ["type": "task", "state": "running", "title": "Subagent", "body": ["kind": "subagent"]])
                ])[0],
                dayLabel: "Yesterday"),
            threadRow,
            TimelineMessageDisplayItem(
                message: Self.items([F.words(id: F.eventId(3), text: "done")])[0], dayLabel: nil),
        ]
        let transcript = AgentTranscript.build(
            displayItems: rows, localAccountIdHex: F.person, sends: { _ in [] }, requestSender: { _ in nil })
        #expect(transcript.mainItems.map(\.dayLabel) == ["Yesterday", "Today"])
    }

    @Test func theRunningTurnAndTheSessionAreFound() {
        let transcript = F.transcript
        #expect(transcript.runningTurn?.firstEventIdHex == F.eventId(2))
        #expect(transcript.session?.firstEventIdHex == F.eventId(1))
        #expect(transcript.hasAgentActivity)
    }

    /// A subagent's items go to its thread under its `task` row; a waiting approval in the thread
    /// is lifted onto the row so it can be answered from the main chat.
    @Test func aSubagentsItemsGoToItsThreadAndItsWaitingApprovalShowsOnTheRow() throws {
        let transcript = F.transcript
        let taskId = F.eventId(10)
        let threadApproval = F.eventId(11)
        #expect(!transcript.mainItems.contains { $0.id == threadApproval })
        #expect(transcript.threads[taskId]?.map(\.id) == [threadApproval])
        let task = try #require(transcript.mainItems.first { $0.id == taskId }?.message.agent)
        #expect(task.threadSummary?.rowCount == 1)
        #expect(task.threadSummary?.waiting.map(\.id) == [threadApproval])
        #expect(transcript.waiting.map(\.firstEventIdHex).contains(threadApproval))
    }

    /// Nothing whose `task` row is not loaded disappears: it shows in the main chat, marked.
    @Test func aThreadItemWhoseTaskIsNotLoadedStaysInTheMainChat() throws {
        let transcript = Self.transcript([
            F.record(
                id: F.eventId(11), event: Self.event(Self.approvalAllowed[1]),
                thread: TimelineThreadRefFfi(rootMessageIdHex: F.eventId(99), parentMessageIdHex: F.eventId(99)))
        ])
        let row = try #require(transcript.mainItems.first?.message.agent)
        #expect(row.isOutsideItsThread)
    }

    @Test func aNestedSubagentHasItsOwnThread() {
        let root = F.eventId(1)
        let nested = F.eventId(2)
        let task: [String: Any] = [
            "type": "task", "state": "running", "title": "Subagent", "body": ["kind": "subagent"],
        ]
        let transcript = Self.transcript([
            F.record(id: root, event: task),
            F.record(
                id: nested, event: task,
                thread: TimelineThreadRefFfi(rootMessageIdHex: root, parentMessageIdHex: root)),
            F.record(
                id: F.eventId(3), event: Self.event(Self.approvalAllowed[1]),
                thread: TimelineThreadRefFfi(rootMessageIdHex: root, parentMessageIdHex: nested)),
        ])
        #expect(transcript.mainItems.map(\.id) == [root])
        #expect(transcript.threads[root]?.map(\.id) == [nested])
        #expect(transcript.threads[nested]?.map(\.id) == [F.eventId(3)])
        let rootSummary = transcript.mainItems.first?.message.agent?.threadSummary
        #expect(rootSummary?.rowCount == 2)
        #expect(rootSummary?.waiting.map(\.id) == [F.eventId(3)])
    }

    /// Only a `task` row opens a thread, so a reply to a tool inside a subagent's thread goes to
    /// that subagent's thread (its root), not to a thread of the tool nobody can open.
    @Test func aReplyToAToolInAThreadStaysInTheSubagentsThread() {
        let task = F.eventId(1)
        let tool = F.eventId(2)
        let reply = F.eventId(3)
        let records = [
            F.record(
                id: task,
                event: ["type": "task", "state": "running", "title": "Subagent", "body": ["kind": "subagent"]]),
            F.record(
                id: tool, event: Self.event(Self.approvalAllowed[3]),
                thread: TimelineThreadRefFfi(rootMessageIdHex: task, parentMessageIdHex: task)),
            timelineMessage(
                id: reply, groupIdHex: F.groupIdHex, sender: F.person, plaintext: "why that file?", kind: 1111,
                recordedAt: 2, thread: TimelineThreadRefFfi(rootMessageIdHex: task, parentMessageIdHex: tool)),
        ]
        let transcript = Self.transcript(records)
        #expect(transcript.mainItems.map(\.id) == [task])
        #expect(transcript.threads[task]?.map(\.id) == [tool, reply])
        #expect(transcript.threads[tool] == nil)
    }

    /// A person's reply in a subagent's thread is a full transcript row there, attachments and
    /// all, even with no text: the thread draws it with the main chat's cell.
    @Test func anAttachmentOnlyReplyInAThreadKeepsItsAttachment() throws {
        let task = F.eventId(1)
        let reply = F.eventId(2)
        let transcript = Self.transcript([
            F.record(
                id: task,
                event: ["type": "task", "state": "running", "title": "Subagent", "body": ["kind": "subagent"]]),
            timelineMessage(
                id: reply, groupIdHex: F.groupIdHex, sender: F.person, plaintext: "", kind: 1111, recordedAt: 2,
                media: [mediaAttachmentReference(mediaType: "image/png", fileName: "screen.png")],
                thread: TimelineThreadRefFfi(rootMessageIdHex: task, parentMessageIdHex: task)),
        ])
        let rows = TranscriptRow.threadRows(
            transcript.threads[task] ?? [], searchMatchMessageId: nil, searchHighlight: nil,
            context: TranscriptRowContext(
                canVoteInPolls: true, showsDebugMetadata: false, isSelectionMode: false, localeIdentifier: "en",
                referenceDay: 0))
        let messages = rows.compactMap { row -> MessageItem? in
            guard case .message(let item, _, _, _, _, _) = row else { return nil }
            return item.message
        }
        #expect(messages.map(\.id) == [reply])
        #expect(try #require(messages.first).mediaAttachments.count == 1)
    }

    /// Search and reply previews reveal a message in a thread by opening every thread around it,
    /// outermost first; a message in the main chat needs none.
    @Test func revealingAThreadMessageOpensTheThreadsAroundIt() {
        let root = F.eventId(1)
        let nested = F.eventId(2)
        let deep = F.eventId(3)
        let task: [String: Any] = [
            "type": "task", "state": "running", "title": "Subagent", "body": ["kind": "subagent"],
        ]
        let transcript = Self.transcript([
            F.record(id: root, event: task),
            F.record(
                id: nested, event: task, thread: TimelineThreadRefFfi(rootMessageIdHex: root, parentMessageIdHex: root)),
            timelineMessage(
                id: deep, groupIdHex: F.groupIdHex, sender: F.person, plaintext: "look here", kind: 1111,
                recordedAt: 3, thread: TimelineThreadRefFfi(rootMessageIdHex: root, parentMessageIdHex: nested)),
        ])
        #expect(transcript.threadPath(to: deep) == [root, nested])
        #expect(transcript.threadPath(to: nested) == [root])
        #expect(transcript.threadPath(to: root) == nil)
        // A first unread message deep in a thread draws its divider on the task row the main
        // chat shows, so opening the chat lands there instead of at the window's top.
        #expect(transcript.mainChatRow(for: deep) == root)
        #expect(transcript.mainChatRow(for: root) == root)
    }

    @Test func kind1202RowsAreNeverShown() {
        let transcript = Self.transcript([
            F.record(id: F.eventId(1), event: Self.event(Self.approvalAllowed[0])),
            timelineMessage(
                id: F.eventId(2), groupIdHex: F.groupIdHex, sender: F.person, plaintext: "Stop",
                kind: AgentItem.requestKind, recordedAt: 2),
        ])
        #expect(transcript.mainItems.map(\.id) == [F.eventId(1)])
    }

    @Test func aSecretIsAnsweredFromTheChatOnlyWhereTwoAreInIt() {
        let model = AgentChatModel(groupIdHex: F.groupIdHex, ledger: nil)
        #expect(model.actions(memberCount: 2, isDirect: false, copyText: { _ in }).canAnswerSecret)
        #expect(!model.actions(memberCount: 3, isDirect: false, copyText: { _ in }).canAnswerSecret)
        #expect(!model.actions(memberCount: 3, isDirect: true, copyText: { _ in }).canAnswerSecret)
    }

    /// The pane's view and its scroll request change together, so the table made for a new view
    /// never applies the last one's: a thread opens at its newest row, Back returns to the row it
    /// left from, and leaving the pane forgets both.
    @Test func threadsOpenAndCloseInOrderEachWithItsOwnScroll() {
        let model = AgentChatModel(groupIdHex: F.groupIdHex, ledger: nil)
        model.openThread("a")
        #expect(model.scrollRequest?.target == .bottom)
        model.openThread("b")
        #expect(model.threadPath == ["a", "b"])
        model.closeThread()
        #expect(model.threadPath == ["a"])
        #expect(model.scrollRequest?.target == .center(id: "b"))
        model.openThread("b")
        model.openThread("a")
        #expect(model.threadPath == ["a"])
        model.openThread("b")
        model.closeAllThreads()
        #expect(model.threadPath.isEmpty)
        #expect(model.scrollRequest?.target == .center(id: "a"))
        model.scroll(TranscriptScrollRequest(target: .center(id: "m")), inThreads: ["a"])
        #expect(model.threadPath == ["a"])
        #expect(model.scrollRequest?.target == .center(id: "m"))
        model.leavePane()
        #expect(model.threadPath.isEmpty)
        #expect(model.scrollRequest == nil)
    }

    @Test func aFinishedTurnSaysHowItEndedAndWhatItUsed() throws {
        let rows = Self.items([F.record(id: F.eventId(1), event: Self.event(Self.approvalAllowed[4]))])
        let item = try #require(rows.first?.agent?.item)
        guard case .turn(let turn) = item.body else { throw Failure("turn") }
        let summary = try #require(AgentItemPresentation.turnSummary(item: item, turn: turn))
        #expect(summary.contains(L10n.string("Finished")))
        #expect(turn.usage?.input_tokens == 31085)
    }
}

private struct Failure: Error {
    let what: String
    init(_ what: String) { self.what = what }
}
