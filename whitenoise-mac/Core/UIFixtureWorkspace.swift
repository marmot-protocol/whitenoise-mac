#if DEBUG
    import AppKit
    import Foundation
    import MarmotKit

    extension WorkspaceState {
        static func uiFixture(named name: String) -> WorkspaceState {
            switch name {
            case "heavy-chat", "performance", "perf":
                UIFixtureWorkspace.makeHeavyChatWorkspace()
            default:
                UIFixtureWorkspace.makeHeavyChatWorkspace()
            }
        }
    }

    private enum UIFixtureWorkspace {
        private static let account = AccountItem(
            id: "ui-fixture-account",
            accountRef: "ui-fixture",
            displayName: "UI Fixture",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            npub: nil,
            initials: "UI",
            pictureURL: nil,
            localSigning: false,
            isRunning: false
        )

        private static let heavyChatId = "ui-fixture-heavy-chat"
        private static let baseDate = Date(timeIntervalSince1970: 1_787_000_000)

        static func makeHeavyChatWorkspace() -> WorkspaceState {
            let chats = makeChats()
            let allMessages = makeMessages()
            let messages = Array(allMessages.suffix(WorkspaceState.timelineWindowLimit))
            let state = WorkspaceState(
                accounts: [account],
                chatsByAccount: [account.id: chats],
                messagesByChat: [heavyChatId: messages],
                appActivityProvider: { true },
                conversationWindowVisibilityProvider: { true },
                clientFactory: { throw PreviewRuntimeError() }
            )
            state.activeAccountId = account.id
            state.selection = .chat(heavyChatId)
            preloadMediaDownloads(for: messages, in: state)
            return state
        }

        private static func makeChats() -> [ChatItem] {
            var chats = [
                ChatItem(
                    id: heavyChatId,
                    title: "Heavy Chat Fixture",
                    subtitle: "\(WorkspaceState.timelineWindowLimit) visible of 900 messages",
                    preview:
                        "Deterministic scroll, markdown, reaction, and media stress data at the production window cap.",
                    updatedAt: baseDate,
                    avatarSeed: heavyChatId,
                    pictureURL: nil,
                    unreadCount: 12,
                    unreadMentionCount: 3
                )
            ]

            for index in 1...220 {
                let bucket: String
                switch index % 5 {
                case 0:
                    bucket = "Launch Review"
                case 1:
                    bucket = "Media Lab"
                case 2:
                    bucket = "Relay Ops"
                case 3:
                    bucket = "Design Bench"
                default:
                    bucket = "Search Load"
                }

                chats.append(
                    ChatItem(
                        id: "ui-fixture-chat-\(index)",
                        title: "\(bucket) \(index)",
                        subtitle: index % 4 == 0 ? "Direct message" : "\(2 + index % 37) members",
                        preview: "Fixture preview \(index) with searchable terms and stable ordering.",
                        updatedAt: baseDate.addingTimeInterval(Double(-index * 137)),
                        avatarSeed: "ui-fixture-chat-\(index)",
                        pictureURL: nil,
                        unreadCount: index % 7,
                        unreadMentionCount: index % 19 == 0 ? 1 : 0,
                        isDirect: index % 4 == 0
                    )
                )
            }

            return chats
        }

        private static func makeMessages() -> [MessageItem] {
            (0..<900).map { index in
                let isOutgoing = index % 3 == 0
                let sender = senderName(index: index, isOutgoing: isOutgoing)
                let mediaAttachments = makeMediaAttachments(messageIndex: index)
                let usesMarkdown = index % 7 == 0
                let body = messageBody(index: index, usesMarkdown: usesMarkdown, hasMedia: !mediaAttachments.isEmpty)

                return MessageItem(
                    id: "ui-fixture-message-\(index)",
                    groupIdHex: heavyChatId,
                    senderAccountIdHex: senderAccountId(index: index, isOutgoing: isOutgoing),
                    senderName: sender,
                    body: body,
                    contentMarkdown: usesMarkdown ? richMarkdownDocument(index: index) : nil,
                    sentAt: baseDate.addingTimeInterval(Double(index * 61)),
                    timelineAt: UInt64(1_787_000_000 + index),
                    isOutgoing: isOutgoing,
                    reactions: reactions(index: index),
                    replyContext: replyContext(index: index),
                    mediaAttachments: mediaAttachments
                )
            }
        }

        private static func senderName(index: Int, isOutgoing: Bool) -> String {
            if isOutgoing { return "UI Fixture" }
            let names = ["Avery", "Mina", "Noor", "Rafa", "Sam", "Tess", "Vik"]
            return names[index % names.count]
        }

        private static func senderAccountId(index: Int, isOutgoing: Bool) -> String {
            isOutgoing
                ? account.accountIdHex
                : hex64(index &* 97 &+ 3)
        }

        private static func messageBody(index: Int, usesMarkdown: Bool, hasMedia: Bool) -> String {
            if hasMedia, index % 4 == 0 {
                return ""
            }

            if usesMarkdown {
                return """
                    ### Release checklist \(index)

                    Review **rendering**, validate _scroll position_, and compare `timeline` behavior.
                    - No jump when older history prepends
                    - No full transcript diff for one update
                    """
            }

            let repeatedClause = "message \(index) keeps the bubble text realistic while remaining deterministic"
            switch index % 6 {
            case 0:
                return "Short fixture note: \(repeatedClause)."
            case 1:
                return
                    "Longer fixture note: \(repeatedClause). It includes enough words to wrap across lines and exercise row height measurement in a dense transcript."
            case 2:
                return
                    "Mention @fixture with punctuation, URLs like https://example.com/\(index), and stable timestamps."
            case 3:
                return "Searchable Launch Media Relay Design content \(index)."
            case 4:
                return "Replying with a medium sized paragraph so scrolling crosses a mix of compact and tall rows."
            default:
                return "Plain text row \(index)."
            }
        }

        private static func reactions(index: Int) -> [MessageReaction] {
            guard index % 23 == 0 else { return [] }
            return [
                MessageReaction(emoji: "+1", count: 2, isOwn: index % 2 == 0),
                MessageReaction(emoji: "OK", count: 1, isOwn: false),
            ]
        }

        private static func replyContext(index: Int) -> MessageReplyContext? {
            guard index > 4, index % 19 == 0 else { return nil }
            return MessageReplyContext(
                targetMessageId: "ui-fixture-message-\(index - 4)",
                senderName: senderName(index: index - 4, isOutgoing: (index - 4) % 3 == 0),
                body: "Earlier fixture message \(index - 4)"
            )
        }

        private static func makeMediaAttachments(messageIndex: Int) -> [MessageMediaAttachment] {
            let mediaDenseTail = messageIndex >= 820 && messageIndex % 2 == 0
            guard messageIndex % 13 == 0 || mediaDenseTail else { return [] }

            let count = mediaDenseTail ? 4 : 1 + (messageIndex % 4)
            return (0..<count).map { attachmentIndex in
                let fileName = "fixture-\(messageIndex)-\(attachmentIndex).png"
                return MessageMediaAttachment(
                    id: "ui-fixture-media-\(messageIndex)-\(attachmentIndex)",
                    reference: MediaAttachmentReferenceFfi(
                        locators: [
                            MediaLocatorFfi(kind: "blossom", value: "https://fixture.invalid/\(fileName)")
                        ],
                        ciphertextSha256: hex64(messageIndex &* 31 &+ attachmentIndex),
                        plaintextSha256: hex64(messageIndex &* 43 &+ attachmentIndex &+ 10_000),
                        nonceHex: hex24(messageIndex &* 59 &+ attachmentIndex),
                        fileName: fileName,
                        mediaType: "image/png",
                        version: "marmot.encrypted-media.v1",
                        sourceEpoch: UInt64(messageIndex),
                        dim: "160x120",
                        thumbhash: nil
                    )
                )
            }
        }

        private static func preloadMediaDownloads(for messages: [MessageItem], in state: WorkspaceState) {
            let imageData = fixtureImageData
            for message in messages {
                for attachment in message.mediaAttachments {
                    state.mediaDownloadStateStore(for: message, attachment: attachment)
                        .update(
                            .loaded(
                                MessageMediaDownload(
                                    data: imageData,
                                    fileName: attachment.fileName,
                                    mediaType: attachment.mediaType,
                                    sizeBytes: UInt64(imageData.count),
                                    payloadId: "ui-fixture-payload-\(attachment.id)"
                                )
                            )
                        )
                }
            }
        }

        private static var fixtureImageData: Data {
            let fallback =
                Data(
                    base64Encoded:
                        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
                ) ?? Data()

            let size = NSSize(width: 160, height: 120)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.68, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.23, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 24, y: 20, width: 76, height: 76)).fill()
            NSColor(calibratedRed: 0.84, green: 0.18, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 92, y: 52, width: 48, height: 42)).fill()
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { return fallback }
            return png
        }

        private static func richMarkdownDocument(index: Int) -> MarkdownDocumentFfi {
            MarkdownDocumentFfi(
                blocks: [
                    .heading(
                        level: 3,
                        inlines: [
                            .text(content: "Release checklist \(index)")
                        ]),
                    .paragraph(inlines: [
                        .text(content: "Review "),
                        .strong(children: [.text(content: "rendering")]),
                        .text(content: ", validate "),
                        .emph(children: [.text(content: "scroll position")]),
                        .text(content: ", and open "),
                        .link(
                            dest: "https://example.com/perf/\(index)",
                            title: nil,
                            children: [.text(content: "perf notes")]
                        ),
                        .text(content: "."),
                    ]),
                    .list(
                        kind: .bullet(marker: "-"),
                        tight: true,
                        items: [
                            MarkdownListItemFfi(
                                blocks: [
                                    .paragraph(inlines: [.text(content: "No jump when older history prepends")])
                                ],
                                checked: nil
                            ),
                            MarkdownListItemFfi(
                                blocks: [
                                    .paragraph(inlines: [.text(content: "No full transcript diff for one update")])
                                ],
                                checked: true
                            ),
                        ]
                    ),
                    .table(
                        alignments: [.left, .right],
                        header: [
                            MarkdownTableCellFfi(inlines: [.text(content: "Path")]),
                            MarkdownTableCellFfi(inlines: [.text(content: "Target")]),
                        ],
                        rows: [
                            [
                                MarkdownTableCellFfi(inlines: [.code(content: "body")]),
                                MarkdownTableCellFfi(inlines: [.text(content: "< 16ms")]),
                            ],
                            [
                                MarkdownTableCellFfi(inlines: [.code(content: "diff")]),
                                MarkdownTableCellFfi(inlines: [.text(content: "bounded")]),
                            ],
                        ]
                    ),
                    .codeBlock(
                        kind: .fenced,
                        info: "swift",
                        content: "let row = ConversationMessageRow(message: item)"
                    ),
                ],
                truncated: false
            )
        }

        private static func hex64(_ seed: Int) -> String {
            String(format: "%064llx", UInt64(truncatingIfNeeded: seed))
        }

        private static func hex24(_ seed: Int) -> String {
            String(format: "%024llx", UInt64(truncatingIfNeeded: seed))
        }
    }
#endif
