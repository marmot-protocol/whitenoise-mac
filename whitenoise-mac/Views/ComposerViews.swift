//
//  ComposerViews.swift
//  whitenoise-mac
//
//  Composition surface: the conversation header, pending-media draft strip
//  and thumbnail decoding, voice-recording composer and audio waveform,
//  timeline loading rows, reply context, the new-chat column/form/recipient
//  card, and the profile-image avatar. Extracted verbatim from
//  MessengerShellView.swift (no behavior change).
//

import AVFoundation
import AppKit
import ImageIO
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerEmojiInsertion: Equatable {
    let id = UUID()
    let emoji: String
}

/// Lets a transcript control (Reply, Edit) hand keyboard focus to the composer. One per
/// conversation, held in `ConversationView` state and passed down through the environment:
/// rows only call `request()` and never read `requestID`, so a request re-renders the composer
/// alone, not the transcript.
///
/// A request stays pending until the text view actually takes focus and consumes it. Retiring it
/// here rather than in the text view's coordinator is what stops a composer rebuilt later in the
/// same chat (after selection mode, a voice recording, …) from mistaking an old request for a
/// new one.
@Observable
final class ComposerFocusRequester {
    private(set) var requestID: UUID?

    func request() {
        requestID = UUID()
    }

    /// Retires `id` if it is still the pending request; a newer request is left alone.
    func consume(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
    }
}

private struct ComposerFocusRequesterKey: EnvironmentKey {
    static let defaultValue = ComposerFocusRequester()
}

extension EnvironmentValues {
    var composerFocusRequester: ComposerFocusRequester {
        get { self[ComposerFocusRequesterKey.self] }
        set { self[ComposerFocusRequesterKey.self] = newValue }
    }
}

/// An open "@query" left of the caret, published by the text view so the shell can show the
/// mention picker. `tokenRange` is the "@…caret" span to replace when a candidate is chosen.
struct ComposerMentionContext: Equatable {
    let query: String
    let tokenRange: NSRange
}

/// A key the text view hands the mention picker while an "@query" is open: Tab or Return takes
/// the highlighted candidate, and the arrows move the highlight.
nonisolated enum ComposerMentionCommand: Equatable {
    case accept
    case moveUp
    case moveDown

    /// Where the highlight lands after this key among `count` rows. The arrows stop at either
    /// end rather than wrapping.
    func movingHighlight(_ index: Int, among count: Int) -> Int {
        switch self {
        case .accept: index
        case .moveUp: max(index - 1, 0)
        case .moveDown: min(index + 1, count - 1)
        }
    }
}

/// A caret-preserving mention insertion the text view applies on the next update, mirroring
/// `ComposerEmojiInsertion` but replacing the "@query" token rather than the current selection.
struct ComposerMentionInsertion: Equatable {
    let id = UUID()
    let scope: WorkspaceState.ComposerDraftKey
    let range: NSRange
    let expectedText: String
    let displayText: String
    let npub: String

    init(
        scope: WorkspaceState.ComposerDraftKey,
        context: ComposerMentionContext,
        candidate: ComposerMentionCandidate
    ) {
        self.scope = scope
        range = context.tokenRange
        expectedText = "@\(context.query)"
        displayText = "@\(candidate.displayName)"
        npub = candidate.npub
    }

    var replacement: String { "\(displayText) " }
}

struct ComposerMessageInputView: View {
    @Binding var text: String
    let placeholder: String
    let emojiInsertion: ComposerEmojiInsertion?
    let onEmojiInsertionConsumed: (UUID) -> Void
    let mentionInsertion: ComposerMentionInsertion?
    let onMentionInsertionConsumed: (UUID) -> Void
    @Binding var mentionSelections: [ComposerMentionSelection]
    let mentionContextScope: WorkspaceState.ComposerDraftKey?
    let onMentionContextChange: (ComposerMentionContext?) -> Void
    /// Applies a picker key to the open "@query". Returns whether it was handled, so Tab, Return
    /// and the arrows keep their ordinary meaning when there is nothing to complete.
    let onMentionCommand: (ComposerMentionCommand) -> Bool
    /// Applies Up in an empty composer or Escape to message editing. Returns whether it was
    /// handled, so the key keeps its ordinary meaning when there is nothing to edit or cancel.
    var onEditCommand: (ComposerEditCommand) -> Bool = { _ in false }
    let onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
    let onSend: () -> Void
    var focusRequestID: UUID?
    var onFocusRequestConsumed: (UUID) -> Void = { _ in }

    @State private var measuredHeight = ComposerMessageInputMetrics.minHeight

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComposerMessageTextViewRepresentable(
                text: $text,
                measuredHeight: $measuredHeight,
                emojiInsertion: emojiInsertion,
                onEmojiInsertionConsumed: onEmojiInsertionConsumed,
                mentionInsertion: mentionInsertion,
                onMentionInsertionConsumed: onMentionInsertionConsumed,
                mentionSelections: $mentionSelections,
                mentionContextScope: mentionContextScope,
                onMentionContextChange: onMentionContextChange,
                onMentionCommand: onMentionCommand,
                onEditCommand: onEditCommand,
                onPasteMedia: onPasteMedia,
                onSend: onSend,
                focusRequestID: focusRequestID,
                onFocusRequestConsumed: onFocusRequestConsumed
            )
            .frame(height: measuredHeight)

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: ComposerMessageInputMetrics.minHeight)
    }
}

#Preview("Message input") {
    @Previewable @State var text = ""
    @Previewable @State var mentions: [ComposerMentionSelection] = []
    ComposerMessageInputView(
        text: $text,
        placeholder: L10n.string("Message"),
        emojiInsertion: nil,
        onEmojiInsertionConsumed: { _ in },
        mentionInsertion: nil,
        onMentionInsertionConsumed: { _ in },
        mentionSelections: $mentions,
        mentionContextScope: nil,
        onMentionContextChange: { _ in },
        onMentionCommand: { _ in false },
        onPasteMedia: { _ in },
        onSend: {}
    )
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background { MessagesComposerFieldBackground() }
    .frame(width: 420)
    .padding()
}

private enum ComposerMessageInputMetrics {
    static let minHeight: CGFloat = 20
    static let maxHeight: CGFloat = 96
}

/// Autocomplete list of mentionable group members, shown above the composer while an "@query"
/// is open. One row is always highlighted — the top one to begin with; Up, Down and the pointer
/// move it. Click a row, or press Tab or Return to take the highlighted one; the caret stays in
/// the text field.
struct ComposerMentionPicker: View {
    let candidates: [ComposerMentionCandidate]
    let highlightedIndex: Int
    let onHighlight: (Int) -> Void
    let onSelect: (ComposerMentionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                ComposerMentionRow(
                    candidate: candidate,
                    isHighlighted: index == highlightedIndex,
                    onHover: { onHighlight(index) },
                    onSelect: { onSelect(candidate) }
                )
                if candidate.id != candidates.last?.id {
                    // Hidden, not removed, beside the highlighted row so the rows do not shift as
                    // the highlight moves: a hairline against the inverted fill only adds noise.
                    Divider()
                        .padding(.leading, 44)
                        .opacity(index == highlightedIndex || index + 1 == highlightedIndex ? 0 : 1)
                }
            }
        }
        .padding(.vertical, 4)
        .wnFloatingGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("composer.mentionPicker")
    }
}

private struct ComposerMentionRow: View {
    let candidate: ComposerMentionCandidate
    let isHighlighted: Bool
    let onHover: () -> Void
    let onSelect: () -> Void

