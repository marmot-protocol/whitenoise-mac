import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Focused behavioral and rendering checks for the native macOS composer, voice/dictation, and
/// picker refresh (#1102, #1103, #1118).
///
/// `.serialized` and `@MainActor` because hosting and rasterization drive AppKit views and switch
/// `NSAppearance`.
@Suite(.serialized) @MainActor struct ComposerVoicePickerRefreshTests {
    // MARK: - Composer typography & mentions (#1102)

    @Test func composerTextViewUsesNativeBodyTypographyAndBoldMentions() throws {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let typingFont = ComposerMessageTextViewRepresentable.typingFont
        let mentionFont = ComposerMessageTextViewRepresentable.mentionFont

        #expect(typingFont == bodyFont)
        #expect(mentionFont.pointSize == typingFont.pointSize)
        #expect(
            NSFontManager.shared.weight(of: mentionFont) > NSFontManager.shared.weight(of: typingFont),
            "mention tokens must remain heavier than plain body typing"
        )

        let plainColor = ComposerMessageTextViewRepresentable.plainTypingAttributes[.foregroundColor] as? NSColor
        #expect(plainColor == WNNSColor.textPrimary)
    }

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func composerContextAndStagedDraftViewsRenderInBothAppearances(appearance: NSAppearance.Name) throws {
        let reply = ReplyComposerContextView(
            context: MessageReplyContext(targetMessageId: "m1", senderName: "Alice", body: "Hello there"),
            cancel: {}
        )
        .frame(width: 440)
        let edit = EditComposerContextView(
            context: MessageEditContext(
                targetMessageId: "m2",
                senderName: "You",
                originalBody: "Original text",
                preservedDraft: "",
                preservedMentionSelections: [],
                preservedReplyContext: nil,
                preservedMediaAttachments: [],
                preservedMediaUploadStates: [:]
            )
        )
        .frame(width: 440)
        let file = PendingMediaAttachment(
            id: UUID(),
            fileName: "report.pdf",
            mediaType: "application/pdf",
            data: Data(repeating: 1, count: 1024),
            dim: nil
        )
        let strip = PendingMediaDraftStrip(
            attachments: [file],
            uploadStates: [file.id: .failed],
            isSending: false,
            onRemove: { _ in },
            onRetryUpload: { _ in },
            rejections: [
                ComposerAttachmentRejections.Item(
                    id: UUID(),
                    rejection: AttachmentRejection(source: .file(name: "bad.exe"), reason: .unsupportedType)
                )
            ]
        )
        .frame(width: 440)

        for view in [AnyView(reply), AnyView(edit), AnyView(strip)] {
            let rep = try Self.rasterize(view, in: appearance)
            #expect(rep.pixelsWide > 0)
            #expect(rep.pixelsHigh > 0)
        }
    }

    @Test func replyContextCancelButtonInvokesCancelCallback() async throws {
        var didCancel = false
        let size = CGSize(width: 420, height: 64)
        let host = HostedViewWindow(
            ReplyComposerContextView(
                context: MessageReplyContext(targetMessageId: "m1", senderName: "Alice", body: "Quoted message"),
                cancel: { didCancel = true }
            )
            .frame(width: size.width),
            size: size
        )
        defer { host.close() }

        // Trailing cancel button sits inside 8pt trailing padding with a 24pt hit target.
        host.click(at: CGPoint(x: size.width - 8 - 12, y: size.height / 2))
        #expect(await host.settle { didCancel })
    }

    // MARK: - Voice recording and dictation (#1103)

    @Test func voiceRecordingBarDrawsAndStopsWhenClicked() async throws {
        var didStop = false
        let size = CGSize(width: 440, height: 56)
        let host = HostedViewWindow(
            VoiceRecordingComposerView(
                samples: [0.3, 0.7, 0.5, 0.9, 0.4],
                durationSeconds: 5.0,
                onStop: { didStop = true }
            )
            .frame(width: size.width),
            size: size
        )
        defer { host.close() }

        let drawn = try #require(await host.steadyDrawing())
        #expect(DrawnText.contains("0:05", in: drawn), "read: \(DrawnText.recognized(in: drawn))")

        // Trailing Stop button inside 10pt trailing padding.
        host.click(at: CGPoint(x: size.width - 10 - 16, y: size.height / 2))
        #expect(await host.settle { didStop })
    }

    @Test func voiceMessageDraftRendersReadyUploadingAndFailedStates() throws {
        let attachment = PendingMediaAttachment(
            id: UUID(),
            fileName: "voice.m4a",
            mediaType: "audio/mp4",
            data: Data(repeating: 0, count: 512),
            dim: nil,
            durationSeconds: 12.0,
            waveformSamples: [0.2, 0.6, 0.9, 0.4, 0.7],
            isVoiceMessage: true
        )

        let states: [PendingMediaUploadState?] = [nil, .uploading, .failed]
        for state in states {
            let rep = try Self.rasterize(
                VoiceMessageDraftComposerView(
                    attachment: attachment,
                    uploadState: state,
                    isSending: false,
                    canSend: true,
                    sendHelp: L10n.string("Send"),
                    onDiscard: {},
                    onRetryUpload: {},
                    onSend: {}
                )
                .frame(width: 480),
                in: .aqua
            )
            #expect(rep.pixelsWide > 0)
            #expect(rep.pixelsHigh > 0)
        }
    }

    @Test func dictationComposerDistinguishesStartingListeningAndFinishingStates() async throws {
        let size = CGSize(width: 480, height: 64)

        let startingHost = HostedViewWindow(
            DictationComposerView(
                state: .starting,
                transcript: DictationTranscript(),
                claimsReturnAndEscape: false,
                onCancel: {},
                onFinish: {}
            )
            .frame(width: size.width),
            size: size
        )
        defer { startingHost.close() }
        let startingShot = try #require(await startingHost.steadyDrawing())
        #expect(
            DrawnText.contains(L10n.string("Getting dictation ready"), in: startingShot),
            "read: \(DrawnText.recognized(in: startingShot))"
        )

        var didFinish = false
        let listeningHost = HostedViewWindow(
            DictationComposerView(
                state: .listening,
                transcript: DictationTranscript(finalized: "Hello ", volatile: "world"),
                claimsReturnAndEscape: false,
                onCancel: {},
                onFinish: { didFinish = true }
            )
            .frame(width: size.width),
            size: size
        )
        defer { listeningHost.close() }
        let listeningShot = try #require(await listeningHost.steadyDrawing())
        #expect(
            DrawnText.contains("Hello world", in: listeningShot),
            "read: \(DrawnText.recognized(in: listeningShot))"
        )

        // Trailing Finish button inside 10pt trailing padding.
        listeningHost.click(at: CGPoint(x: size.width - 10 - 16, y: size.height / 2))
        #expect(await listeningHost.settle { didFinish })
    }

    // MARK: - Pickers and poll composer (#1118)

    @Test func giphySearchViewDisplaysDisclosureAndPoweredByAttribution() async throws {
        let model = GiphySearchViewModel(search: { _ in [] }, send: { _ in })
        let size = CGSize(width: 400, height: 460)
        let host = HostedViewWindow(GiphySearchView(model: model, onDismiss: {}), size: size)
        defer { host.close() }

        let drawn = try #require(await host.steadyDrawing())
        #expect(
            DrawnText.contains("Your search and IP address are sent to GIPHY", in: drawn),
            "read: \(DrawnText.recognized(in: drawn))"
        )
        #expect(
            DrawnText.contains("Powered by", in: drawn),
            "read: \(DrawnText.recognized(in: drawn))"
        )
    }

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func pollComposerSheetDrawsWithGroupedFormInBothAppearances(appearance: NSAppearance.Name) throws {
        let rep = try Self.rasterize(
            PollComposerSheet(onSend: { _ in }, onCancel: {}).background(WNColor.backgroundPrimary),
            in: appearance
        )
        #expect(rep.pixelsWide > 400)
        #expect(rep.pixelsHigh > 300)
    }

    // MARK: - Helpers

    private static func rasterize(_ view: some View, in appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(
            content:
                view
                .background(WNColor.backgroundPrimary)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        let tiff = try #require(image?.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }
}
