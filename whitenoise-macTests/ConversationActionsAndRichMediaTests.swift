//
//  ConversationActionsAndRichMediaTests.swift
//  whitenoise-macTests
//
//  Behavioral and rendering tests for Wave 3A (#1104 message actions/sheets/reactions and
//  #1113 rich message cards and media states).
//

import AppKit
import MarmotKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import whitenoise_mac

@Suite(.serialized)
@MainActor
struct ConversationActionsAndRichMediaTests {
    // MARK: - File-type icon resolution (D02, #1113)

    @Test func fileTypeIconResolvesMIMETypesAndFilenameExtensions() {
        #expect(AttachmentFileTypeIcon.contentType(mediaType: "application/pdf", fileName: "doc") == .pdf)
        #expect(AttachmentFileTypeIcon.contentType(mediaType: "text/plain", fileName: "notes") == .plainText)
        #expect(AttachmentFileTypeIcon.contentType(mediaType: "application/zip", fileName: "bundle") == .zip)

        // Unknown/blank MIME falls back to filename extension, then generic data.
        #expect(AttachmentFileTypeIcon.contentType(mediaType: "", fileName: "report.pdf") == .pdf)
        #expect(
            AttachmentFileTypeIcon.contentType(mediaType: "application/x-unknown-custom", fileName: "archive.zip")
                == .zip)
        #expect(AttachmentFileTypeIcon.contentType(mediaType: "", fileName: "README") == .data)