    private var shortNpub: String? {
        candidate.npub.isEmpty ? nil : DisplayText.short(candidate.npub)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ProfileImageAvatarView(
                    seed: candidate.accountIdHex,
                    initials: candidate.displayName,
                    sanitizedPictureURL: candidate.sanitizedPictureURL,
                    localImagePayload: candidate.imagePayload,
                    size: 26,
                    isSelected: false
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isHighlighted ? WNColor.fillContentPrimary : WNColor.textPrimary)
                        .lineLimit(1)
                    // Under a private nickname, who the person actually publishes as says more
                    // about which of two similarly-nicknamed contacts this is than their npub.
                    if let subtitle = candidate.publishedDisplayName ?? shortNpub {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(
                                isHighlighted
                                    ? WNColor.fillContentPrimary.opacity(0.75)
                                    : Color(nsColor: .secondaryLabelColor)
                            )
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                // Inverted, the way a menu marks its highlighted item: Tab and Return act on this
                // row, so it has to read at a glance. The sidebar's selected-row wash
                // (`fillTertiaryHover`) is one neutral step off the surface and all but vanishes
                // over the picker's translucent material.
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(WNColor.fillPrimary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

#Preview("Mention picker") {
    @Previewable @State var highlightedIndex = 0
    let candidates = ["Alice", "Bob", "Carol"].enumerated().map { index, name in
        ComposerMentionCandidate(
            details: GroupMemberDetailsFfi(
                memberIdHex: String(repeating: "\(index + 1)", count: 64),
                account: nil,
                local: false,
                isAdmin: false,
                isSelf: false,
                npub: "npub1\(name.lowercased())",
                displayName: name
            )
        )
    }
    ComposerMentionPicker(
        candidates: candidates,
        highlightedIndex: highlightedIndex,
        onHighlight: { highlightedIndex = $0 },
        onSelect: { _ in }
    )
    .frame(width: 280)
    .padding()
}

nonisolated enum ComposerReturnKeyAction: Equatable {
    case send
    case insertLineBreak
    case deferToSystem
}

nonisolated enum ComposerKeyboardShortcutPolicy {
    static func returnKeyAction(for modifierFlags: NSEvent.ModifierFlags) -> ComposerReturnKeyAction {
        let meaningfulFlags =
            modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.shift, .control, .option, .command])
        if meaningfulFlags.isEmpty {
            return .send
        }
        if meaningfulFlags == .shift {
            return .insertLineBreak
        }
        return .deferToSystem
    }
}

struct ComposerMessageTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let emojiInsertion: ComposerEmojiInsertion?
    let onEmojiInsertionConsumed: (UUID) -> Void
    let mentionInsertion: ComposerMentionInsertion?
    let onMentionInsertionConsumed: (UUID) -> Void
    @Binding var mentionSelections: [ComposerMentionSelection]
    let mentionContextScope: WorkspaceState.ComposerDraftKey?
    let onMentionContextChange: (ComposerMentionContext?) -> Void
    /// Applies a picker key to the open "@query". Returns whether it was handled, so Tab, Return
    /// and the arrows keep their ordinary meaning when there is nothing to complete.
    let onMentionCommand: (ComposerMentionCommand) -> Bool
    var onEditCommand: (ComposerEditCommand) -> Bool = { _ in false }
    let onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
    let onSend: () -> Void
    /// A pending request moves keyboard focus into the text view, caret at the end of the draft,
    /// then is reported through `onFocusRequestConsumed` so the owner can retire it.
    var focusRequestID: UUID?
    var onFocusRequestConsumed: (UUID) -> Void = { _ in }

    /// Native macOS semantic body font shared by displayed text, placeholder, and height
    /// measurement (F04, T08).
    static var typingFont: NSFont {
        NSFont.preferredFont(forTextStyle: .body, options: [:])
    }

    /// Bold face at the typing font's own size, so a mention token and the words around it stay
    /// on one baseline and one measure.
    static var mentionFont: NSFont {
        NSFont.systemFont(ofSize: typingFont.pointSize, weight: .bold)
    }

