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
import SwiftUI

struct ComposerEmojiInsertion: Equatable {
    let id = UUID()
    let emoji: String
}

/// An open "@query" left of the caret, published by the text view so the shell can show the
/// mention picker. `tokenRange` is the "@…caret" span to replace when a candidate is chosen.
struct ComposerMentionContext: Equatable {
    let query: String
    let tokenRange: NSRange
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
    let onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
    let onSend: () -> Void

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
                onPasteMedia: onPasteMedia,
                onSend: onSend
            )
            .frame(height: measuredHeight)

            if text.isEmpty {
                Text(placeholder)
                    .wnFont(.medium14)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: ComposerMessageInputMetrics.minHeight)
    }
}

private enum ComposerMessageInputMetrics {
    static let minHeight: CGFloat = 20
    static let maxHeight: CGFloat = 96
}

/// Autocomplete list of mentionable group members, shown above the composer while an "@query"
/// is open. Mouse-driven selection; the caret stays in the text field.
struct ComposerMentionPicker: View {
    let candidates: [ComposerMentionCandidate]
    let onSelect: (ComposerMentionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(candidates) { candidate in
                ComposerMentionRow(candidate: candidate) {
                    onSelect(candidate)
                }
                if candidate.id != candidates.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
        .shadow(color: WNColor.shadow.opacity(0.1), radius: 12, y: 4)
        .accessibilityIdentifier("composer.mentionPicker")
    }
}

private struct ComposerMentionRow: View {
    let candidate: ComposerMentionCandidate
    let onSelect: () -> Void

    @State private var isHovered = false

