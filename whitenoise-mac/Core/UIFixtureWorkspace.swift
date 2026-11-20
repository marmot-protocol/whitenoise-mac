#if DEBUG
    import AppKit
    import CryptoKit
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

    /// The DEBUG-only `-uiFixture heavy-chat` workspace: one signed-in account on an in-memory
    /// `FakeMarmotRuntime`, so a UI test drives the app's real session, chat list and conversation
    /// code against deterministic data, with no network. Its account data, file stores and media
    /// cache live in a fresh temporary directory, but it is otherwise the same app as a normal
    /// Debug launch: preferences a UI test changes are the development app's.
    ///
    /// It has to be a runtime underneath rather than rows handed to the views: the conversation
    /// pane is built from the account scope, which exists only once the runtime has brought the
    /// account online. A fixture that seeded the views directly stopped showing a transcript when
    /// the conversation moved onto `AccountScope`.
    private enum UIFixtureWorkspace {
        private static let account = AccountSummaryFfi(
            label: "UI Fixture",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )

        private static let heavyChatId = "ui-fixture-heavy-chat"
        private static let heavyChatTitle = "Heavy Chat Fixture"
        private static let baseDate = Date(timeIntervalSince1970: 1_787_000_000)
        private static let messageCount = 900

        static func makeHeavyChatWorkspace() -> WorkspaceState {
            // A fresh directory per launch: the file stores `WorkspaceState` keeps beside the core
            // (hidden messages, pins, nicknames) never see another launch's records.
            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("whitenoise-ui-fixture-\(UUID().uuidString)", isDirectory: true)
            let runtime = FakeMarmotRuntime(accounts: [account], storageRootPath: storageRoot.path)
            runtime.installProfile(
                accountIdHex: account.accountIdHex,
                profile: UserProfileMetadataFfi(
                    name: "ui-fixture",
                    displayName: "UI Fixture",
                    about: nil,
                    picture: nil,
                    nip05: nil,
                    lud16: nil
                )
            )
            runtime.installGroups(makeGroups())
            runtime.answersTextFiltersFromTitles = true
            // Answered, so launch doesn't put the diagnostics prompt over the transcript.
            runtime.usageSettings.decision = .declined

            let messages = Array(makeMessages().suffix(WorkspaceState.timelineWindowLimit))
            runtime.conversationWindowInitialSnapshots[heavyChatId] = conversationSnapshot(messages: messages)
            installMedia(for: messages, in: runtime)

            // Its own media cache too: the shared one is the development app's Application Support
            // directory and keychain item, and evicts that app's entries when it fills up.
            let mediaCacheRoot = storageRoot.appendingPathComponent("media-cache", isDirectory: true)
            let mediaCacheKey = SymmetricKey(size: .bits256)
            let mediaDiskCache = MessageMediaDiskCache(
                directoryResolver: { mediaCacheRoot },
                keyProvider: { mediaCacheKey },
                keyDeleter: {}
            )
            let state = WorkspaceState(
                appActivityProvider: { true },
                conversationWindowVisibilityProvider: { true },
                mediaDiskCache: mediaDiskCache,
                clientFactory: { runtime }
            )
            // Named before bootstrap, so bootstrap keeps it rather than picking one and saving that
            // as the account the next normal launch reopens: a fixture launch shares the app's
            // preferences.
            state.activeAccountId = AccountItem(summary: account).id
            // Opens on the heavy chat, so a UI test starts at its transcript.
            state.selection = .chat(heavyChatId)
            return state
        }

        private static func makeGroups() -> [AppGroupRecordFfi] {
            var groups = [group(id: heavyChatId, name: heavyChatTitle)]
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
                groups.append(group(id: "ui-fixture-chat-\(index)", name: "\(bucket) \(index)"))
            }
            return groups
        }

        private static func group(id: String, name: String) -> AppGroupRecordFfi {
            AppGroupRecordFfi(
                groupIdHex: id,
                endpoint: "",
                name: name,
                description: "",
                admins: [],
                relays: MarmotClient.seedRelays,
                nostrGroupIdHex: "",
                avatarUrl: nil,
                avatarDim: nil,
                avatarThumbhash: nil,
                imageHashHex: nil,
                encryptedMedia: encryptedMediaComponent(),
                disappearingMessageSecs: 0,
                archived: false,
                pendingConfirmation: false,
                selfMembership: .member,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            )
        }

        private static func makeMessages() -> [ConversationMessageFfi] {
            (0..<messageCount).map { index in
                let isOutgoing = index % 3 == 0
                let media = makeMediaReferences(messageIndex: index)
                let usesMarkdown = index % 7 == 0
                let invalidationStatus = deliveryFixtureInvalidationStatus(index: index)
                let record = timelineMessage(
                    id: messageId(index),
                    // Every ordinary row is relay-confirmed. Without a source id an old outgoing row
                    // reads as an unconfirmed send past its grace window and shows the red marker,
                    // which would hide the delivery fixtures below among 300 false failures.
                    sourceMessageIdHex: invalidationStatus == MessageItem.localPublishFailedStatus
                        ? nil : "ui-fixture-source-\(index)",
                    direction: isOutgoing ? "outbound" : "inbound",
                    groupIdHex: heavyChatId,
                    sender: senderAccountId(index: index, isOutgoing: isOutgoing),
                    plaintext: messageBody(index: index, usesMarkdown: usesMarkdown, hasMedia: !media.isEmpty),
                    recordedAt: UInt64(baseDate.timeIntervalSince1970) + UInt64(index * 61),
                    media: media,
                    replyToMessageIdHex: replyTarget(index: index).map { messageId($0) },
                    replyPreview: replyPreview(index: index),
                    contentTokens: usesMarkdown ? richMarkdownDocument(index: index) : emptyMarkdownDocument(),
                    invalidationStatus: invalidationStatus
                )
                return ConversationMessageFfi(
                    timeline: record,
                    references: ConversationMessageReferencesFfi(
                        messageIdHex: record.messageIdHex,
                        sender: record.sender,
                        replyAuthor: replyTarget(index: index).map {
                            senderAccountId(index: $0, isOutgoing: $0 % 3 == 0)
                        },
                        mentions: [],
                        mentionsTruncated: false,
                        replyMentions: [],
                        replyMentionsTruncated: false,
                        system: nil,
                        reactions: reactions(index: index)
                    )
                )
            }
        }

        private static func conversationSnapshot(messages: [ConversationMessageFfi]) -> ConversationWindowSnapshotFfi {
            ConversationWindowSnapshotFfi(
                revision: ConversationWindowRevisionFfi(generation: "ui-fixture", sequence: 1),
                header: ConversationHeaderFfi(
                    selected: ConversationPresentationFfi(
                        title: .literal(text: heavyChatTitle),
                        avatar: .placeholder(stableSeed: heavyChatId, source: .groupFallback),
                        titleSource: .group,
                        avatarSource: .groupFallback,
                        peerId: nil,
                        resolution: .cached
                    ),
                    memberCount: UInt64(senderNames.count + 1),
                    archived: false,
                    epoch: 1,
                    lifecycle: .stable,
                    disbanding: false,
                    unrecoverable: false,
                    capabilities: ConversationCapabilitiesFfi(
                        participation: .active,
                        isSelfAdmin: false,
                        isLastAdmin: false,
                        canSend: true,
                        canInvite: false,
                        canEditGroup: false,
                        canLeave: true,
                        requiresSelfDemoteBeforeLeave: false,
                        canCancelLeave: false,
                        canEnableDisbanding: false,
                        canDisband: false
                    ),
                    avatarAsset: nil
                ),
                messages: messages,
                identities: identities(),
                readState: ConversationOpenReadStateFfi(
                    initialized: true,
                    lastReadMessageIdHex: messages.last?.timeline.messageIdHex,
                    lastReadTimelineAt: messages.last?.timeline.timelineAt,
                    manuallyMarkedUnread: false,
                    unreadCount: 0,
                    unreadMentionCount: 0,
                    firstUnreadMessageIdHex: nil
                ),
                draft: SelectedMessageDraftFfi(
                    revision: MessageDraftRevisionFfi(noPointer: .init()),
                    draft: nil
                ),
                pendingConfirmation: false,
                anchor: ConversationAnchorOutcomeFfi(kind: .latest, index: nil),
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        /// The names the transcript shows for each sender, carried by the window as the core's
        /// prepared presentation.
        private static func identities() -> [ConversationIdentityFfi] {
            var identities = [identity(accountIdHex: account.accountIdHex, displayName: "UI Fixture")]
            for (offset, name) in senderNames.enumerated() {
                identities.append(identity(accountIdHex: incomingSenderId(offset), displayName: name))
            }
            return identities
        }

        private static func identity(accountIdHex: String, displayName: String) -> ConversationIdentityFfi {
            ConversationIdentityFfi(
                accountIdHex: accountIdHex,
                displayName: displayName,
                avatar: .placeholder(stableSeed: accountIdHex, source: .peerProfile),
                hasCachedProfile: true,
                avatarAsset: nil
            )
        }

        private static func messageId(_ index: Int) -> String {
            "ui-fixture-message-\(index)"
        }

        /// The delivery footer's three non-routine states, near the bottom of the chat so QA sees them
        /// without scrolling: an own message convergence retired (orange warning), someone else's
        /// (orange warning), and an own send the core retracted as unpublished (red, with Retry).
        /// Outgoing is `index % 3 == 0`, so 897 and 894 are own rows and 898 is incoming.
        private static func deliveryFixtureInvalidationStatus(index: Int) -> String? {
            switch index {
            case 897, 898: "losing_branch"
            case 894: MessageItem.localPublishFailedStatus
            default: nil
            }
        }

        private static let senderNames = ["Avery", "Mina", "Noor", "Rafa", "Sam", "Tess", "Vik"]

        private static func senderAccountId(index: Int, isOutgoing: Bool) -> String {
            isOutgoing ? account.accountIdHex : incomingSenderId(index % senderNames.count)
        }

        private static func incomingSenderId(_ offset: Int) -> String {
            hex64(offset &* 97 &+ 3)
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

        private static func reactions(index: Int) -> ConversationReactionsFfi {
            guard index % 23 == 0 else {
                return ConversationReactionsFfi(totalCount: 0, totalKinds: 0, items: [], omittedKinds: 0)
            }
            // The second +1 is the viewer's own on even rows; the chip's selection and the
            // reactor list have to agree on that.
            let viewerReacted = index % 2 == 0
            let items = [
                ConversationReactionFfi(
                    emoji: "+1",
                    count: 2,
                    reactors: [incomingSenderId(0), viewerReacted ? account.accountIdHex : incomingSenderId(2)],
                    viewerReacted: viewerReacted,
                    reactionMessageIdHex: "ui-fixture-reaction-\(index)-0"
                ),
                ConversationReactionFfi(
                    emoji: "OK",
                    count: 1,
                    reactors: [incomingSenderId(1)],
                    viewerReacted: false,
                    reactionMessageIdHex: "ui-fixture-reaction-\(index)-1"
                ),
            ]
            return ConversationReactionsFfi(totalCount: 3, totalKinds: 2, items: items, omittedKinds: 0)
        }

        private static func replyTarget(index: Int) -> Int? {
            guard index > 4, index % 19 == 0 else { return nil }
            return index - 4
        }

        private static func replyPreview(index: Int) -> TimelineReplyPreviewFfi? {
            guard let target = replyTarget(index: index) else { return nil }
            return TimelineReplyPreviewFfi(
                messageIdHex: messageId(target),
                sender: senderAccountId(index: target, isOutgoing: target % 3 == 0),
                plaintext: "Earlier fixture message \(target)",
                contentTokens: emptyMarkdownDocument(),
                kind: 9,
                mediaJson: nil,
                media: [],
                agentTextStreamJson: nil,
                deleted: false,
                invalidationStatus: nil
            )
        }

        private static func makeMediaReferences(messageIndex: Int) -> [MediaAttachmentReferenceFfi] {
            let mediaDenseTail = messageIndex >= 820 && messageIndex % 2 == 0
            guard messageIndex % 13 == 0 || mediaDenseTail else { return [] }

            let count = mediaDenseTail ? 4 : 1 + (messageIndex % 4)
            return (0..<count).map { attachmentIndex in
                let fileName = "fixture-\(messageIndex)-\(attachmentIndex).png"
                return MediaAttachmentReferenceFfi(
                    locators: [
                        MediaLocatorFfi(kind: "blossom", value: "https://fixture.invalid/\(fileName)")
                    ],
                    ciphertextSha256: hex64(messageIndex &* 31 &+ attachmentIndex),
                    // The digest of the bytes the runtime serves: the media cache keeps only bytes
                    // that match their reference, so a made-up digest is never cached.
                    plaintextSha256: fixtureImageDigest,
                    nonceHex: hex24(messageIndex &* 59 &+ attachmentIndex),
                    fileName: fileName,
                    mediaType: "image/png",
                    version: .v1,
                    sourceEpoch: UInt64(messageIndex),
                    dim: "160x120",
                    thumbhash: nil
                )
            }
        }

        /// Serves every fixture image through the runtime, so the transcript's tiles load on the
        /// same download path a real image takes.
        private static func installMedia(for messages: [ConversationMessageFfi], in runtime: FakeMarmotRuntime) {
            let imageData = fixtureImageData
            for message in messages {
                let record = message.timeline
                for case .accepted(let attachmentIndex, let reference) in record.media {
                    runtime.installMediaRecord(
                        MediaRecordFfi(
                            messageIdHex: record.messageIdHex,
                            attachmentIndex: attachmentIndex,
                            direction: record.direction,
                            groupIdHex: heavyChatId,
                            sender: record.sender,
                            reference: reference,
                            caption: nil,
                            recordedAt: record.timelineAt,
                            receivedAt: record.receivedAt
                        ),
                        download: MediaDownloadResultFfi(
                            plaintext: imageData,
                            fileName: reference.fileName,
                            mediaType: reference.mediaType,
                            sizeBytes: UInt64(imageData.count)
                        )
                    )
                }
            }
        }

        private static let fixtureImageDigest = MessageMediaDiskCacheKey.plaintextDigest(for: fixtureImageData)

        private static let fixtureImageData: Data = {
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
        }()

        private static func markdownDocument(
            blocks: [MarkdownBlockFfi],
            truncated: Bool
        ) -> MarkdownDocumentFfi {
            MarkdownDocumentFfi(
                blocks: blocks,
                truncated: truncated,
                blankLinesBefore: Data(repeating: 0, count: blocks.count)
            )
        }

        private static func richMarkdownDocument(index: Int) -> MarkdownDocumentFfi {
            markdownDocument(
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
                            children: [.text(content: "perf notes")],
                            classification: .web
                        ),
                        .text(content: "."),
                    ]),
                    .listBlock(
                        kind: .bullet(marker: "-"),
                        tight: true,
                        items: [
                            MarkdownListItemFfi(
                                blocks: [
                                    .paragraph(inlines: [.text(content: "No jump when older history prepends")])
                                ],
                                checked: nil,
                                blankLinesBefore: Data([0])
                            ),
                            MarkdownListItemFfi(
                                blocks: [
                                    .paragraph(inlines: [.text(content: "No full transcript diff for one update")])
                                ],
                                checked: true,
                                blankLinesBefore: Data([0])
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