    /// Attributes typed text should carry when it is not part of a mention token. Reapplied after a
    /// mention is inserted so the token's chip and identity markers cannot bleed into what follows.
    static var plainTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.typingFont,
            .foregroundColor: WNNSColor.textPrimary,
        ]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            measuredHeight: $measuredHeight,
            mentionSelections: $mentionSelections,
            mentionContextScope: mentionContextScope,
            onPasteMedia: onPasteMedia,
            onSend: onSend,
            onMentionContextChange: onMentionContextChange,
            onMentionCommand: onMentionCommand,
            onEditCommand: onEditCommand
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerPasteInterceptingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.typingFont
        textView.textColor = WNNSColor.textPrimary
        textView.insertionPointColor = WNNSColor.textPrimary
        // Plain text is the baseline; only a mention marker adds attributes on top of it.
        textView.typingAttributes = Self.plainTypingAttributes
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: ComposerMessageInputMetrics.minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        configureHandlers(for: textView, coordinator: context.coordinator)

        scrollView.documentView = textView
        DispatchQueue.main.async {
            context.coordinator.updateMeasuredHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.measuredHeight = $measuredHeight
        context.coordinator.onPasteMedia = onPasteMedia
        context.coordinator.onSend = onSend
        context.coordinator.onEmojiInsertionConsumed = onEmojiInsertionConsumed
        context.coordinator.onFocusRequestConsumed = onFocusRequestConsumed
        context.coordinator.onMentionInsertionConsumed = onMentionInsertionConsumed
        context.coordinator.mentionSelections = $mentionSelections
        context.coordinator.onMentionContextChange = onMentionContextChange
        context.coordinator.onMentionCommand = onMentionCommand
        context.coordinator.onEditCommand = onEditCommand

        guard let textView = scrollView.documentView as? ComposerPasteInterceptingTextView else { return }
        configureHandlers(for: textView, coordinator: context.coordinator)
        // No `textView.font =` here: the setter re-fonts the whole storage, which strips a draft
        // mention's bold on every SwiftUI update. `makeNSView` sets the typing font once.
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.scheduleMentionSynchronization(
            scope: mentionContextScope,
            insertion: mentionInsertion,
            in: textView
        )
        context.coordinator.scheduleEmojiInsertion(emojiInsertion, into: textView)
        context.coordinator.scheduleFocus(focusRequestID, in: textView)
        DispatchQueue.main.async {
            context.coordinator.updateMeasuredHeight(for: textView)
        }
    }

    private func configureHandlers(for textView: ComposerPasteInterceptingTextView, coordinator: Coordinator) {
        textView.mediaPasteHandler = { [weak coordinator] in
            coordinator?.handleMediaPaste() ?? false
        }
        textView.returnKeySendHandler = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.handleReturnKeySend(in: textView)
        }
        textView.windowAttachHandler = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.retryPendingFocus(in: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>
        var mentionSelections: Binding<[ComposerMentionSelection]>
        private var mentionContextScope: WorkspaceState.ComposerDraftKey?
        var onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
        var onSend: () -> Void
        var onEmojiInsertionConsumed: (UUID) -> Void
        var onMentionInsertionConsumed: (UUID) -> Void
        var onMentionContextChange: (ComposerMentionContext?) -> Void
        var onMentionCommand: (ComposerMentionCommand) -> Bool
        var onEditCommand: (ComposerEditCommand) -> Bool
        private var lastEmojiInsertionID: UUID?
        /// Dedupes the focus attempt already queued for this update pass; cleared when it runs,
        /// so a request that could not be applied is retried on the next update.
        private var inFlightFocusRequestID: UUID?
        /// The request the last update pass carried, kept so entering a window can retry it.
        private var latestFocusRequestID: UUID?
        var onFocusRequestConsumed: (UUID) -> Void = { _ in }
        private var lastMentionInsertionID: UUID?
        private var lastMentionContext: ComposerMentionContext?
        private var mentionSynchronizationGeneration: UInt64 = 0

        init(
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            mentionSelections: Binding<[ComposerMentionSelection]>,
            mentionContextScope: WorkspaceState.ComposerDraftKey?,
            onPasteMedia: @escaping ([OutgoingMediaPasteboardAttachment]) -> Void,
            onSend: @escaping () -> Void,
            onEmojiInsertionConsumed: @escaping (UUID) -> Void = { _ in },
            onMentionInsertionConsumed: @escaping (UUID) -> Void = { _ in },
            onMentionContextChange: @escaping (ComposerMentionContext?) -> Void = { _ in },
            onMentionCommand: @escaping (ComposerMentionCommand) -> Bool = { _ in false },
            onEditCommand: @escaping (ComposerEditCommand) -> Bool = { _ in false }
        ) {
            self.text = text
            self.measuredHeight = measuredHeight
            self.mentionSelections = mentionSelections
            self.mentionContextScope = mentionContextScope
            self.onPasteMedia = onPasteMedia
            self.onSend = onSend
            self.onEmojiInsertionConsumed = onEmojiInsertionConsumed
            self.onMentionInsertionConsumed = onMentionInsertionConsumed
            self.onMentionContextChange = onMentionContextChange
            self.onMentionCommand = onMentionCommand
            self.onEditCommand = onEditCommand
        }

        func scheduleEmojiInsertion(_ insertion: ComposerEmojiInsertion?, into textView: NSTextView) {
            guard let insertion, insertion.id != lastEmojiInsertionID else { return }
            lastEmojiInsertionID = insertion.id
            DispatchQueue.main.async { [self] in
                let selectedRange = textView.selectedRange()
                textView.insertText(insertion.emoji, replacementRange: selectedRange)
                text.wrappedValue = textView.string
                updateMeasuredHeight(for: textView)
                textView.window?.makeFirstResponder(textView)
                onEmojiInsertionConsumed(insertion.id)
            }
        }

        func scheduleFocus(_ requestID: UUID?, in textView: NSTextView) {
            latestFocusRequestID = requestID
            guard let requestID, requestID != inFlightFocusRequestID else { return }
            inFlightFocusRequestID = requestID
            // Deferred past the update pass: the text view may not be in a window yet when the
            // composer is rebuilt by the same change that asked for focus, and consuming the
            // request writes observable state that must not change during a view update.
            DispatchQueue.main.async { [self] in
                inFlightFocusRequestID = nil
                guard let window = textView.window else { return }
                guard window.isKeyWindow else {
                    if latestFocusRequestID == requestID { latestFocusRequestID = nil }
                    onFocusRequestConsumed(requestID)
                    return
                }
                guard window.makeFirstResponder(textView) else { return }
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                if latestFocusRequestID == requestID { latestFocusRequestID = nil }
                onFocusRequestConsumed(requestID)
            }
        }

        /// A focus attempt that ran before the text view had a window gave up without consuming
        /// its request; nothing else re-runs it unless SwiftUI happens to update the view again.
        func retryPendingFocus(in textView: NSTextView) {
            guard textView.window != nil else { return }
            scheduleFocus(latestFocusRequestID, in: textView)
        }

        func scheduleMentionSynchronization(
            scope: WorkspaceState.ComposerDraftKey?,
            insertion: ComposerMentionInsertion?,
            in textView: NSTextView
        ) {
            mentionSynchronizationGeneration &+= 1
            let generation = mentionSynchronizationGeneration
            DispatchQueue.main.async { [self] in
                guard generation == mentionSynchronizationGeneration else { return }
                synchronizeMentionMarkers(in: textView)
                synchronizeMentionContextScope(scope, in: textView)
                insertMentionIfNeeded(insertion, into: textView)
            }
        }

        func insertMentionIfNeeded(_ insertion: ComposerMentionInsertion?, into textView: NSTextView) {
            guard let insertion, insertion.id != lastMentionInsertionID else { return }
            lastMentionInsertionID = insertion.id
            guard insertion.scope == mentionContextScope else {
                onMentionInsertionConsumed(insertion.id)
                return
            }
            let bounds = NSRange(location: 0, length: (textView.string as NSString).length)
            // The token range was captured on an earlier text snapshot; drop it if the text has
            // since shrunk past it rather than inserting at a stale offset.
            guard NSMaxRange(insertion.range) <= bounds.length else {
                onMentionInsertionConsumed(insertion.id)
                return
            }
            guard (textView.string as NSString).substring(with: insertion.range) == insertion.expectedText else {
                onMentionInsertionConsumed(insertion.id)
                return
            }
            textView.insertText(insertion.replacement, replacementRange: insertion.range)
            let mentionRange = NSRange(
                location: insertion.range.location,
                length: (insertion.displayText as NSString).length
            )
            ComposerMentionMarkerStore.add(
                ComposerMentionSelection(
                    range: mentionRange,
                    displayText: insertion.displayText,
                    npub: insertion.npub
                ),
                to: textView
            )
            // The caret is left just past the token, so pin the attributes the next keystroke
            // continues with: without this, NSTextView carries on with whatever it derived at the
            // insertion point and the first character typed after a mention could pick up the
            // chip and the identity markers with it. (A chip smeared on by clicking into an
            // existing token instead is undone by the repair pass in
            // `ComposerMentionMarkerStore.selections(in:)`.)
            textView.typingAttributes = ComposerMessageTextViewRepresentable.plainTypingAttributes
            text.wrappedValue = textView.string
            publishMentionSelections(for: textView)
            updateMeasuredHeight(for: textView)
            textView.window?.makeFirstResponder(textView)
            publishMentionContext(for: textView)
            onMentionInsertionConsumed(insertion.id)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            publishMentionSelections(for: textView)
            updateMeasuredHeight(for: textView)
            publishMentionContext(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publishMentionContext(for: textView)
        }

        private static let mentionCommands: [Selector: ComposerMentionCommand] = [
            #selector(NSResponder.insertTab(_:)): .accept,
            #selector(NSResponder.moveUp(_:)): .moveUp,
            #selector(NSResponder.moveDown(_:)): .moveDown,
        ]

        /// Tab completes an open "@query" with the highlighted candidate, and Up and Down move the
        /// highlight. Only when the picker is showing is the key consumed; otherwise Up in an empty
        /// composer edits the user's latest message, Escape abandons an edit, and every other key
        /// inserts its tab or moves the caret as before. Arrives as a command, so it never fires
        /// mid-composition — the input context keeps these keys while text is marked.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if let command = Self.mentionCommands[commandSelector], applyMentionCommand(command, in: textView) {
                return true
            }
            // A key that ended a composition was the input context's, not an edit command.
            if (textView as? ComposerPasteInterceptingTextView)?.isHandlingKeyFromComposition == true {
                return false
            }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                // Only an empty composer: with a draft, Up moves the caret between its lines.
                guard textView.string.isEmpty else { return false }
                return onEditCommand(.editLastMessage)
            case #selector(NSResponder.cancelOperation(_:)):
                return onEditCommand(.cancelEdit)
            default:
                return false
            }
        }

        /// The send shortcut. While an "@query" is open and has a candidate, Return completes the
        /// mention instead — a lone "@" must not go out as the message. Otherwise it sends.
        func handleReturnKeySend(in textView: NSTextView) {
            guard !applyMentionCommand(.accept, in: textView) else { return }
            onSend()
        }

        private func applyMentionCommand(_ command: ComposerMentionCommand, in textView: NSTextView) -> Bool {
            publishMentionContext(for: textView)
            guard lastMentionContext != nil else { return false }
            return onMentionCommand(command)
        }

        /// Recompute the open mention query left of the caret and forward it upward when it
        /// changes, so the picker tracks both typing and caret moves.
        private func publishMentionContext(for textView: NSTextView) {
            let context = Self.mentionContext(in: textView)
            guard context != lastMentionContext else { return }
            lastMentionContext = context
            onMentionContextChange(context)
        }

        func synchronizeMentionContextScope(
            _ scope: WorkspaceState.ComposerDraftKey?,
            in textView: NSTextView
        ) {
            guard mentionContextScope != scope else { return }
            mentionContextScope = scope
            lastMentionContext = nil
            publishMentionContext(for: textView)
        }

        private static func mentionContext(in textView: NSTextView) -> ComposerMentionContext? {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }
            let full = textView.string
            guard let caret = Range(NSRange(location: selection.location, length: 0), in: full)?.lowerBound,
                let session = ComposerMentionQuery.active(in: full, upTo: caret),
                !ComposerMentionQuery.looksLikeCompleteNpub(session.query)
            else { return nil }
            return ComposerMentionContext(query: session.query, tokenRange: NSRange(session.range, in: full))
        }

        func synchronizeMentionMarkers(in textView: NSTextView) {
            let desired = mentionSelections.wrappedValue
            guard ComposerMentionMarkerStore.selections(in: textView) != desired else { return }
            ComposerMentionMarkerStore.replaceAll(with: desired, in: textView)
            publishMentionSelections(for: textView)
        }

        private func publishMentionSelections(for textView: NSTextView) {
            let selections = ComposerMentionMarkerStore.selections(in: textView)
            if mentionSelections.wrappedValue != selections {
                mentionSelections.wrappedValue = selections
            }
        }

        func handleMediaPaste() -> Bool {
            let attachments = OutgoingMediaPasteboardReader.attachments(from: .general)
            guard !attachments.isEmpty else { return false }
            onPasteMedia(attachments)
            return true
        }

        func updateMeasuredHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let insetHeight = textView.textContainerInset.height * 2
            let height = min(
                ComposerMessageInputMetrics.maxHeight,
                max(ComposerMessageInputMetrics.minHeight, ceil(usedHeight + insetHeight))
            )
            if abs(measuredHeight.wrappedValue - height) > 0.5 {
                measuredHeight.wrappedValue = height
            }
        }
    }
}

