// coverage:ignore-file
//  Agent items for previews and tests, shaped like marmot-agents' recorded Codex sessions
//  (`fixtures/recordings/codex/expected/*.jsonl`). DEBUG only, like the rest of DebugSupport.

#if DEBUG
    import Foundation
    import MarmotKit

    nonisolated enum AgentPreviewFixtures {
        static let groupIdHex = String(repeating: "a1", count: 32)
        static let agent = String(repeating: "aa", count: 32)
        static let person = String(repeating: "bb", count: 32)

        /// A row of kind 1201 holding `event` (a marmot-agents event as JSON, `native` left out) at
        /// `version`, as MDK hands it over.
        static func record(
            id: String,
            event: [String: Any],
            version: UInt64 = 1,
            sender: String = agent,
            at: UInt64 = 1_800_000_000,
            settles: [String] = [],
            alerts: Bool? = nil,
            thread: TimelineThreadRefFfi? = nil,
            extraTags: [[String]] = [],
            firstEventMissing: Bool = false
        ) -> TimelineMessageRecordFfi {
            let type = event["type"] as? String ?? "notice"
            let stateName = event["state"] as? String ?? "done"
            let state: AgentItemStateFfi =
                switch stateName {
                case "running": .running
                case "waiting": .waiting
                case "failed": .failed
                case "declined": .declined
                case "cancelled": .cancelled
                default: .done
                }
            let fields: [String: Any] = ["type": type, "body": event["body"] ?? [:]]
            let fieldsJSON =
                String(
                    data: (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data(),
                    encoding: .utf8) ?? "{}"
            let item = AgentItemFfi(
                version: version,
                state: state,
                title: event["title"] as? String ?? "",
                harness: event["harness"] as? String ?? "codex",
                itemId: event["item"] as? String ?? id,
                seq: (event["seq"] as? NSNumber)?.uint64Value ?? 1,
                itemType: type,
                fieldsJson: fieldsJSON,
                session: event["session"] as? String,
                turn: event["turn"] as? String,
                startedByMessageIdHex: nil,
                settles: settles,
                alerts: alerts ?? ((type == "approval" || type == "question") && state == .waiting)
            )
            var tags: [[String]] = [["v", "\(version)"], ["state", stateName]]
            tags += extraTags
            return timelineMessage(
                id: id,
                groupIdHex: groupIdHex,
                sender: sender,
                plaintext: event["text"] as? String ?? "",
                kind: AgentItem.itemKind,
                tags: tags.map { MessageTagFfi(values: $0) },
                recordedAt: at,
                thread: thread,
                agentItem: item,
                agentItemFirstEventMissing: firstEventMissing
            )
        }

        static func words(
            id: String, text: String, turn: String = "t1", commentary: Bool = false, at: UInt64 = 1_800_000_000
        ) -> TimelineMessageRecordFfi {
            var tags = [["turn", turn]]
            if commentary { tags.append(["phase", "commentary"]) }
            return timelineMessage(
                id: id, groupIdHex: groupIdHex, sender: agent, plaintext: text, kind: 9,
                tags: tags.map { MessageTagFfi(values: $0) }, recordedAt: at)
        }

        static func eventId(_ n: Int) -> String {
            String(format: "%064x", n)
        }

        static var records: [TimelineMessageRecordFfi] {
            [
                record(
                    id: eventId(1),
                    event: [
                        "type": "session", "state": "running", "title": "Session",
                        "text": "Model: gpt-6.1-sol, Approval policy: untrusted",
                        "body": [
                            "harness_version": "0.169.0",
                            "settings": [
                                [
                                    "id": "model", "label": "Model", "value": "gpt-6.1-sol",
                                    "options": ["gpt-6.1-sol", "gpt-6.2-sol"],
                                ],
                                [
                                    "id": "approval_policy", "label": "Approval policy", "value": "untrusted",
                                    "approve": true,
                                ],
                            ],
                            "actions": [
                                ["id": "compact", "label": "Compact", "description": "Compact the conversation"]
                            ],
                            "commands": [["name": "review", "description": "Review changes", "hint": ""]],
                        ],
                    ]),
                record(
                    id: eventId(2),
                    event: [
                        "type": "turn", "state": "running", "title": "Working", "text": "",
                        "turn": "t1", "body": ["started_by": "user"],
                    ]),
                words(id: eventId(3), text: "I’ll run `python3 greet.py` and report its output.", commentary: true),
                record(
                    id: eventId(4),
                    event: [
                        "type": "tool", "state": "done", "title": "Ran a command", "turn": "t1",
                        "text": "/usr/bin/zsh -lc 'python3 greet.py'",
                        "body": [
                            "kind": "command", "name": "shell", "command": "/usr/bin/zsh -lc 'python3 greet.py'",
                            "cwd": "/work/demo", "exit_code": 0, "duration_ms": 12, "output": "Hello, world\n",
                        ],
                    ], version: 2),
                record(
                    id: eventId(5),
                    event: [
                        "type": "approval", "state": "waiting", "title": "Allow this command?", "turn": "t1",
                        "text": "/usr/bin/zsh -lc 'rm -rf build'",
                        "body": [
                            "subject": "exec-1",
                            "choices": [
                                ["id": "c0", "label": "Allow once", "effect": "allow"],
                                [
                                    "id": "c1", "label": "Allow, and don't ask again for this command",
                                    "effect": "allow",
                                ],
                                ["id": "c2", "label": "Deny and stop", "effect": "deny"],
                                ["id": "c3", "label": "Deny", "effect": "deny"],
                            ],
                        ],
                    ]),
                record(
                    id: eventId(6),
                    event: [
                        "type": "tool", "state": "running", "title": "Editing files", "turn": "t1",
                        "text": "/work/demo/greet.py",
                        "body": [
                            "kind": "edit", "name": "apply_patch",
                            "changes": [
                                [
                                    "path": "/work/demo/greet.py", "change": "update",
                                    "diff":
                                        "@@ -1,3 +1,3 @@\n def greet(name):\n-    return \"Hello, \" + name\n+    return \"Hello, \" + name + \"!\"\n",
                                ]
                            ],
                        ],
                    ]),
                record(
                    id: eventId(7),
                    event: [
                        "type": "plan", "state": "running", "title": "Plan", "turn": "t1", "text": "",
                        "body": [
                            "entries": [
                                ["text": "Read greet.py", "state": "done"],
                                ["text": "Fix the greeting", "state": "running"],
                                ["text": "Run the tests", "state": "pending"],
                            ]
                        ],
                    ]),
                record(
                    id: eventId(8),
                    event: [
                        "type": "reasoning", "state": "done", "title": "Thinking", "turn": "t1",
                        "text": "The test expects an exclamation mark.", "body": [:],
                    ]),
                record(
                    id: eventId(9),
                    event: [
                        "type": "question", "state": "waiting", "title": "Question", "turn": "t1",
                        "text": "Which greeting?",
                        "body": [
                            "answer_via": "request",
                            "questions": [
                                [
                                    "id": "q0", "text": "Which greeting should greet.py use?", "multiple": false,
                                    "allow_text": true,
                                    "options": [["id": "o0", "label": "Hello"], ["id": "o1", "label": "Hi"]],
                                ],
                                ["id": "q1", "text": "API token", "secret": true],
                            ],
                        ],
                    ]),
                record(
                    id: eventId(10),
                    event: [
                        "type": "task", "state": "running", "title": "Subagent", "turn": "t1",
                        "text": "Check other callers",
                        "body": ["kind": "subagent", "description": "Check other callers"],
                    ]),
                record(
                    id: eventId(11),
                    event: [
                        "type": "approval", "state": "waiting", "title": "Allow this command?",
                        "text": "/usr/bin/zsh -lc 'rg greet'",
                        "body": [
                            "choices": [
                                ["id": "c0", "label": "Allow once", "effect": "allow"],
                                ["id": "c3", "label": "Deny", "effect": "deny"],
                            ]
                        ],
                    ],
                    thread: TimelineThreadRefFfi(rootMessageIdHex: eventId(10), parentMessageIdHex: eventId(10))),
                record(
                    id: eventId(12),
                    event: [
                        "type": "notice", "state": "done", "title": "Not acted on",
                        "text": "Only the owner may approve in this chat.",
                        "body": ["kind": "refused", "reason": "not_allowed"],
                    ]),
                record(
                    id: eventId(13),
                    event: [
                        "type": "error", "state": "failed", "title": "Error",
                        "text": "The model gpt-9 does not exist.", "body": ["code": 400],
                    ]),
                words(id: eventId(14), text: "It printed: Hello, world"),
            ]
        }

        static var messages: [MessageItem] {
            MessageItem.timeline(
                from: TimelinePageFfi(messages: records, hasMoreBefore: false, hasMoreAfter: false),
                activeAccountIdHex: person
            )
        }

        static var transcript: AgentTranscript {
            AgentTranscript.build(
                displayItems: TimelineMessageDisplayItem.make(from: messages),
                localAccountIdHex: person,
                sends: { _ in [] },
                requestSender: { _ in nil }
            )
        }
    }
#endif