    private var shortNpub: String? {
        candidate.npub.isEmpty ? nil : DisplayText.short(candidate.npub)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ProfileImageAvatarView(
                    seed: candidate.accountIdHex,
                    initials: candidate.displayName,
                    sanitizedPictureURL: nil,
                    size: 26,
                    isSelected: false
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.displayName)
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                        .lineLimit(1)
                    // Under a private nickname, who the person actually publishes as says more
                    // about which of two similarly-nicknamed contacts this is than their npub.
                    if let subtitle = candidate.publishedDisplayName ?? shortNpub {
                        Text(subtitle)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(WNColor.fillTertiaryHover)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
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
    let onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
    let onSend: () -> Void

    /// The rung the composer is set at.
    static let typingStyle = WNTextStyle.medium14

    /// What a mention token is set in — the Bold face at the typing rung's own size, so a token
    /// and the words around it stay on one baseline and one measure however that rung moves.
    static let mentionStyle = WNTextStyle.custom(size: typingStyle.size, weight: .bold)

    /// Attributes typed text should carry when it is not part of a mention token. Reapplied after a
    /// mention is inserted so the token's chip and identity markers cannot bleed into what follows.
    static var plainTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: WNNSFont.font(for: Self.typingStyle),
            .kern: Self.typingStyle.tracking,
            .foregroundColor: WNNSColor.backgroundContentPrimary,
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
            onMentionContextChange: onMentionContextChange
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
        textView.font = WNNSFont.font(for: Self.typingStyle)
        textView.textColor = WNNSColor.backgroundContentPrimary
        textView.insertionPointColor = WNNSColor.backgroundContentPrimary
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
        context.coordinator.onMentionInsertionConsumed = onMentionInsertionConsumed
        context.coordinator.mentionSelections = $mentionSelections
        context.coordinator.onMentionContextChange = onMentionContextChange

        guard let textView = scrollView.documentView as? ComposerPasteInterceptingTextView else { return }
        configureHandlers(for: textView, coordinator: context.coordinator)
        textView.font = WNNSFont.font(for: Self.typingStyle)
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.scheduleMentionSynchronization(
            scope: mentionContextScope,
            insertion: mentionInsertion,
            in: textView
        )
        context.coordinator.scheduleEmojiInsertion(emojiInsertion, into: textView)
        DispatchQueue.main.async {
            context.coordinator.updateMeasuredHeight(for: textView)
        }
    }

    private func configureHandlers(for textView: ComposerPasteInterceptingTextView, coordinator: Coordinator) {
        textView.mediaPasteHandler = { [weak coordinator] in
            coordinator?.handleMediaPaste() ?? false
        }
        textView.returnKeySendHandler = { [weak coordinator] in
            coordinator?.onSend()
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
        private var lastEmojiInsertionID: UUID?
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
            onMentionContextChange: @escaping (ComposerMentionContext?) -> Void = { _ in }
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
        // The same treatment a rendered mention gets — bold, in the app's one blue — so a token
        // looks the same while you are typing it as it will once it is sent. See
        // `MentionTextPalette`.
        storage.addAttribute(
            .foregroundColor,
            value: MentionTextPalette.nsForeground,
            range: selection.range
        )
        storage.addAttribute(
            .font,
            value: WNNSFont.font(for: ComposerMessageTextViewRepresentable.mentionStyle),
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
private final class ComposerPasteInterceptingTextView: NSTextView {
    var mediaPasteHandler: (() -> Bool)?
    var returnKeySendHandler: (() -> Void)?

    override func paste(_ sender: Any?) {
        if mediaPasteHandler?() == true {
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
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

struct PendingMediaDraftStrip: View {
    let attachments: [PendingMediaAttachment]
    let uploadStates: [PendingMediaAttachment.ID: PendingMediaUploadState]
    let isSending: Bool
    let onRemove: (PendingMediaAttachment.ID) -> Void
    let onRetryUpload: (PendingMediaAttachment.ID) -> Void

    private let tileSize = CGSize(width: 74, height: 74)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
                            Button {
                                onRemove(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .wnFont(.semiBold18)
                                    .symbolRenderingMode(.palette)
                                    // Two-layer glyph: the inner disc is the surface it is
                                    // punched out of, the ring is content on that surface.
                                    .foregroundStyle(
                                        WNColor.backgroundPrimary, WNColor.backgroundContentSecondary)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.string("Remove attachment"))
                            .offset(x: 7, y: -7)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }
}

struct PendingMediaDraftTile: View {
    let attachment: PendingMediaAttachment
    let tileSize: CGSize
    let uploadState: PendingMediaUploadState?
    let onRetry: () -> Void

    @State private var decodedImagePreview: NSImage?
    @State private var decodedImageTaskID: String?

    var body: some View {
        Group {
            switch attachment.kind {
            case .image:
                imagePreview
                    .task(id: imagePreviewTaskID) {
                        await loadImagePreview()
                    }
            case .audio:
                audioPreview
            case .video, .file:
                filePreview
            }
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WNColor.fillSecondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if let uploadState {
                PendingMediaUploadStatusBadge(state: uploadState, onRetry: onRetry)
                    .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let image = decodedImagePreview {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel(attachment.fileName)
        } else {
            iconPreview(systemName: attachment.kind.systemImageName)
        }
    }

    private var imagePreviewTaskID: String {
        Self.previewTaskID(for: attachment, maxPixelSize: imagePreviewMaxPixelSize)
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

    private static func previewTaskID(for attachment: PendingMediaAttachment, maxPixelSize: CGFloat) -> String {
        "\(attachment.id.uuidString)|\(attachment.data.count)|\(Int(maxPixelSize))"
    }

    private var audioPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .wnFont(.semiBold16)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                ComposerAudioWaveformView(
                    samples: attachment.waveformSamples,
                    progress: 0,
                    barColor: WNColor.backgroundContentTertiary,
                    playedColor: WNColor.backgroundContentPrimary
                )
                .frame(height: 24)

                Text(attachment.durationLabel ?? attachment.sizeLabel)
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
    }

    private var filePreview: some View {
        VStack(spacing: 5) {
            Image(systemName: attachment.kind.systemImageName)
                .wnFont(.semiBold18)
            Text(attachment.fileName)
                .wnFont(.medium10)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(WNColor.backgroundContentSecondary)
        .padding(.horizontal, 8)
    }

    private func iconPreview(systemName: String) -> some View {
        Image(systemName: systemName)
            .wnFont(.semiBold20)
            .foregroundStyle(WNColor.backgroundContentSecondary)
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
                .tint(WNColor.backgroundContentPrimary)
                .scaleEffect(0.62)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: .circle)
                .shadow(color: WNColor.shadow.opacity(0.1), radius: 4, y: 1)
        case .uploaded:
            EmptyView()
        case .failed:
            Button(L10n.string("Retry upload"), systemImage: "arrow.clockwise", action: onRetry)
                .labelStyle(.iconOnly)
                .wnFont(.bold12)
                .foregroundStyle(WNColor.fillContentQuaternary)
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .background(WNColor.fillDestructive, in: .circle)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .help(L10n.string("Retry upload"))
        }
    }
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
    let samples: [CGFloat]
    let durationSeconds: Double
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ComposerAudioWaveformView(
                samples: samples,
                progress: 0,
                // Recording, so every bar is "live" rather than played — one token at full
                // strength. `backgroundContent*` rather than a fill token because the bars are
                // drawn straight onto the bar's own surface, and primary rather than the
                // destructive red this used to be: a recording in progress is the composer doing
                // what it was asked to, not an error. The voice-draft bar below uses the same two
                // tokens at two weights, so the two waveforms read as one control.
                barColor: WNColor.backgroundContentPrimary,
                playedColor: WNColor.backgroundContentPrimary,
                mode: .liveRecording
            )
            .frame(height: 30)

            Text(Self.durationLabel(durationSeconds))
                .wnFont(.semiBold10.monospacedDigit())
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(minWidth: 44, alignment: .trailing)

            // Stop is the only thing this bar asks for, so it wears the primary action's pair
            // (`fillPrimary` + `fillContentPrimary`) rather than the destructive one. Finishing a
            // recording keeps it — the trash can that throws it away lives in the voice-draft bar
            // this hands off to, and that is where the destructive color belongs.
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .wnFont(.bold12)
                    .foregroundStyle(WNColor.fillContentPrimary)
                    .frame(width: 30, height: 30)
                    .background(WNColor.fillPrimary, in: .circle)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Finish recording"))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
    }

    private static func durationLabel(_ duration: Double) -> String {
        MediaDurationLabel.string(for: duration)
    }
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
                Image(systemName: isPlaying || isPreparingPlayback ? "stop.fill" : "play.fill")
                    .wnFont(.bold14)
                    .frame(width: 30, height: 30)
                    .background {
                        MessagesCircleControlBackground()
                    }
            }
            .buttonStyle(.plain)
            .help(playbackActionLabel)
            // `help` becomes the tooltip, not the label: an icon-only button needs the action
            // spelled out or VoiceOver is left announcing the SF Symbol.
            .accessibilityLabel(playbackActionLabel)
            .accessibilityIdentifier("composer.voiceDraft.playback")

            // Unplayed bars are de-emphasized, played bars are full-strength content — the same
            // reading the transcript's audio rows use, so progress is legible as one hue at two
            // weights rather than two competing colors.
            ComposerAudioWaveformView(
                samples: attachment.waveformSamples,
                progress: playbackProgress,
                barColor: WNColor.backgroundContentTertiary,
                playedColor: WNColor.backgroundContentPrimary
            )
            .frame(height: 30)

            Text(MediaDurationLabel.string(for: isPlaying ? elapsedSeconds : (attachment.durationSeconds ?? 0)))
                .wnFont(.semiBold10.monospacedDigit())
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(minWidth: 44, alignment: .trailing)

            // Discard sits with Send rather than at the far left: the two decisions the bar asks
            // for — throw it away or send it — belong next to each other, past the recording.
            Button(action: discard) {
                Image(systemName: "trash")
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
                    .frame(width: 30, height: 30)
                    .background {
                        MessagesCircleControlBackground()
                    }
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .help(L10n.string("Delete recording"))
            .accessibilityIdentifier("composer.voiceDraft.delete")

            if uploadState == .failed {
                Button(L10n.string("Retry upload"), systemImage: "arrow.clockwise", action: onRetryUpload)
                    .labelStyle(.iconOnly)
                    .wnFont(.bold14)
                    .foregroundStyle(WNColor.fillContentQuaternary)
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 30)
                    .background(WNColor.fillDestructive, in: .circle)
                    .help(L10n.string("Retry upload"))
            }

            Button(action: send) {
                MessagesSendButtonLabel(
                    systemImage: "paperplane.fill",
                    isEnabled: canSend,
                    isSending: isSending
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(sendHelp)
            .accessibilityIdentifier("composer.voiceDraft.send")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
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

nonisolated enum ComposerAudioWaveformMode {
    case playback
    case liveRecording
}

nonisolated struct ComposerAudioWaveformBar: Equatable {
    let amplitude: CGFloat?
}

nonisolated enum ComposerAudioWaveformPresentation {
    static let amplitudeCurveExponent: Double = 0.45
    static let fallbackPlaybackBars = bars(for: MediaWaveformAnalyzer.fallbackSamples, mode: .playback)

    static func visiblePlaybackBars(
        loadedBars: [ComposerAudioWaveformBar],
        metadataPayloadID: String?,
        currentPayloadID: String
    ) -> [ComposerAudioWaveformBar] {
        metadataPayloadID == currentPayloadID ? loadedBars : fallbackPlaybackBars
    }

    static func bars(
        for samples: [CGFloat],
        mode: ComposerAudioWaveformMode,
        count: Int = MediaWaveformAnalyzer.sampleCount
    ) -> [ComposerAudioWaveformBar] {
        let targetCount = max(0, count)
        guard targetCount > 0 else { return [] }
        switch mode {
        case .playback:
            return MediaWaveformAnalyzer.normalized(samples, count: targetCount)
                .map(displayAmplitude)
                .map { ComposerAudioWaveformBar(amplitude: $0) }
        case .liveRecording:
            // Live recordings grow while the user speaks, so this path intentionally
            // recomputes from the current samples instead of caching a stale snapshot.
            let visibleSamples = samples.suffix(targetCount)
                .map(displayAmplitude)
                .map { ComposerAudioWaveformBar(amplitude: $0) }
            let blankCount = max(0, targetCount - visibleSamples.count)
            return Array(repeating: ComposerAudioWaveformBar(amplitude: nil), count: blankCount) + visibleSamples
        }
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

    // Convenience path for one-shot previews and live recording. Playback rows pass
    // precomputed bars so progress ticks only recolor already-prepared amplitudes.
    init(
        samples: [CGFloat],
        progress: CGFloat,
        barColor: Color,
        playedColor: Color,
        mode: ComposerAudioWaveformMode = .playback
    ) {
        self.init(
            bars: ComposerAudioWaveformPresentation.bars(for: samples, mode: mode),
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
        guard bar.amplitude != nil else { return .clear }
        let played = CGFloat(index) / CGFloat(max(1, count - 1)) <= progress
        return played ? playedColor : barColor
    }

    private func barHeight(for bar: ComposerAudioWaveformBar, in availableHeight: CGFloat) -> CGFloat {
        guard let amplitude = bar.amplitude else { return 4 }
        return max(4, availableHeight * min(1, max(0.08, amplitude)))
    }
}

struct TimelineInitialLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(L10n.string("Loading messages..."))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
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
                .fill(MessagesPalette.sentBubble)
                .frame(width: 4, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L10n.string("Replying to %@"), context.senderName))
                    .wnFont(.semiBold10)
                    .foregroundStyle(MessagesPalette.sentBubble)
                    .lineLimit(1)

                Text(context.body)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 12)

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .wnFont(.bold12)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background { MessagesCircleControlBackground() }
            .help(L10n.string("Cancel reply"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background { GlassRoundedBackground(cornerRadius: 12) }
    }
}

struct EditComposerContextView: View {
    let context: MessageEditContext

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .wnFont(.semiBold12)
                .foregroundStyle(MessagesPalette.sentBubble)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Editing message"))
                    .wnFont(.semiBold10)
                Text(context.originalBody)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { GlassRoundedBackground(cornerRadius: 12) }
    }
}

/// Replaces the composer for a group the local account left or was removed from:
/// the transcript stays readable, but the core would reject any send
/// (`invalid_transition`), so no input is offered.
struct MembershipEndedComposerNotice: View {
    let membership: ChatSelfMembership

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: membership.endedSymbolName ?? "")
                .wnFont(.semiBold14)
                .foregroundStyle(WNColor.backgroundContentSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(membership.endedDescription ?? "")
                    .wnFont(.semiBold12)

                Text(ChatSelfMembership.endedHistoryExplanation)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard()
        .accessibilityIdentifier("composer.membershipEnded")
    }
}

/// Replaces the composer until the user accepts or declines a pending group invite.
struct PendingGroupInviteComposerNotice: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.intentionInfoContent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(inviteMessage)
                        .wnFont(.semiBold12)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.string("If you decline, this chat will be removed from your chat list."))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await workspace.acceptGroupInvite(for: chat) }
                } label: {
                    HStack(spacing: 8) {
                        if workspace.isAcceptingGroupInvite {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text(workspace.isAcceptingGroupInvite ? L10n.string("Accepting...") : L10n.string("Accept"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .controlSize(.large)
                .nativeGlassProminentButtonStyle()
                .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                .help(L10n.string("Accept invite"))

                // No destructive `role`: `chat_invite_screen.dart` builds Decline as `outline`,
                // and the group-details Decline already dropped it. Marking it destructive while
                // rendering it secondary is a trap — see `WNSecondaryButtonStyle`.
                Button {
                    Task { await workspace.declineGroupInvite(for: chat) }
                } label: {
                    HStack(spacing: 8) {
                        if workspace.isDecliningGroupInvite {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                        Text(workspace.isDecliningGroupInvite ? L10n.string("Declining...") : L10n.string("Decline"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .controlSize(.large)
                .buttonStyle(.wnSecondary)
                .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                .help(L10n.string("Decline invite"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
        .accessibilityIdentifier("composer.pendingGroupInvite")
    }

    private var inviteMessage: String {
        String(format: L10n.string("%@ invited you to a secure chat."), inviterName)
    }

    private var inviterName: String {
        if let previewSender = previewSenderName {
            return previewSender
        }
        return L10n.string("Someone")
    }

    private var previewSenderName: String? {
        let preview = chat.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = preview.firstIndex(of: ":") else { return nil }
        let candidate = String(preview[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
            candidate != L10n.string("You"),
            candidate != chat.title
        else { return nil }
        return candidate
    }
}

struct ProfileImageAvatarView: View {
    @Environment(WorkspaceState.self) private var workspace
    let seed: String
    let initials: String
    /// Already passed through `RemoteImageURLPolicy`; body only checks the user preference.
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
            } else if workspace.loadRemoteImages, let imageURL = sanitizedPictureURL {
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
        let showsPicture = localImagePayload != nil || (workspace.loadRemoteImages && sanitizedPictureURL != nil)
        return showsPicture ? AvatarChromeModifier.neutralRing : AvatarPalette.colors(for: seed).border
    }
}

struct ConversationHeader: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem

    /// Under the chat title: the disappearing-message timer as a bare clock icon + duration (no
    /// "Disappearing messages:" label) when it's on, otherwise the usual member/DM subtitle.
    private var headerSubtitle: some View {
        let metadata = workspace.conversationMetadataByChat[chat.id]
        return DisappearingMessageHeaderSubtitle(
            durationSeconds: metadata?.disappearingMessageSecs,
            fallback: metadata?.subtitle ?? chat.subtitle
        )
        .wnFont(.medium10)
        .lineLimit(1)
    }

    var body: some View {
        @Bindable var workspace = workspace

        HStack(spacing: 10) {
            if workspace.isTimelineSelectionMode {
                Button {
                    workspace.cancelMessageSelection()
                } label: {
                    Image(systemName: "xmark")
                        .wnFont(.bold14)
                        .frame(width: 40, height: 40)
                        .background { MessagesCircleControlBackground() }
                }
                .buttonStyle(.plain)
                .help(L10n.string("Cancel selection"))

                Text(
                    String(
                        format: L10n.string("%d selected"),
                        workspace.selectedTimelineMessageIds.count
                    )
                )
                .wnFont(.semiBold16)

                Spacer()
            } else {
                // Tapping the avatar or title opens the chat info / settings panel,
                // which slides in over the transcript (see ConversationView).
                Button {
                    Task { await workspace.showGroupDetails(for: chat) }
                } label: {
                    HStack(spacing: 10) {
                        ProfileImageAvatarView(
                            seed: chat.avatarSeed,
                            initials: chat.title,
                            sanitizedPictureURL: chat.sanitizedPictureURL,
                            localImagePayload: chat.groupImagePayload,
                            size: 38,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title)
                                .wnFont(.semiBold16)
                                .lineLimit(1)
                                .foregroundStyle(WNColor.backgroundContentPrimary)

                            headerSubtitle
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("Chat info"))

                Spacer()

                // Changing the group image is a send (commit) under the hood, which the
                // core rejects until the invite is accepted, or once the local account is
                // no longer a member.
                if !chat.isDirect && chat.canUseComposer {
                    Button {
                        workspace.showGroupImagePicker(for: chat)
                    } label: {
                        Image(systemName: "photo.badge.plus")
                            .wnFont(.semiBold16)
                            .frame(width: 34, height: 34)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Set group image"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .frame(height: 76)
        .background {
            MessagesHeaderBackground()
        }
        .sheet(isPresented: $workspace.isGroupImagePickerPresented) {
            GroupImagePickerSheet()
        }
    }
}

struct MessageSelectionToolbar: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        let messages = workspace.selectedTimelineMessagesForAction
        let canForward = messages.contains(where: \.canForward)
        let canDelete = messages.contains(where: workspace.canDeleteMessage)

        HStack(spacing: 12) {
            Text(
                String(
                    format: L10n.string("%d selected"),
                    workspace.selectedTimelineMessageIds.count
                )
            )
            .wnFont(.semiBold12)

            Spacer()

            Button {
                workspace.startForwarding(messages)
            } label: {
                Label(L10n.string("Forward"), systemImage: "arrowshape.turn.up.right")
                    .frame(minWidth: 40, minHeight: 40)
            }
            .buttonStyle(.plain)
            .disabled(!canForward)

            Button(role: .destructive) {
                Task { await workspace.deleteSelectedMessages() }
            } label: {
                Label(L10n.string("Delete"), systemImage: "trash")
                    .frame(minWidth: 40, minHeight: 40)
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
        }
        .frame(minHeight: 42)
    }
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

struct MessageForwardSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var query = ""

    var body: some View {
        let targets = workspace.activeChats.filter { chat in
            let searchMatches = query.isEmpty || chat.title.localizedCaseInsensitiveContains(query)
            return chat.canUseComposer && searchMatches
        }

        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Forward To"))
                    .wnFont(.semiBold16)
                Spacer()
                Button {
                    workspace.cancelForwarding()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                TextField(L10n.string("Search chats"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(targets) { chat in
                        Button {
                            Task { await workspace.forwardPendingMessages(to: chat) }
                        } label: {
                            HStack(spacing: 12) {
                                ProfileImageAvatarView(
                                    seed: chat.avatarSeed,
                                    initials: chat.title,
                                    sanitizedPictureURL: chat.sanitizedPictureURL,
                                    localImagePayload: chat.groupImagePayload,
                                    size: 34,
                                    isSelected: false
                                )
                                Text(chat.title)
                                    .lineLimit(1)
                                Spacer()
                                if workspace.isForwardingMessages {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrowshape.turn.up.right")
                                        .foregroundStyle(WNColor.backgroundContentSecondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.isForwardingMessages)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 420, height: 520)
    }
}