@MainActor
enum ComposerMentionMarkerStore {
    private struct Repair {
        let oldRange: NSRange
        let selection: ComposerMentionSelection
    }

    static func add(_ selection: ComposerMentionSelection, to textView: NSTextView) {
        guard isExact(selection, in: textView.string), let storage = textView.textStorage else { return }
        storage.addAttribute(.composerMentionNpub, value: selection.npub, range: selection.range)
        storage.addAttribute(.composerMentionDisplayText, value: selection.displayText, range: selection.range)
        // The same treatment a rendered mention gets — bold, in the surrounding content color —
        // so a token looks the same while you are typing it as it will once it is sent.
        storage.addAttribute(
            .foregroundColor,
            value: WNNSColor.textPrimary,
            range: selection.range
        )
        storage.addAttribute(
            .font,
            value: ComposerMessageTextViewRepresentable.mentionFont,
            range: selection.range
        )
    }

    static func replaceAll(with selections: [ComposerMentionSelection], in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        removeMarkers(in: fullRange, from: storage)
        for selection in selections {
            add(selection, to: textView)
        }
    }

    /// Reverts a range to plain typed text: the identity markers come off, and the styling `add`
    /// laid over them is *restored to the plain values* rather than removed.
    ///
    /// Restoring rather than removing is the whole point. With no `.foregroundColor` attribute at
    /// all, TextKit draws the run in opaque black — it does not fall back to the text view's
    /// `textColor` — which is invisible on the composer's `backgroundPrimary` field in dark
    /// appearance and fine in light, so the damage only shows in one of the two. `replaceAll`
    /// sweeps the *entire* storage before re-adding tokens, so one mention anywhere in a draft was
    /// enough to blank every character of it.
    ///
    /// The styling is still never maintained on its own: it is written only by `add` and reset
    /// wherever the markers are dropped, so it cannot drift from identity. Resetting these keys is
    /// safe over any range because the composer text view is plain text (`isRichText = false`), so
    /// the plain attributes are what every unstyled character already carries.
    private static func removeMarkers(in range: NSRange, from storage: NSTextStorage) {
        storage.removeAttribute(.composerMentionNpub, range: range)
        storage.removeAttribute(.composerMentionDisplayText, range: range)
        guard range.length > 0 else { return }
        storage.addAttributes(ComposerMessageTextViewRepresentable.plainTypingAttributes, range: range)
    }

    static func selections(in textView: NSTextView) -> [ComposerMentionSelection] {
        guard let storage = textView.textStorage else { return [] }
        let text = textView.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard fullRange.length > 0 else { return [] }
        var selections: [ComposerMentionSelection] = []
        var invalidRanges: [NSRange] = []
        var repairs: [Repair] = []
        storage.enumerateAttribute(.composerMentionNpub, in: fullRange) { value, range, _ in
            guard let npub = value as? String,
                let displayText = storage.attribute(
                    .composerMentionDisplayText,
                    at: range.location,
                    effectiveRange: nil
                ) as? String,
                let normalizedRange = normalizedRange(
                    for: displayText,
                    within: range,
                    in: text
                )
            else {
                invalidRanges.append(range)
                return
            }
            let selection = ComposerMentionSelection(
                range: normalizedRange,
                displayText: displayText,
                npub: npub
            )
            selections.append(selection)
            if normalizedRange != range {
                repairs.append(Repair(oldRange: range, selection: selection))
            }
        }
        guard !invalidRanges.isEmpty || !repairs.isEmpty else {
            return selections.sorted { $0.location < $1.location }
        }
        storage.beginEditing()
        for range in invalidRanges + repairs.map(\.oldRange) {
            removeMarkers(in: range, from: storage)
        }
        for repair in repairs {
            add(repair.selection, to: textView)
        }
        storage.endEditing()
        return selections.sorted { $0.location < $1.location }
    }

    private static func normalizedRange(
        for displayText: String,
        within attributedRange: NSRange,
        in text: String
    ) -> NSRange? {
        let nsText = text as NSString
        guard attributedRange.location >= 0,
            attributedRange.length > 0,
            NSMaxRange(attributedRange) <= nsText.length
        else { return nil }
        if nsText.substring(with: attributedRange) == displayText,
            ComposerMentionCanonicalizer.isValidVisibleMention(attributedRange, in: text)
        {
            return attributedRange
        }
        let first = nsText.range(of: displayText, options: [], range: attributedRange)
        guard first.location != NSNotFound,
            ComposerMentionCanonicalizer.isValidVisibleMention(first, in: text)
        else { return nil }
        let remainingLocation = NSMaxRange(first)
        if remainingLocation < NSMaxRange(attributedRange) {
            let remaining = NSRange(
                location: remainingLocation,
                length: NSMaxRange(attributedRange) - remainingLocation
            )
            guard nsText.range(of: displayText, options: [], range: remaining).location == NSNotFound else {
                return nil
            }
        }
        return first
    }

    private static func isExact(_ selection: ComposerMentionSelection, in text: String) -> Bool {
        selection.location >= 0
            && selection.length > 0
            && NSMaxRange(selection.range) <= (text as NSString).length
            && (text as NSString).substring(with: selection.range) == selection.displayText
            && ComposerMentionCanonicalizer.isValidVisibleMention(selection.range, in: text)
    }
}

private extension NSAttributedString.Key {
    static let composerMentionNpub = NSAttributedString.Key("whitenoise.composerMentionNpub")
    static let composerMentionDisplayText = NSAttributedString.Key("whitenoise.composerMentionDisplayText")
}

@MainActor
final class ComposerPasteInterceptingTextView: NSTextView {
    var mediaPasteHandler: (() -> Bool)?
    var returnKeySendHandler: (() -> Void)?
    var windowAttachHandler: (() -> Void)?
    /// Whether the key being handled arrived while text was marked. The input context ends the
    /// composition before the key's command reaches the delegate, so `hasMarkedText()` is
    /// already false by then.
    private(set) var isHandlingKeyFromComposition = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowAttachHandler?()
    }

    override func paste(_ sender: Any?) {
        if mediaPasteHandler?() == true {
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        isHandlingKeyFromComposition = hasMarkedText()
        defer { isHandlingKeyFromComposition = false }
        guard event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\n" else {
            super.keyDown(with: event)
            return
        }

        // While a composition is marked, Return belongs to the input context — it commits the
        // pending candidate, so forwarding it must win over the send shortcut.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        switch ComposerKeyboardShortcutPolicy.returnKeyAction(for: event.modifierFlags) {
        case .send:
            returnKeySendHandler?()
        case .insertLineBreak:
            insertNewlineIgnoringFieldEditor(nil)
        case .deferToSystem:
            super.keyDown(with: event)
        }
    }
}

/// The files staged for the next message, followed by any the last selection refused. A refused
/// file stays in line with the ones that made it, as a failed tile, until the user dismisses it,
/// stages again, or sends.
struct PendingMediaDraftStrip: View {
    let attachments: [PendingMediaAttachment]
    let uploadStates: [PendingMediaAttachment.ID: PendingMediaUploadState]
    let isSending: Bool
    let onRemove: (PendingMediaAttachment.ID) -> Void
    let onRetryUpload: (PendingMediaAttachment.ID) -> Void
    var rejections: [ComposerAttachmentRejections.Item] = []
    var onDismissRejection: (ComposerAttachmentRejections.Item.ID) -> Void = { _ in }