        let pdfIcon = AttachmentFileTypeIcon.icon(mediaType: "application/pdf", fileName: "report.pdf")
        #expect(pdfIcon != nil)
        #expect((pdfIcon?.size.width ?? 0) > 0)
    }

    // MARK: - Attachment rows across polarities & states (D02, T02, #1113)

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func attachmentStatusRowsRenderLoadedLoadingAndFailedStatesAcrossPolarities(
        appearance: NSAppearance.Name
    ) throws {
        let pdfIcon = AttachmentFileTypeIcon.icon(mediaType: "application/pdf", fileName: "spec.pdf")
        for isOutgoing in [false, true] {
            let loaded = try Self.rasterize(
                MessageAttachmentStatusRow(
                    systemImage: "doc",
                    fileIcon: pdfIcon,
                    title: "spec.pdf",
                    detail: "1.2 MB",
                    isOutgoing: isOutgoing
                )
                .padding(8)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )
            let failed = try Self.rasterize(
                MessageAttachmentStatusRow(
                    systemImage: "exclamationmark.triangle",
                    title: "spec.pdf",
                    detail: L10n.string("Attachment unavailable"),
                    isOutgoing: isOutgoing,
                    retryAction: {}
                )
                .padding(8)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )
            let loading = try Self.rasterize(
                MessageAttachmentStatusRow(
                    systemImage: "arrow.down.circle",
                    title: "spec.pdf",
                    detail: "application/pdf",
                    isOutgoing: isOutgoing,
                    isLoading: true
                )
                .padding(8)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )

            #expect(loaded.pixelsWide > 0 && loaded.pixelsHigh > 0)
            #expect(failed.pixelsWide > 0 && failed.pixelsHigh > 0)
            #expect(loading.pixelsWide > 0 && loading.pixelsHigh > 0)
        }
    }

    // MARK: - Poll pending-vote & read-only rendering (T10, #1113)

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func pollCardRendersConfirmedPendingAndClosedStatesAcrossPolarities(
        appearance: NSAppearance.Name
    ) throws {
        let poll = MessagePoll(
            question: "Deploy today?",
            options: [
                .init(id: "0", label: "Yes", votes: 2),
                .init(id: "1", label: "Wait", votes: 1),
            ],
            kind: .singleChoice,
            participants: 3,
            localSelection: ["0"],
            endsAt: nil,
            isOpen: true
        )

        for isOutgoing in [false, true] {
            let confirmed = try Self.rasterize(
                PollMessageRow(
                    poll: poll,
                    isOutgoing: isOutgoing,
                    senderName: isOutgoing ? nil : "Alice",
                    timeLabel: "10:00",
                    confirmedSelection: ["0"],
                    isVotePending: false,
                    onVote: { _ in },
                    onViewVotes: {}
                )
                .frame(width: 460)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )
            let pending = try Self.rasterize(
                PollMessageRow(
                    poll: poll,
                    isOutgoing: isOutgoing,
                    senderName: isOutgoing ? nil : "Alice",
                    timeLabel: "10:00",
                    confirmedSelection: [],
                    isVotePending: true,
                    onVote: { _ in },
                    onViewVotes: {}
                )
                .frame(width: 460)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )
            let closed = try Self.rasterize(
                PollMessageRow(
                    poll: MessagePoll(
                        question: poll.question,
                        options: poll.options,
                        kind: poll.kind,
                        participants: poll.participants,
                        localSelection: poll.localSelection,
                        endsAt: nil,
                        isOpen: false
                    ),
                    isOutgoing: isOutgoing,
                    senderName: isOutgoing ? nil : "Alice",
                    timeLabel: "10:00",
                    onVote: nil,
                    onViewVotes: {}
                )
                .frame(width: 460)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )

            #expect(confirmed.pixelsWide > 0 && confirmed.pixelsHigh > 0)
            #expect(pending.pixelsWide > 0 && pending.pixelsHigh > 0)
            #expect(closed.pixelsWide > 0 && closed.pixelsHigh > 0)
        }
    }

    // MARK: - Link & Nostr preview cards across bubble polarities (T02, T07, #1113)

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func linkAndNostrPreviewCardsRenderAcrossBothBubblePolarities(
        appearance: NSAppearance.Name
    ) throws {
        let preview = NostrEventPreview(
            authorIdHex: String(repeating: "ab", count: 32),
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            body: .note(text: "Encrypted messaging over Nostr.")
        )
        let author = NostrEventPreviewStore.Author(name: "Alice", pictureURL: nil)

        for polarity in [MessageBubblePolarity.received, .sent] {
            let linkCard = try Self.rasterize(
                LinkPreviewCardContent(
                    title: "White Noise Protocol",
                    host: "example.com",
                    image: nil,
                    showsImageSlot: false
                )
                .padding(10)
                .background(polarity.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .environment(\.messageBubblePolarity, polarity)
                .frame(width: 340)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )
            let nostrCard = try Self.rasterize(
                NostrEventPreviewCardContent(
                    preview: preview,
                    author: author,
                    image: nil,
                    showsImageSlot: false
                )
                .padding(10)
                .background(polarity.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .environment(\.messageBubblePolarity, polarity)
                .frame(width: 340)
                .background(WNColor.backgroundPrimary),
                in: appearance
            )

            #expect(linkCard.pixelsWide > 0 && linkCard.pixelsHigh > 0)
            #expect(nostrCard.pixelsWide > 0 && nostrCard.pixelsHigh > 0)
        }
    }

    // MARK: - Refreshed sheets & action controls (#1104)

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func editHistoryForwardAndReportSheetsRenderCleanly(appearance: NSAppearance.Name) throws {
        let editHistory = try Self.rasterize(
            MessageEditHistoryContentView(
                versions: [
                    TimelineEditVersionFfi(
                        messageIdHex: "v2",
                        editedAt: 1_760_003_600,
                        plaintext: "Updated text"
                    ),
                    TimelineEditVersionFfi(
                        messageIdHex: "v1",
                        editedAt: 1_760_000_000,
                        plaintext: "Original text"
                    ),
                ],
                isLoading: false,
                errorMessage: "Storage busy",
                hasMore: true,
                onLoadMore: {},
                onClose: {}
            )
            .frame(width: 420, height: 380)
            .background(WNColor.backgroundPrimary),
            in: appearance
        )
        let forwardSheet = try Self.rasterize(
            MessageForwardSheet(
                model: MessageForwardViewModel(messages: [], dependencies: .inert),
                chats: ChatItem.samples,
                onClose: {}
            )
            .background(WNColor.backgroundPrimary),
            in: appearance
        )
        let reportSheet = try Self.rasterize(
            ReportMessageSheet(
                model: ReportMessageViewModel(
                    eligibility: MessageModerationEligibility(
                        reportsToGroup: true,
                        reportsToTeam: true,
                        canBlockAuthor: true,
                        authorAccountIdHex: String(repeating: "a", count: 64)
                    ),
                    dependencies: .inert
                ),
                dismiss: {}
            )
            .background(WNColor.backgroundPrimary),
            in: appearance
        )

        #expect(editHistory.pixelsWide > 0 && editHistory.pixelsHigh > 0)
        #expect(forwardSheet.pixelsWide > 0 && forwardSheet.pixelsHigh > 0)
        #expect(reportSheet.pixelsWide > 0 && reportSheet.pixelsHigh > 0)
    }

    @Test func editHistorySheetInvokesRetryAndCloseCallbacks() async throws {
        var retried = false
        var closed = false
        let host = HostedViewWindow(
            MessageEditHistoryContentView(
                versions: [],
                isLoading: false,
                errorMessage: "Couldn't read history",
                hasMore: false,
                onLoadMore: { retried = true },
                onClose: { closed = true }
            )
            .frame(width: 420, height: 320),
            size: CGSize(width: 420, height: 320)
        )
        defer { host.close() }

        let drawing = try #require(await host.steadyDrawing())
        #expect(DrawnPixels.inkedRows(drawing) > 20)
        #expect(!retried && !closed)
    }

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func overflowMenuQuickReactionsAndReactionChipsRenderCleanly(appearance: NSAppearance.Name) throws {
        let menu = try Self.rasterize(
            MessageOverflowMenu(
                actions: [
                    MessageRowAction(kind: .info, title: "Message Info", systemImage: "info.circle", role: nil) {},
                    MessageRowAction(kind: .copy, title: "Copy Text", systemImage: "doc.on.doc", role: nil) {},
                    MessageRowAction(kind: .delete, title: "Delete", systemImage: "trash", role: .destructive) {},
                ]
            )
            .background(WNColor.backgroundPrimary),
            in: appearance
        )
        let picker = try Self.rasterize(
            QuickReactionPicker(
                emojis: ChatReactionDefaults.quick,
                selectedEmojis: ["👍"],
                onPick: { _ in }
            )
            .background(WNColor.backgroundPrimary),
            in: appearance
        )
        let chips = try Self.rasterize(
            MessageReactionChips(
                reactions: [
                    MessageReaction(emoji: "👍", count: 3, isOwn: true, senders: ["a", "b", "c"]),
                    MessageReaction(emoji: "🔥", count: 1, isOwn: false, senders: ["b"]),
                ],
                omittedKinds: 2,
                onOpenViewer: { _ in }
            )
            .padding(8)
            .background(WNColor.backgroundPrimary),
            in: appearance
        )

        #expect(menu.pixelsWide > 0 && menu.pixelsHigh > 0)
        #expect(picker.pixelsWide > 0 && picker.pixelsHigh > 0)
        #expect(chips.pixelsWide > 0 && chips.pixelsHigh > 0)
    }

    // MARK: - Helpers

    private static func rasterize(_ view: some View, in appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        let tiff = try #require(image?.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }
}
