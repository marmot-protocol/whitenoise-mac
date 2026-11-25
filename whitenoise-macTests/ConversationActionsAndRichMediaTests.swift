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
import Vision

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
        #expect(pdfIcon.size.width > 0)
    }

    // MARK: - Poll option confirmation & closed-poll finality (T10, #1113)

    @Test func pollOptionVisualStateDistinguishesConfirmedPendingAndClosedStates() {
        let confirmed: Set<String> = ["0"]

        // No pending vote: confirmed option is selected, others are not, nothing is pending.
        #expect(
            PollOptionVisualState.resolve(
                optionID: "0", confirmedSelection: confirmed, pendingSelection: nil, isOpen: true
            ) == PollOptionVisualState(isConfirmedSelection: true, isPendingChange: false)
        )
        #expect(
            PollOptionVisualState.resolve(
                optionID: "1", confirmedSelection: confirmed, pendingSelection: nil, isOpen: true
            ) == PollOptionVisualState(isConfirmedSelection: false, isPendingChange: false)
        )

        // Single-choice switch from 0 -> 1 in flight: 0 stays confirmed-selected while pending
        // removal, 1 is NOT confirmed-selected yet and is pending addition.
        #expect(
            PollOptionVisualState.resolve(
                optionID: "0", confirmedSelection: confirmed, pendingSelection: ["1"], isOpen: true
            ) == PollOptionVisualState(isConfirmedSelection: true, isPendingChange: true)
        )
        #expect(
            PollOptionVisualState.resolve(
                optionID: "1", confirmedSelection: confirmed, pendingSelection: ["1"], isOpen: true
            ) == PollOptionVisualState(isConfirmedSelection: false, isPendingChange: true)
        )

        // Multi-choice adding 1 while keeping 0: 0 is confirmed and untouched, 1 is pending add.
        #expect(
            PollOptionVisualState.resolve(
                optionID: "0", confirmedSelection: confirmed, pendingSelection: ["0", "1"], isOpen: true
            ) == PollOptionVisualState(isConfirmedSelection: true, isPendingChange: false)
        )
        #expect(
            PollOptionVisualState.resolve(
                optionID: "1", confirmedSelection: confirmed, pendingSelection: ["0", "1"], isOpen: true
            ) == PollOptionVisualState(isConfirmedSelection: false, isPendingChange: true)
        )

        // Removing confirmed option 0 in flight: 0 stays confirmed until MDK settles, marked pending.
        #expect(
            PollOptionVisualState.resolve(
                optionID: "0", confirmedSelection: confirmed, pendingSelection: [], isOpen: true
            ) == PollOptionVisualState(isConfirmedSelection: true, isPendingChange: true)
        )

        // Closed poll with a vote still in flight: pending markers vanish and only MDK's confirmed
        // selection remains selected.
        #expect(
            PollOptionVisualState.resolve(
                optionID: "0", confirmedSelection: confirmed, pendingSelection: ["1"], isOpen: false
            ) == PollOptionVisualState(isConfirmedSelection: true, isPendingChange: false)
        )
        #expect(
            PollOptionVisualState.resolve(
                optionID: "1", confirmedSelection: confirmed, pendingSelection: ["1"], isOpen: false
            ) == PollOptionVisualState(isConfirmedSelection: false, isPendingChange: false)
        )
    }

    @Test func closedPollWithInFlightVoteDrawsConfirmedFinalResultsWithoutAllowingVotes() async throws {
        // MDK's confirmed tally: 1 participant voted for "Yes" (option 0), 0 for "No" (option 1).
        let closedPoll = MessagePoll(
            question: "Ship tonight?",
            options: [
                .init(id: "0", label: "Yes", votes: 1),
                .init(id: "1", label: "No", votes: 0),
            ],
            kind: .singleChoice,
            participants: 1,
            localSelection: ["0"],
            endsAt: 1,
            isOpen: false
        )
        var votedOptions: [String] = []
        let size = CGSize(width: 340, height: 220)
        let host = HostedViewWindow(
            PollMessageCard(
                poll: closedPoll,
                isOutgoing: false,
                timeLabel: "10:00",
                // A local vote for option 1 was still in flight when the poll closed.
                pendingSelection: ["1"],
                onVote: { votedOptions.append($0) },
                onViewVotes: nil
            )
            .padding(12),
            size: size
        )
        defer { host.close() }

        let drawn = try #require(await host.steadyDrawing())
        #expect(
            DrawnText.contains("Final results", in: drawn),
            "read: \(DrawnText.recognized(in: drawn))"
        )
        #expect(
            DrawnText.contains("1 vote", in: drawn),
            "read: \(DrawnText.recognized(in: drawn))"
        )

        // Clicking an option row on a closed poll must not fire `onVote`.
        host.click(at: CGPoint(x: size.width / 2, y: 120))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(votedOptions.isEmpty)
    }

    // MARK: - Action grouping (K02, K03, #1104)

    @Test func messageRowActionGroupingSeparatesStandardAndDestructiveWhilePreservingOrder() {
        let actions: [MessageRowAction] = [
            MessageRowAction(kind: .info, title: "Message Info", systemImage: "info.circle", role: nil) {},
            MessageRowAction(kind: .delete, title: "Delete", systemImage: "trash", role: .destructive) {},
            MessageRowAction(kind: .copy, title: "Copy Text", systemImage: "doc.on.doc", role: nil) {},
            MessageRowAction(kind: .report, title: "Report", systemImage: "flag", role: .destructive) {},
            MessageRowAction(kind: .forward, title: "Forward", systemImage: "arrowshape.turn.up.right", role: nil) {},
        ]

        let grouped = MessageRowActionGrouping.split(actions)
        #expect(grouped.standard.map(\.kind) == [.info, .copy, .forward])
        #expect(grouped.destructive.map(\.kind) == [.delete, .report])
    }

    // MARK: - Task sheet behaviors (P01, C05, E03, #1104)

    @Test func forwardSheetCancelRemainsActiveDuringAttachmentPreparation() async throws {
        let gate = AsyncFfiGate()
        gate.isEnabled = true
        let attachment = MessageMediaAttachment(
            id: "m1#0",
            reference: mediaAttachmentReference(
                sourceEpoch: 1,
                mediaType: "application/pdf",
                fileName: "file.pdf",
                ciphertextSha256: String(repeating: "1", count: 64),
                plaintextSha256: String(repeating: "2", count: 64)
            )
        )
        let message = MessageItem(
            id: "m1",
            senderName: "Alice",
            body: "Check this doc",
            sentAt: Date(timeIntervalSince1970: 1_760_000_000),
            isOutgoing: false,
            mediaAttachments: [attachment]
        )
        let targetChat = try #require(ChatItem.samples.first)
        var sendCount = 0
        let model = MessageForwardViewModel(
            messages: [message],
            dependencies: MessageForwardDependencies(
                fetchAttachment: { _, _ in
                    await gate.passIfArmed()
                    return MessageMediaDownload(
                        data: Data("pdf-bytes".utf8),
                        fileName: "file.pdf",
                        mediaType: "application/pdf",
                        sizeBytes: 9
                    )
                },
                sendText: { _, _ in sendCount += 1 },
                sendMedia: { _, _ in sendCount += 1 },
                reportError: { _ in },
                finish: {}
            )
        )
        var closed = false
        let size = CGSize(width: 420, height: 520)
        // Mirror production (`MessengerShellView`): `onClose` only clears presentation state;
        // `MessageForwardSheet` itself must cancel `model` synchronously before closing.
        let host = HostedViewWindow(
            MessageForwardSheet(
                model: model,
                chats: [targetChat],
                onClose: { closed = true }
            ),
            size: size
        )
        defer {
            gate.release()
            host.close()
        }

        // Start preparing an attachment forward, then cancel via Escape (.cancelAction) while
        // preparation is still paused.
        model.forward(to: targetChat)
        await gate.waitUntilReached()
        #expect(model.phase == MessageForwardViewModel.Phase.preparing(chatId: targetChat.id))
        #expect(!model.isSending)

        let escapeEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: host.window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        #expect(host.window.performKeyEquivalent(with: escapeEvent))
        #expect(await host.settle { closed })

        // Even after the paused fetch resumes with real attachment bytes, the cancelled task must
        // never transition into sending or deliver any message.
        gate.release()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(sendCount == 0)
    }

    @Test func forwardSheetDisablesCancelWhileSending() async throws {
        let sendGate = AsyncFfiGate()
        sendGate.isEnabled = true
        let message = MessageItem(
            id: "m-text",
            senderName: "Alice",
            body: "Hello",
            sentAt: Date(timeIntervalSince1970: 1_760_000_000),
            isOutgoing: false
        )
        let targetChat = try #require(ChatItem.samples.first)
        let model = MessageForwardViewModel(
            messages: [message],
            dependencies: MessageForwardDependencies(
                fetchAttachment: { _, _ in nil },
                sendText: { _, _ in await sendGate.passIfArmed() },
                sendMedia: { _, _ in },
                reportError: { _ in },
                finish: {}
            )
        )
        var closed = false
        let host = HostedViewWindow(
            MessageForwardSheet(model: model, chats: [targetChat], onClose: { closed = true }),
            size: CGSize(width: 420, height: 520)
        )
        defer {
            sendGate.release()
            host.close()
        }

        model.forward(to: targetChat)
        await sendGate.waitUntilReached()
        #expect(model.isSending)

        let escapeEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: host.window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        _ = host.window.performKeyEquivalent(with: escapeEvent)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!closed)
        sendGate.release()
    }

    @Test func reportSheetReturnDoesNotAccidentallySubmitReport() async throws {
        var submitted = false
        let model = ReportMessageViewModel(
            eligibility: MessageModerationEligibility(
                reportsToGroup: true,
                reportsToTeam: true,
                canBlockAuthor: false,
                authorAccountIdHex: String(repeating: "a", count: 64)
            ),
            dependencies: ReportMessageDependencies(
                reportToGroup: { _, _ in
                    submitted = true
                    return .published
                },
                reportToTeam: { _, _ in
                    submitted = true
                    return .published
                },
                present: { _ in }
            )
        )
        model.explanation = "Line 1"
        let size = CGSize(width: 480, height: 420)
        let host = HostedViewWindow(
            ReportMessageSheet(model: model, dismiss: {}),
            size: size
        )
        defer { host.close() }

        _ = try #require(await host.steadyDrawing())

        // Focus the multiline explanation field and dispatch Return through normal key handling:
        // it must never submit the report and must keep/extend the typed explanation.
        let textField = try #require(host.window.contentView.flatMap { Self.firstEditableTextField(in: $0) })
        #expect(host.window.makeFirstResponder(textField))
        let editor = try #require(textField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        let returnEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: host.window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        if !host.window.performKeyEquivalent(with: returnEvent) {
            host.window.sendEvent(returnEvent)
        }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.explanation.hasPrefix("Line 1"))
        #expect(!submitted)
    }

    @Test func editHistorySheetInvokesRetryAndDoneCallbacks() async throws {
        var retried = false
        var closed = false
        let size = CGSize(width: 420, height: 360)
        let host = HostedViewWindow(
            MessageEditHistoryContentView(
                versions: [],
                isLoading: false,
                errorMessage: "Temporary storage error",
                hasMore: false,
                onLoadMore: { retried = true },
                onClose: { closed = true }
            ),
            size: size
        )
        defer { host.close() }

        let drawn = try #require(await host.steadyDrawing())
        #expect(
            DrawnText.contains("Temporary storage error", in: drawn),
            "read: \(DrawnText.recognized(in: drawn))"
        )

        // Activate Retry via a real click on the rendered button and Done via Escape (.cancelAction).
        let retryPoint = try #require(Self.centerOfText(L10n.string("Retry"), in: drawn, viewSize: size))
        host.click(at: retryPoint)
        #expect(await host.settle { retried })

        let escapeEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: host.window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        #expect(host.window.performKeyEquivalent(with: escapeEvent))
        #expect(await host.settle { closed })
    }

    private static func centerOfText(
        _ phrase: String, in rep: NSBitmapImageRep, viewSize: CGSize
    ) -> CGPoint? {
        guard let image = rep.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let target = phrase.lowercased()
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string.lowercased(),
                text.contains(target)
            else { continue }
            let box = observation.boundingBox
            return CGPoint(x: box.midX * viewSize.width, y: (1 - box.midY) * viewSize.height)
        }
        return nil
    }

    private static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.isEditable {
            return textField
        }
        for subview in view.subviews {
            if let found = firstEditableTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}