    private let tileSize = CGSize(width: 74, height: 74)

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        PendingMediaDraftTile(
                            attachment: attachment,
                            tileSize: tileSize,
                            uploadState: uploadStates[attachment.id],
                            onRetry: { onRetryUpload(attachment.id) }
                        )

                        if !isSending {
                            PendingMediaDraftRemoveButton(help: L10n.string("Remove attachment")) {
                                onRemove(attachment.id)
                            }
                        }
                    }
                }

                ForEach(rejections) { item in
                    ZStack(alignment: .topTrailing) {
                        RejectedAttachmentTile(rejection: item.rejection, tileSize: tileSize)
                        PendingMediaDraftRemoveButton(help: L10n.string("Dismiss"), isDestructive: true) {
                            onDismissRejection(item.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
    }
}

/// The small disc on a strip tile's corner that takes it out of the draft. A refused file's tile
/// wears it red, matching the tile it dismisses.
private struct PendingMediaDraftRemoveButton: View {
    let help: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                // Two-layer glyph: the inner disc is the surface it is
                // punched out of, the ring is content on that surface.
                .foregroundStyle(
                    isDestructive ? WNColor.fillContentQuaternary : WNColor.backgroundPrimary,
                    isDestructive ? WNColor.fillDestructive : WNColor.backgroundContentSecondary
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .offset(x: 7, y: -7)
    }
}

struct PendingMediaDraftTile: View {
    let attachment: PendingMediaAttachment
    let tileSize: CGSize
    let uploadState: PendingMediaUploadState?
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch attachment.kind {
            case .image:
                PendingMediaImagePreview(attachment: attachment, tileSize: tileSize)
            case .audio:
                PendingMediaAudioPreview(attachment: attachment)
            case .video, .file:
                PendingMediaFilePreview(attachment: attachment)
            }
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WNColor.fillSecondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if let uploadState {
                PendingMediaUploadStatusBadge(state: uploadState, onRetry: onRetry)
                    .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PendingMediaImagePreview: View {
    let attachment: PendingMediaAttachment
    let tileSize: CGSize

    @State private var decodedImagePreview: NSImage?
    @State private var decodedImageTaskID: String?

    var body: some View {
        Group {
            if let image = decodedImagePreview {
                AttachmentGIFPlayback(
                    contentID: attachment.id.uuidString,
                    data: AttachmentGIF.isGIF(mediaType: attachment.mediaType) ? attachment.data : nil,
                    isActive: true
                ) { frame in
                    (frame ?? Image(nsImage: image))
                        .resizable()
                        .scaledToFill()
                        .accessibilityLabel(attachment.fileName)
                }
            } else {
                Image(systemName: attachment.kind.systemImageName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: imagePreviewTaskID) {
            await loadImagePreview()
        }
    }

    private var imagePreviewTaskID: String {
        "\(attachment.id.uuidString)|\(attachment.data.count)|\(Int(imagePreviewMaxPixelSize))"
    }

    private var imagePreviewMaxPixelSize: CGFloat {
        ceil(max(tileSize.width, tileSize.height) * 2)
    }

    @MainActor
    private func loadImagePreview() async {
        let taskID = imagePreviewTaskID
        if decodedImageTaskID == taskID {
            return
        }

        decodedImageTaskID = taskID
        decodedImagePreview = nil

        let data = attachment.data
        let maxPixelSize = imagePreviewMaxPixelSize
        let decoded = await Task.detached(priority: .utility) {
            PendingMediaDraftThumbnailDecoder.image(from: data, maxPixelSize: maxPixelSize)
        }.value

        guard decodedImageTaskID == taskID else { return }
        decodedImagePreview = decoded
    }
}

private struct PendingMediaAudioPreview: View {
    let attachment: PendingMediaAttachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.headline)
                .foregroundStyle(WNColor.textPrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                ComposerAudioWaveformView(
                    samples: attachment.waveformSamples,
                    progress: 0,
                    barColor: Color(nsColor: .tertiaryLabelColor),
                    playedColor: WNColor.textPrimary
                )
                .frame(height: 24)

                Text(attachment.durationLabel ?? attachment.sizeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct PendingMediaFilePreview: View {
    let attachment: PendingMediaAttachment

    private var systemFileIcon: NSImage? {
        guard attachment.kind == .file else { return nil }
        let ext = (attachment.fileName as NSString).pathExtension
        guard
            let type = UTType(mimeType: attachment.mediaType)
                ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext))
        else { return nil }
        return NSWorkspace.shared.icon(for: type)
    }

    var body: some View {
        VStack(spacing: 4) {
            if let systemFileIcon {
                Image(nsImage: systemFileIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: attachment.kind.systemImageName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(attachment.fileName)
                .font(.caption2)
                .foregroundStyle(WNColor.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6)
    }
}

/// Only the states that need the user's attention get a badge. A finished upload deliberately
/// shows nothing: the spinner going away is the confirmation, and a green tick sitting on every
/// thumbnail for the rest of the draft's life is clutter that says nothing new. What is left to
/// wait for is reported once, on the send button.
private struct PendingMediaUploadStatusBadge: View {
    let state: PendingMediaUploadState
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: .circle)
                .shadow(color: WNColor.shadow.opacity(0.1), radius: 4, y: 1)
        case .uploaded:
            EmptyView()
        case .failed:
            Button(action: onRetry) {
                Label(L10n.string("Retry upload"), systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WNColor.fillContentQuaternary)
                    .frame(width: 24, height: 24)
                    .background(WNColor.statusError, in: .circle)
            }
            .buttonStyle(.plain)
            .shadow(color: WNColor.shadow.opacity(0.12), radius: 4, y: 1)
            .help(L10n.string("Retry upload"))
            .accessibilityLabel(L10n.string("Retry upload"))
        }
    }
}

#Preview("Pending media draft strip") {
    let pdf = PendingMediaAttachment(
        id: UUID(),
        fileName: "Quarterly-Report.pdf",
        mediaType: "application/pdf",
        data: Data(repeating: 0, count: 4096),
        dim: nil
    )
    let video = PendingMediaAttachment(
        id: UUID(),
        fileName: "clip.mp4",
        mediaType: "video/mp4",
        data: Data(repeating: 0, count: 8192),
        dim: nil
    )
    PendingMediaDraftStrip(
        attachments: [pdf, video],
        uploadStates: [pdf.id: .uploading, video.id: .failed],
        isSending: false,
        onRemove: { _ in },
        onRetryUpload: { _ in },
        rejections: [
            ComposerAttachmentRejections.Item(
                id: UUID(),
                rejection: AttachmentRejection(source: .file(name: "archive.dmg"), reason: .unsupportedType)
            )
        ]
    )
    .padding()
    .frame(width: 420)
}

nonisolated enum PendingMediaDraftThumbnailDecoder {
    static func image(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixelSize)),
            ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return DownsampledImageSizing.image(fromDownsampled: cgImage)
    }
}

/// The composer while the mic is hot: a live waveform, the elapsed time, and Stop. There is no
/// cancel here — stopping hands the recording to the voice-draft bar, whose trash can throws it
/// away, so the one path out is the one the user was going to take anyway.
struct VoiceRecordingComposerView: View {
    /// The visible tail of the recording, oldest first.
    let samples: [CGFloat]
    let durationSeconds: Double
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VoiceRecordingPulseDot()

            VoiceRecordingWaveformView(
                levels: samples,
                window: .liveTail,
                // Recording, so every bar is "live" rather than played — one token at full
                // strength. Primary content rather than destructive red: a recording in progress is
                // the composer doing what it was asked to, not an error.
                barColor: WNColor.textPrimary
            )
            .frame(height: 30)

            Text(Self.durationLabel(durationSeconds))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)

            // Stop is the only thing this bar asks for, so it wears the primary monochrome button
            // tier rather than a destructive one. Finishing a recording hands off to the
            // voice-draft bar, where discarding lives.
            Button(action: onStop) {
                Label(L10n.string("Finish recording"), systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .wnPrimaryButtonStyle()
            .wnButtonShape(.circle)
            .controlSize(.regular)
            .help(L10n.string("Finish recording"))
            .accessibilityLabel(L10n.string("Finish recording"))
            .accessibilityIdentifier("composer.voiceRecording.stop")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private static func durationLabel(_ duration: Double) -> String {
        MediaDurationLabel.string(for: duration)
    }
}

#Preview("Voice recording") {
    VoiceRecordingComposerView(
        samples: [0.2, 0.5, 0.85, 0.4, 0.7, 0.3, 0.9, 0.6, 0.45, 0.55],
        durationSeconds: 12.4,
        onStop: {}
    )
    .padding()
    .frame(width: 480)
}

/// The composer once a recording has been stopped: trash it, listen back, or send it. It stands
/// in for the whole composer row — no text field, no emoji, no paperclip — because a recording is
/// sent as a message of its own rather than staged as one more attachment.
struct VoiceMessageDraftComposerView: View {
    let attachment: PendingMediaAttachment
    let uploadState: PendingMediaUploadState?
    let isSending: Bool
    let canSend: Bool
    /// Worded by the shell exactly as it words it for the text composer. An unfinished upload no
    /// longer keeps Send off — the recording carries on uploading from its bubble — so this is the
    /// plain Send label; the bar still offers its own retry while the recording is staged.
    let sendHelp: String
    let onDiscard: () -> Void
    let onRetryUpload: () -> Void
    let onSend: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    /// Identifies the preparation currently allowed to install a player. A bare `Bool` cannot
    /// tell two overlapping preparations apart, so a take that finished late could pass the
    /// guard opened by a newer take and play the wrong recording. Matches the transcript row's
    /// player in `MessageMediaViews`.
    @State private var playbackPreparationID: UUID?
    @State private var playbackProgress: CGFloat = 0
    @State private var elapsedSeconds: Double = 0
    @State private var playbackMonitor: Task<Void, Never>?
    @State private var playbackDelegate = MessageAudioPlayerDelegate()

    private var isPreparingPlayback: Bool {
        playbackPreparationID != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Label(playbackActionLabel, systemImage: isPlaying || isPreparingPlayback ? "stop.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .wnSecondaryButtonStyle()
            .controlSize(.regular)
            .help(playbackActionLabel)
            // `help` becomes the tooltip, not the label: an icon-only button needs the action
            // spelled out or VoiceOver is left announcing the SF Symbol.
            .accessibilityLabel(playbackActionLabel)
            .accessibilityIdentifier("composer.voiceDraft.playback")

            // The strip the mic was drawing a moment ago, standing still: the same view, the same
            // bar width and pitch, the same length the take had reached. The transcript's playback
            // waveform is drawn on other terms — a fixed bar count divided into whatever width it
            // is given — and across a composer-wide bar that lands each bar about as wide as a
            // finger, which is not what the user just watched themselves record.
            //
            // Unplayed bars are de-emphasized, played bars are full-strength content — the same
            // reading the transcript's audio rows use, so progress is legible as one hue at two
            // weights rather than two competing colors.
            VoiceRecordingWaveformView(
                levels: attachment.waveformSamples,
                window: .stopped(recordedSeconds: attachment.durationSeconds),
                barColor: Color(nsColor: .tertiaryLabelColor),
                playback: VoiceRecordingWaveformView.PlaybackTint(
                    progress: playbackProgress,
                    playedColor: WNColor.textPrimary
                )
            )
            .frame(height: 30)

            ZStack(alignment: .trailing) {
                Text(MediaDurationLabel.string(for: isPlaying ? elapsedSeconds : (attachment.durationSeconds ?? 0)))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(uploadState == .uploading || isSending ? 0 : 1)

                if uploadState == .uploading || isSending {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(minWidth: 44, alignment: .trailing)

            // Discard sits with Send rather than at the far left: the two decisions the bar asks
            // for — throw it away or send it — belong next to each other, past the recording.
            Button(role: .destructive, action: discard) {
                Label(L10n.string("Delete recording"), systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(WNColor.intentionErrorContent)
                    .frame(width: 20, height: 20)
            }
            .wnSecondaryButtonStyle()
            .controlSize(.regular)
            .disabled(isSending)
            .help(L10n.string("Delete recording"))
            .accessibilityLabel(L10n.string("Delete recording"))
            .accessibilityIdentifier("composer.voiceDraft.delete")

            if uploadState == .failed {
                Button(action: onRetryUpload) {
                    Label(L10n.string("Retry upload"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(WNColor.intentionErrorContent)
                        .frame(width: 20, height: 20)
                }
                .wnSecondaryButtonStyle()
                .controlSize(.regular)
                .help(L10n.string("Retry upload"))
                .accessibilityLabel(L10n.string("Retry upload"))
            }

            Button(action: send) {
                Label(sendHelp, systemImage: "paperplane.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .wnPrimaryButtonStyle()
            .controlSize(.regular)
            .disabled(!canSend)
            .help(sendHelp)
            .accessibilityLabel(sendHelp)
            .accessibilityIdentifier("composer.voiceDraft.send")
        }
        .wnButtonShape(.circle)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        // The player is built from one recording's bytes: if this view's identity outlives a
        // re-recording, drop it so playback cannot replay the discarded take.
        .onChange(of: attachment.id) { _, _ in
            stopPlayback()
            player = nil
        }
        .onDisappear {
            stopPlayback()
        }
    }

    /// Tracks the icon: preparing counts as playing, because the tap that starts playback is
    /// already cancellable by a second tap.
    private var playbackActionLabel: String {
        isPlaying || isPreparingPlayback ? L10n.string("Stop") : L10n.string("Play")
    }

    private func discard() {
        stopPlayback()
        onDiscard()
    }

    private func send() {
        guard !isSending else { return }
        stopPlayback()
        onSend()
    }

    private func togglePlayback() async {
        if isPlaying || isPreparingPlayback {
            stopPlayback()
        } else {
            await startPlayback()
        }
    }

    private func startPlayback() async {
        var preparationID: UUID?
        do {
            if player == nil {
                let data = attachment.data
                let nextPreparationID = UUID()
                preparationID = nextPreparationID
                playbackPreparationID = nextPreparationID
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let audioPlayer = try AVAudioPlayer(data: data)
                    audioPlayer.prepareToPlay()
                    return PreparedMessageAudioPlayer(player: audioPlayer)
                }.value.player
                // A newer take, a Stop, or a discard has moved the token on: this player is for a
                // recording the bar is no longer showing, so drop it rather than install it.
                guard playbackPreparationID == nextPreparationID else { return }
                playbackPreparationID = nil
                player = prepared
                prepared.delegate = playbackDelegate
            }
            playbackDelegate.onDidFinishPlaying = finishPlayback
            player?.play()
            isPlaying = true
            updatePlaybackProgress()
            monitorPlaybackProgress()
        } catch {
            // Only the still-current preparation may reset playback state; a stale failure must
            // not clear the token a live preparation is waiting on.
            if preparationID == nil || playbackPreparationID == preparationID {
                playbackPreparationID = nil
                isPlaying = false
            }
        }
    }

    private func stopPlayback() {
        playbackPreparationID = nil
        playbackDelegate.onDidFinishPlaying = nil
        player?.stop()
        finishPlayback()
    }

    /// The one rewind path, reached both by `stopPlayback()` and by the delegate when the recording
    /// plays out. Winding `currentTime` back here is what the natural end needs: `stop()` leaves the
    /// playhead where it was, so a player left at the end would make the next Play finish instantly.
    private func finishPlayback() {
        playbackMonitor?.cancel()
        playbackMonitor = nil
        player?.currentTime = 0
        isPlaying = false
        playbackProgress = 0
        elapsedSeconds = 0
    }

    private func monitorPlaybackProgress() {
        playbackMonitor?.cancel()
        playbackMonitor = Task { @MainActor in
            while !Task.isCancelled, isPlaying {
                updatePlaybackProgress()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func updatePlaybackProgress() {
        guard let player, player.duration > 0 else { return }
        elapsedSeconds = player.currentTime
        playbackProgress = CGFloat(min(1, max(0, player.currentTime / player.duration)))
    }
}

#Preview("Voice message draft") {
    let recording = PendingMediaAttachment(
        id: UUID(),
        fileName: "voice-message.m4a",
        mediaType: "audio/mp4",
        data: Data(repeating: 0, count: 2048),
        dim: nil,
        durationSeconds: 7.5,
        waveformSamples: [0.2, 0.5, 0.85, 0.4, 0.7, 0.3, 0.9, 0.6],
        isVoiceMessage: true
    )
    VStack(spacing: 12) {
        VoiceMessageDraftComposerView(
            attachment: recording,
            uploadState: nil,
            isSending: false,
            canSend: true,
            sendHelp: L10n.string("Send"),
            onDiscard: {},
            onRetryUpload: {},
            onSend: {}
        )
        VoiceMessageDraftComposerView(
            attachment: recording,
            uploadState: .failed,
            isSending: false,
            canSend: true,
            sendHelp: L10n.string("Send"),
            onDiscard: {},
            onRetryUpload: {},
            onSend: {}
        )
    }
    .padding()
    .frame(width: 480)
}

nonisolated struct ComposerAudioWaveformBar: Equatable {
    let amplitude: CGFloat
}

nonisolated enum ComposerAudioWaveformPresentation {
    static let amplitudeCurveExponent: Double = 0.45
    static let fallbackPlaybackBars = bars(for: MediaWaveformAnalyzer.fallbackSamples)

    static func visiblePlaybackBars(
        loadedBars: [ComposerAudioWaveformBar],
        metadataPayloadID: String?,
        currentPayloadID: String
    ) -> [ComposerAudioWaveformBar] {
        metadataPayloadID == currentPayloadID ? loadedBars : fallbackPlaybackBars
    }

    /// Bars for a recording that is already on disk, which is every waveform this draws. A live one
    /// needs bars that keep their identity from one metered sample to the next, so it is built by
    /// `VoiceRecordingWaveform` instead.
    static func bars(
        for samples: [CGFloat],
        count: Int = MediaWaveformAnalyzer.sampleCount
    ) -> [ComposerAudioWaveformBar] {
        let targetCount = max(0, count)
        guard targetCount > 0 else { return [] }
        return MediaWaveformAnalyzer.normalized(samples, count: targetCount)
            .map(displayAmplitude)
            .map { ComposerAudioWaveformBar(amplitude: $0) }
    }

    private static func displayAmplitude(_ sample: CGFloat) -> CGFloat {
        let bounded = min(1, max(0.05, sample))
        return min(1, max(0.05, CGFloat(pow(Double(bounded), amplitudeCurveExponent))))
    }
}

struct ComposerAudioWaveformView: View {
    let bars: [ComposerAudioWaveformBar]
    let progress: CGFloat
    let barColor: Color
    let playedColor: Color

    // Convenience path for one-shot previews. Playback rows pass precomputed bars so
    // progress ticks only recolor already-prepared amplitudes.
    init(
        samples: [CGFloat],
        progress: CGFloat,
        barColor: Color,
        playedColor: Color
    ) {
        self.init(
            bars: ComposerAudioWaveformPresentation.bars(for: samples),
            progress: progress,
            barColor: barColor,
            playedColor: playedColor
        )
    }

    init(
        bars: [ComposerAudioWaveformBar],
        progress: CGFloat,
        barColor: Color,
        playedColor: Color
    ) {
        self.bars = bars
        self.progress = progress
        self.barColor = barColor
        self.playedColor = playedColor
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let barCount = max(1, bars.count)
            let availableWidth = geometry.size.width - spacing * CGFloat(max(0, barCount - 1))
            let barWidth = max(2, availableWidth / CGFloat(barCount))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    Capsule()
                        .fill(fillColor(for: bar, index: index, count: bars.count))
                        .frame(
                            width: barWidth,
                            height: barHeight(for: bar, in: geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    private func fillColor(for bar: ComposerAudioWaveformBar, index: Int, count: Int) -> Color {
        let played = CGFloat(index) / CGFloat(max(1, count - 1)) <= progress
        return played ? playedColor : barColor
    }

    private func barHeight(for bar: ComposerAudioWaveformBar, in availableHeight: CGFloat) -> CGFloat {
        max(4, availableHeight * min(1, max(0.08, bar.amplitude)))
    }
}

struct TimelineInitialLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(L10n.string("Loading messages..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("Loading messages"))
    }
}

struct TimelinePageLoadingRow: View {
    let isLoading: Bool

    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .opacity(isLoading ? 1 : 0.55)
            Spacer()
        }
        .frame(height: 28)
        .padding(.vertical, 2)
    }
}

struct ReplyComposerContextView: View {
    let context: MessageReplyContext
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(WNColor.fillPrimary)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L10n.string("Replying to %@"), context.senderName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WNColor.textPrimary)
                    .lineLimit(1)

                Text(context.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 12)

            Button(action: cancel) {
                Label(L10n.string("Cancel reply"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Cancel reply"))
            .accessibilityLabel(L10n.string("Cancel reply"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

struct EditComposerContextView: View {
    let context: MessageEditContext

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WNColor.textPrimary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Editing message"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WNColor.textPrimary)
                Text(context.originalBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

#Preview("Reply and edit context") {
    VStack(spacing: 10) {
        ReplyComposerContextView(
            context: MessageReplyContext(
                targetMessageId: "msg-1",
                senderName: "Alice",
                body: "See you at the station around six!"
            ),
            cancel: {}
        )
        EditComposerContextView(
            context: MessageEditContext(
                targetMessageId: "msg-2",
                senderName: "You",
                originalBody: "Typo in the earlier note",
                preservedDraft: "",
                preservedMentionSelections: [],
                preservedReplyContext: nil,
                preservedMediaAttachments: [],
                preservedMediaUploadStates: [:]
            )
        )
    }
    .padding()
    .frame(width: 440)
}

/// Replaces the composer for a group the local account left or was removed from:
/// the transcript stays readable, but the core would reject any send
/// (`invalid_transition`), so no input is offered.
struct MembershipEndedComposerNotice: View {
    let membership: ChatSelfMembership

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: membership.endedSymbolName ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(membership.endedDescription ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(ChatSelfMembership.endedHistoryExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(WNColor.backgroundPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
        .accessibilityIdentifier("composer.membershipEnded")
    }
}

/// Replaces the composer until the user accepts, declines, or blocks the inviter on a pending invite.
struct PendingGroupInviteComposerNotice: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session
    @Environment(\.locale) private var locale
    let chat: ChatItem
    var blockedUsersModel: BlockedUsersViewModel?
    var moderationReporter: ModerationReporter?

    var body: some View {
        let inviter = workspace.pendingInviteInviterIdentity(for: chat)

        VStack(alignment: .leading, spacing: 12) {
            // Once the inviter resolves, their avatar leads the notice and opens their profile:
            // the invitee's one chance to check who this is — npub included — before answering.
            // The lock stands in until then, so the row never has an empty leading slot.
            HStack(alignment: inviter == nil ? .firstTextBaseline : .center, spacing: 10) {
                if let inviter {
                    PendingInviteInviterAvatar(chat: chat, inviter: inviter, name: inviterName)
                } else {
                    Image(systemName: "lock.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WNColor.intentionInfoContent)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(inviteMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.string("If you decline, this chat will be removed from your chat list.", locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if let inviter, let blockedUsersModel, !blockedUsersModel.isBlocked(accountID: inviter.accountIdHex) {
                    PendingInviteBlockControl(
                        accountID: inviter.accountIdHex,
                        blockedUsersModel: blockedUsersModel,
                        reporter: moderationReporter
                    )
                }
            }

            PendingInviteActionButtons(
                accept: { await workspace.acceptGroupInvite(for: chat) },
                decline: { confirm in
                    await workspace.declineGroupInvite(
                        for: chat, confirmAdminStepDown: confirm, advisory: session.accountScope?.groupChangeAdvisory)
                }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(WNColor.backgroundPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
        // `.contain` keeps the identifier on the card: applied to the bare stack it overrode every
        // child's, so Accept and Decline both answered to "composer.pendingGroupInvite".
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.pendingGroupInvite")
        // This prompt replaces the composer, so the roster (and with it the inviter) has no
        // other reason to load for the chat that most needs it.
        .task(id: chat.id) {
            workspace.ensureGroupInviterLoaded(forGroupIdHex: chat.id)
        }
    }

    private var inviteMessage: String {
        String(
            format: L10n.string("%@ invited you to a secure chat.", locale: locale),
            PeerDisplayText.templateFragment(inviterName)
        )
    }

    /// Who to name as the inviter, best source first.
    ///
    /// The group record's welcome sender is the only authoritative answer — a chat-list row
    /// carries no welcomer, which is why this used to guess from the preview and land on
    /// "Someone" for the case an invite is most often seen in: a direct chat with no messages
    /// yet, whose preview is empty. `directPeerName` covers a record that kept no welcome
    /// sender: a one-to-one has exactly one other member, so they are the inviter.
    private var inviterName: String {
        workspace.inviterDisplayName(forGroupIdHex: chat.id)
            ?? directPeerName
            ?? previewSenderName
            ?? workspace.inviterIdentifierLabel(forGroupIdHex: chat.id)
            ?? L10n.string("Someone", locale: locale)
    }

    /// The other party in a direct chat, and only once a peer has actually resolved — a title
    /// standing in for an unresolved peer is the shortened group id, which names nobody.
    private var directPeerName: String? {
        guard chat.isDirect, chat.directPeerAccountIdHex != nil else { return nil }
        return chat.title.nilIfBlank
    }

    private var previewSenderName: String? {
        let preview = chat.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = preview.firstIndex(of: ":") else { return nil }
        let candidate = String(preview[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
            candidate != L10n.string("You", locale: locale),
            candidate != chat.title
        else { return nil }
        return candidate
    }
}

/// Optional Block / Block and Report control on a pending invite notice, reusing the same
/// confirmation dialog and `BlockedUsersViewModel` / `ModerationReporter` owners as contact details.
private struct PendingInviteBlockControl: View {
    @Environment(\.locale) private var locale
    let accountID: String
    let blockedUsersModel: BlockedUsersViewModel
    let reporter: ModerationReporter?
    @State private var isConfirmingBlock = false

    private var reportedAccountId: String? {
        MessageModerationEligibility.normalizedAccountId(accountID)
    }

    private var availableReporter: ModerationReporter? {
        guard let reporter, reporter.isAvailable, reportedAccountId != nil else { return nil }
        return reporter
    }

    var body: some View {
        Button(role: .destructive) {
            isConfirmingBlock = true
        } label: {
            Label(L10n.string("Block User", locale: locale), systemImage: "hand.raised")
        }
        .wnSecondaryButtonStyle()
        .controlSize(.small)
        .disabled(!blockedUsersModel.canMutate(accountID: accountID))
        .accessibilityIdentifier("invite.block")
        .confirmationDialog(
            L10n.string("Block this user?", locale: locale),
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            if let reporter = availableReporter, let reportedAccountId {
                Button(L10n.string("Block and Report", locale: locale), role: .destructive) {
                    reporter.startBlocking(accountIdHex: reportedAccountId, reporting: true)
                }
            }
            Button(L10n.string("Block User", locale: locale), role: .destructive) {
                if let reporter, let reportedAccountId {
                    reporter.startBlocking(accountIdHex: reportedAccountId, reporting: false)
                } else {
                    Task { await blockedUsersModel.setBlocked(true, accountID: accountID) }
                }
            }
            Button(L10n.string("Cancel", locale: locale), role: .cancel) {}
        } message: {
            BlockUserConfirmationMessage(reportsToTeam: availableReporter != nil)
        }
    }
}

/// The inviter's avatar in the pending-invite notice, opening their profile.
///
/// Drawn and wired like the transcript's sender avatar — same control, same contact pane — so
/// "the picture beside a name is how you look that person up" holds here too. A touch larger
/// than the transcript's 28pt, because here it stands beside the notice's two lines of text.
///
/// `name` is the notice's own `inviterName`, so the avatar's monogram and label always read as
/// the sentence beside them, whichever rung of that ladder answered.
private struct PendingInviteInviterAvatar: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem
    let inviter: WorkspaceState.PendingInviteInviterIdentity
    let name: String

    var body: some View {
        Button {
            Task { await workspace.showContactDetails(for: inviter, named: name, invitedTo: chat) }
        } label: {
            ProfileImageAvatarView(
                seed: inviter.accountIdHex,
                initials: name,
                sanitizedPictureURL: inviter.sanitizedPictureURL,
                size: 32,
                isSelected: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewContactLabel)
        .accessibilityIdentifier("composer.pendingGroupInvite.inviter")
        .help(viewContactLabel)
    }

    private var viewContactLabel: String {
        String(format: L10n.string("View contact %@"), name)
    }
}

struct ProfileImageAvatarView: View {
    let seed: String
    let initials: String
    /// Already passed through `RemoteImageURLPolicy` (https only).
    let sanitizedPictureURL: URL?
    let localImagePayload: DownloadedMediaPayload?
    let size: CGFloat
    let isSelected: Bool

    init(
        seed: String,
        initials: String,
        sanitizedPictureURL: URL?,
        localImagePayload: DownloadedMediaPayload? = nil,
        size: CGFloat,
        isSelected: Bool
    ) {
        self.seed = seed
        self.initials = initials
        self.sanitizedPictureURL = sanitizedPictureURL
        self.localImagePayload = localImagePayload
        self.size = size
        self.isSelected = isSelected
    }

    var body: some View {
        Group {
            if let localImagePayload {
                DownsampledDataImage(payload: localImagePayload, maxPixelSize: size * 2) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    AvatarView(seed: seed, initials: initials, size: size, isSelected: isSelected, drawsChrome: false)
                }
            } else if let imageURL = sanitizedPictureURL {
                DownsampledAsyncImage(url: imageURL, maxPixelSize: size * 2) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    AvatarView(seed: seed, initials: initials, size: size, isSelected: isSelected, drawsChrome: false)
                }
            } else {
                AvatarView(seed: seed, initials: initials, size: size, isSelected: isSelected, drawsChrome: false)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .modifier(AvatarChromeModifier(isSelected: isSelected, ringColor: ringColor))
    }

    /// A picture keeps the neutral hairline; the initials fallback wears its accent border, whose
    /// pale fill needs the ring to read as an object. Keyed on whether an image will be *attempted*
    /// rather than on whether one has decoded, so the ring does not change color mid-load.
    private var ringColor: Color {
        let showsPicture = localImagePayload != nil || sanitizedPictureURL != nil
        return showsPicture ? AvatarChromeModifier.neutralRing : AvatarPalette.colors(for: seed).border
    }
}

#Preview("Membership ended notice") {
    VStack(spacing: 12) {
        MembershipEndedComposerNotice(membership: .left)
        MembershipEndedComposerNotice(membership: .removed)
    }
    .padding()
    .frame(width: 480)
}

#Preview("Pending invite notice") {
    PendingGroupInviteComposerNotice(chat: ChatItem.samples[0])
        .environment(WorkspaceState.preview())
        .environment(SessionState())
        .padding()
        .frame(width: 520)
}

struct MessageInfoSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.string("Message Info"))
                    .wnFont(.semiBold16)
                Spacer()
                Button {
                    workspace.messageInfoTarget = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                infoRow(title: L10n.string("From"), value: message.senderName)
                infoRow(
                    title: L10n.string("Sent"),
                    value: DisplayText.longDateTimeTimestamp(for: message.sentAt)
                )
                if message.isEdited {
                    infoRow(title: L10n.string("Status"), value: L10n.string("Edited"))
                }
                infoRow(title: L10n.string("Message ID"), value: message.id)
            }

            if !message.trimmedBody.isEmpty {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { GlassRoundedBackground(cornerRadius: 12) }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func infoRow(title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
