import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Focused behavioral and interaction checks for the native macOS composer, voice/dictation, and
/// picker refresh (#1102, #1103, #1118).
///
/// `.serialized` and `@MainActor` because hosting drives AppKit windows and key equivalents.
@Suite(.serialized) @MainActor struct ComposerVoicePickerRefreshTests {
    // MARK: - Composer typography & mentions (#1102)

    @Test func composerTextViewUsesNativeBodyTypographyAndBoldMentions() {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body, options: [:])
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

        var finishingDidCancel = false
        var finishingDidFinish = false
        let finishingHost = HostedViewWindow(
            DictationComposerView(
                state: .finishing,
                transcript: DictationTranscript(finalized: "Hello world", volatile: ""),
                claimsReturnAndEscape: false,
                onCancel: { finishingDidCancel = true },
                onFinish: { finishingDidFinish = true }
            )
            .frame(width: size.width),
            size: size
        )
        defer { finishingHost.close() }
        let finishingShot = try #require(await finishingHost.steadyDrawing())
        #expect(
            DrawnText.contains("Hello world", in: finishingShot),
            "read: \(DrawnText.recognized(in: finishingShot))"
        )

        // While finishing, Finish is disabled and cannot fire, while Cancel remains clickable.
        finishingHost.click(at: CGPoint(x: size.width - 10 - 16, y: size.height / 2))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!finishingDidFinish)

        // Cancel sits immediately to the left of Finish (trailing 10pt + 32pt Finish + 10pt spacing + 16pt center).
        finishingHost.click(at: CGPoint(x: size.width - 10 - 32 - 10 - 16, y: size.height / 2))
        #expect(await finishingHost.settle { finishingDidCancel })
    }

    // MARK: - Pickers and poll composer (#1118)

    @Test func emojiPickerModelTracksCompletedQueryToAvoidPrematureEmptyState() async {
        let model = ChatEmojiPickerModel()
        #expect(model.completedQuery.isEmpty)

        await model.load()
        await model.search(query: "  fire  ")
        #expect(model.completedQuery == "fire")

        await model.search(query: "   ")
        #expect(model.completedQuery.isEmpty)
        #expect(model.searchResults.isEmpty)
    }

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

    /// Pressing Escape clears a non-empty GIPHY query first even when focus is not in the search
    /// field, and only dismisses once the query is empty (C13).
    @Test func giphyEscapeClearsQueryFirstEvenWithoutSearchFieldFocusThenDismisses() async throws {
        var didDismiss = false
        let model = GiphySearchViewModel(search: { _ in [] }, send: { _ in })
        model.query = "marmot"

        let size = CGSize(width: 400, height: 460)
        let host = HostedViewWindow(
            GiphySearchView(model: model, onDismiss: { didDismiss = true }),
            size: size
        )
        defer { host.close() }

        // Move first responder away from the text field onto the window content view.
        host.window.makeFirstResponder(host.window.contentView)
        _ = await host.settle(timeout: .milliseconds(100)) { false }

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
        #expect(await host.settle { model.query.isEmpty })
        #expect(!didDismiss)

        #expect(host.window.performKeyEquivalent(with: escapeEvent))
        #expect(await host.settle { didDismiss })
    }

    /// Submitting an invalid poll displays the validation explanation visibly above the Send
    /// footer even when the form sections could scroll away.
    @Test func pollComposerInvalidSendShowsVisibleValidationMessageAboveFooter() async throws {
        var didSend = false
        let size = CGSize(width: 440, height: 460)
        let host = HostedViewWindow(
            PollComposerSheet(onSend: { _ in didSend = true }, onCancel: {}),
            size: size
        )
        defer { host.close() }

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

        _ = host.window.performKeyEquivalent(with: returnEvent)
        let drawn = try #require(await host.steadyDrawing())
        #expect(!didSend)
        #expect(
            DrawnText.contains(L10n.string("Enter a question."), in: drawn),
            "read: \(DrawnText.recognized(in: drawn))"
        )
    }
}
