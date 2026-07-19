//
//  MessageMediaViews.swift
//  whitenoise-mac
//
//  Message rendering and media subsystem: message rows, MessageBubble,
//  visual-media grids/tiles, attachment rows, audio/video players, the
//  image gallery overlay, and inline message actions/reactions. Extracted
//  verbatim from MessengerShellView.swift (no behavior change).
//

import AVFoundation
import AVKit
import AppKit
import SwiftUI

/// Oversample factor applied to media thumbnails over their display-point size.
/// Because tiles use `scaledToFill` (which crops to the center square), a source
/// whose aspect ratio is `r:1` needs `r×` the display pixels on its shorter side
/// to stay crisp. 1.5 keeps the common 4:3/3:2 photo ratios sharp while decoding
/// ~44% fewer pixels than the previous 2× factor, which also lets ~2× more tiles
/// fit in the cost-bounded decoded-image cache.
private let mediaThumbnailOversample: CGFloat = 1.5

/// Per-conversation hover-selection gate. Bubbles register a local `isSelectable` binding;
/// `activate` flips only the previous and newly active bubble so hover does not invalidate
/// the non-lazy transcript `ForEach` parent (whitenoise-mac#397). SwiftUI calls this from
/// main-thread view lifecycle / hover callbacks; it intentionally publishes no observable
/// state back to `ConversationView`.
final class ConversationHoverSelectionCoordinator {
    private var activeMessageID: String?
    private var registrations: [String: Binding<Bool>] = [:]

    func register(messageID: String, isSelectable: Binding<Bool>) {
        registrations[messageID] = isSelectable
        isSelectable.wrappedValue = activeMessageID == messageID
    }

    func unregister(messageID: String) {
        if activeMessageID == messageID {
            activeMessageID = nil
        }
        registrations.removeValue(forKey: messageID)
    }

    func activate(messageID: String) {
        guard activeMessageID != messageID else { return }
        if let previousID = activeMessageID {
            registrations[previousID]?.wrappedValue = false
        }
        activeMessageID = messageID
        registrations[messageID]?.wrappedValue = true
    }

    func reset() {
        if let activeMessageID {
            registrations[activeMessageID]?.wrappedValue = false
        }
        activeMessageID = nil
    }
}

private struct ConversationHoverSelectionCoordinatorKey: EnvironmentKey {
    static let defaultValue = ConversationHoverSelectionCoordinator()
}

extension EnvironmentValues {
    var conversationHoverSelectionCoordinator: ConversationHoverSelectionCoordinator {
        get { self[ConversationHoverSelectionCoordinatorKey.self] }
        set { self[ConversationHoverSelectionCoordinatorKey.self] = newValue }
    }
}

struct ConversationMessageRow: View {
    let message: MessageItem
    var showsDebugMetadata = false
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void
    let onNavigateToMessage: (String) -> Void

    // Receives the resolved MessageItem by value (not via a shared @Observable lookup),
    // so SwiftUI diffs each row by value and only re-runs the rows that actually changed
    // instead of invalidating every visible row on each page load / streaming update.
    var body: some View {
        if message.presentation.isChatBubble {
            MessageBubble(
                message: message,
                showsDebugMetadata: showsDebugMetadata,
                onOpenImageGallery: onOpenImageGallery,
                onNavigateToMessage: onNavigateToMessage
            )
        } else {
            TimelineNoticeRow(message: message, showsDebugMetadata: showsDebugMetadata)
        }
    }
}

struct TimelineNoticeRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let showsDebugMetadata: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 24)

            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: message.presentation.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)

                    Text(message.body)
                        .font(.caption.weight(.medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)

                    Text(message.timeLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if showsDebugMetadata {
                    MessageDebugMetadataView(message: message, isOutgoing: false)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                GlassCapsuleBackground()
            }
            .frame(maxWidth: 520)
            .contextMenu {
                Button {
                    workspace.copyText(of: message)
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }

            Spacer(minLength: 24)
        }
    }
}

struct MessageBubble: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.conversationHoverSelectionCoordinator) private var hoverSelectionCoordinator
    @State private var isHovering = false
    @State private var isInlineActionPresentationActive = false
    @State private var isSelectable = false
    @State private var isReactionSummaryPresented = false
    let message: MessageItem
    let showsDebugMetadata: Bool
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void
    let onNavigateToMessage: (String) -> Void

    var body: some View {
        // Alignment is done with a fill-frame + opposite-side padding rather than the old
        // `HStack { Spacer(minLength: 72); … }`. Two flexible `Spacer`s plus the nested
        // `maxWidth` frames formed an underdetermined flexible-width system that SwiftUI
        // re-solved on every `sizeThatFits` — and the transcript's lazy stack issues dozens
        // of those per row while resolving the bottom scroll anchor. Frame-alignment is a
        // single deterministic pass with the same result: bubble pinned to its side, ≥72pt
        // gutter opposite. See whitenoise-mac#205 (scroll-layout hangs).
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
            if !message.isOutgoing {
                Text(message.senderName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !message.visualMediaAttachments.isEmpty {
                MessageVisualMediaGrid(
                    message: message,
                    attachments: message.visualMediaAttachments,
                    isOutgoing: message.isOutgoing,
                    onOpenImageGallery: onOpenImageGallery
                )
            }

            ForEach(message.nonvisualMediaAttachments) { attachment in
                MessageMediaAttachmentView(
                    downloadState: workspace.mediaDownloadStateStore(for: message, attachment: attachment),
                    message: message,
                    attachment: attachment,
                    isOutgoing: message.isOutgoing
                )
            }

            if showsDebugMetadata || message.hasBubbleContent {
                bubbleContent
            }

            if !message.hasBubbleContent {
                compactMetadata
                    .padding(.horizontal, 5)
            }

            if message.supportsChatActions && !message.reactions.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(message.reactions.prefix(5))) { reaction in
                        Button {
                            Task {
                                if reaction.canRemoveOwnReaction {
                                    await workspace.removeReaction(reaction, from: message)
                                } else {
                                    await workspace.react(to: message, emoji: reaction.emoji)
                                }
                            }
                        } label: {
                            Text(reaction.label)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background {
                                    GlassCapsuleBackground(
                                        borderColor: reaction.canRemoveOwnReaction
                                            ? MessagesPalette.sentBubble.opacity(0.45) : Color.white.opacity(0.18)
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .help(
                            reaction.canRemoveOwnReaction
                                ? "Remove \(reaction.emoji) reaction" : "React with \(reaction.emoji)")
                    }
                    if message.reactions.count > 5 {
                        Button("+\(message.reactions.count - 5)") {
                            isReactionSummaryPresented = true
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background { GlassCapsuleBackground() }
                        .popover(isPresented: $isReactionSummaryPresented, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.string("Reactions"))
                                    .font(.headline)
                                ScrollView {
                                    LazyVStack(spacing: 8) {
                                        ForEach(message.reactions) { reaction in
                                            reactionSummaryRow(reaction)
                                        }
                                    }
                                }
                                .frame(maxHeight: 260)
                            }
                            .padding(14)
                            .frame(width: 220)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            if !usesBubbleSurface {
                inlineActions
            }
        }
        .overlay(alignment: .leading) {
            if workspace.isTimelineSelectionMode {
                Button {
                    workspace.toggleMessageSelection(message)
                } label: {
                    Image(
                        systemName: workspace.selectedTimelineMessageIds.contains(message.id)
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(
                        workspace.selectedTimelineMessageIds.contains(message.id)
                            ? Color.accentColor : Color.secondary
                    )
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    workspace.selectedTimelineMessageIds.contains(message.id)
                        ? L10n.string("Deselect message") : L10n.string("Select message")
                )
            }
        }
        .animation(.smooth(duration: 0.12), value: showsInlineActions)
        .frame(maxWidth: 660, alignment: message.isOutgoing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .padding(message.isOutgoing ? .leading : .trailing, 72)
        .contentShape(Rectangle())
        .contextMenu {
            if !workspace.isTimelineSelectionMode {
                MessageContextMenuItems(message: message)
            }
        }
        .onTapGesture {
            if workspace.isTimelineSelectionMode {
                workspace.toggleMessageSelection(message)
            }
        }
        .onAppear {
            hoverSelectionCoordinator.register(messageID: message.id, isSelectable: $isSelectable)
        }
        .onDisappear {
            hoverSelectionCoordinator.unregister(messageID: message.id)
        }
        .onHover { hovering in
            isHovering = hovering
            // Make this the active (selectable) bubble on hover-enter; do NOT clear on
            // exit, so the selection survives moving the cursor toward ⌘C / the menu bar.
            if hovering {
                hoverSelectionCoordinator.activate(messageID: message.id)
            }
        }
    }

    private var showsInlineActions: Bool {
        message.supportsChatActions && (isHovering || isInlineActionPresentationActive)
    }

    @ViewBuilder
    private func reactionSummaryRow(_ reaction: MessageReaction) -> some View {
        if reaction.canRemoveOwnReaction {
            Button {
                Task {
                    await workspace.removeReaction(reaction, from: message)
                    isReactionSummaryPresented = false
                }
            } label: {
                reactionSummaryLabel(reaction)
            }
            .buttonStyle(.plain)
            .help(String(format: L10n.string("Remove %@ reaction"), reaction.emoji))
        } else {
            reactionSummaryLabel(reaction)
        }
    }

    private func reactionSummaryLabel(_ reaction: MessageReaction) -> some View {
        HStack {
            Text(reaction.emoji)
            Text("\(reaction.count)")
                .foregroundStyle(.secondary)
            Spacer()
            if reaction.canRemoveOwnReaction {
                Text(L10n.string("You"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var usesBubbleSurface: Bool {
        showsDebugMetadata || message.hasBubbleContent
    }

    @ViewBuilder
    private var inlineActions: some View {
        if showsInlineActions {
            MessageInlineActions(
                isPresentationActive: $isInlineActionPresentationActive,
                message: message
            )
            .offset(x: message.isOutgoing ? -inlineActionOffset : inlineActionOffset)
            .transition(
                .opacity.combined(
                    with: .scale(
                        scale: 0.96,
                        anchor: message.isOutgoing ? .trailing : .leading
                    )))
        }
    }

    private var inlineActionOffset: CGFloat {
        var actionCount = 0
        actionCount += message.canReact ? 1 : 0
        actionCount += message.canReply ? 1 : 0
        actionCount += message.supportsChatActions ? 1 : 0

        let controlWidth = CGFloat(actionCount) * 40
        let spacingWidth = CGFloat(max(actionCount - 1, 0)) * 4
        return controlWidth + spacingWidth + 8
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsDebugMetadata {
                MessageDebugMetadataView(message: message, isOutgoing: message.isOutgoing)
            }

            if let replyContext = message.replyContext {
                MessageReplyContextView(
                    context: replyContext,
                    isOutgoing: message.isOutgoing,
                    onOpen: { onNavigateToMessage(replyContext.targetMessageId) }
                )
            }

            if !message.trimmedBody.isEmpty {
                MarkdownMessageView(
                    message: message,
                    trailingMetadata: showsInlineMetadata ? inlineMetadataText : nil
                )
                .font(.system(size: 15.5))
                .foregroundStyle(message.isOutgoing ? .white : .primary)
                .multilineTextAlignment(.leading)
            }

            if showsSeparateMetadata {
                compactMetadata
            }
        }
        // One hover-gated selection gate for the whole bubble: `.textSelection(.enabled)`
        // propagates through the environment to the body + reply-quote Text, so only the
        // active bubble (`isSelectable`) is backed by a selection NSView. Non-active bubbles
        // get no modifier (Text is non-selectable by default). See whitenoise-mac#205.
        .textSelectable(isSelectable)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background { BubbleBackground(isOutgoing: message.isOutgoing) }
        // Attach controls before the positioning frame so short messages use the visible
        // bubble edge instead of the frame's maximum width.
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            inlineActions
        }
        .frame(maxWidth: 540, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var showsInlineMetadata: Bool {
        !message.isDeleted && !showsDebugMetadata && message.supportsInlineMetadata
    }

    private var showsSeparateMetadata: Bool {
        !message.isDeleted && (!showsInlineMetadata || message.trimmedBody.isEmpty)
    }

    private var inlineMetadataText: Text {
        let color = metadataColor
        var result = Text("  ")
        if message.isEdited {
            result =
                result
                + Text("Edited ")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(color)
        }
        result =
            result
            + Text(message.timeLabel)
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundColor(color)
        if message.invalidationStatus != nil {
            result =
                result + Text(" ")
                + Text(Image(systemName: "exclamationmark.circle.fill"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.red)
        } else if message.isOutgoing {
            result =
                result + Text(" ")
                + Text(Image(systemName: "checkmark"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(color)
        }
        return result
    }

    private var metadataColor: Color {
        message.isOutgoing && message.hasBubbleContent
            ? Color.white.opacity(0.68) : Color.secondary.opacity(0.72)
    }

    private var compactMetadata: some View {
        HStack(spacing: 4) {
            if message.isEdited {
                Text("Edited")
            }
            Text(message.timeLabel)
                .monospacedDigit()
            if message.invalidationStatus != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else if message.isOutgoing {
                Image(systemName: "checkmark")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(metadataColor)
        .accessibilityLabel(message.metadataLabel)
    }
}

private extension View {
    /// Enable text selection only when `enabled`. `.textSelection(.enabled)` and `.disabled`
    /// are distinct types (so a ternary won't type-check); a plain `Text` is non-selectable
    /// by default, so the inactive case simply applies no modifier.
    @ViewBuilder
    func textSelectable(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            self
        }
    }

    func attachmentRowChrome(isOutgoing: Bool) -> some View {
        foregroundStyle(isOutgoing ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 260, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOutgoing ? Color.white.opacity(0.12) : Color.primary.opacity(0.06))
            }
    }

    func autoDownloadMediaAttachment(
        _ downloadState: MediaDownloadStateStore,
        attachment: MessageMediaAttachment,
        message: MessageItem,
        requiresScrollVisibility: Bool = true
    ) -> some View {
        modifier(
            AutomaticMediaDownloadModifier(
                downloadState: downloadState,
                attachment: attachment,
                message: message,
                requiresScrollVisibility: requiresScrollVisibility
            )
        )
    }
}

private struct AutomaticMediaDownloadModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    let downloadState: MediaDownloadStateStore
    let attachment: MessageMediaAttachment
    let message: MessageItem
    let requiresScrollVisibility: Bool
    @State private var isVisibleInScrollView = false
    @State private var automaticDownloadTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        Group {
            if requiresScrollVisibility {
                content
                    // A tiny non-zero threshold means eager, non-lazy transcript rows do not
                    // auto-download until at least part of the tile intersects the ScrollView.
                    .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                        isVisibleInScrollView = isVisible
                        if isVisible {
                            startAutomaticDownloadIfNeeded()
                        } else {
                            cancelAutomaticDownload()
                        }
                    }
            } else {
                content
                    .onAppear {
                        startAutomaticDownloadIfNeeded()
                    }
            }
        }
        .onChange(of: attachment.id) { _, _ in
            cancelAutomaticDownload()
            if shouldStartForCurrentVisibility {
                startAutomaticDownloadIfNeeded()
            }
        }
        .onChange(of: downloadState.shouldStartAutomaticDownload) { _, shouldStart in
            if shouldStart, shouldStartForCurrentVisibility {
                startAutomaticDownloadIfNeeded()
            }
        }
        .onDisappear {
            cancelAutomaticDownload()
        }
    }

    private var shouldStartForCurrentVisibility: Bool {
        !requiresScrollVisibility || isVisibleInScrollView
    }

    private func startAutomaticDownloadIfNeeded() {
        guard downloadState.shouldStartAutomaticDownload else { return }
        automaticDownloadTask?.cancel()
        automaticDownloadTask = Task {
            await workspace.loadMediaAttachment(attachment, for: message)
        }
    }

    private func cancelAutomaticDownload() {
        automaticDownloadTask?.cancel()
        automaticDownloadTask = nil
    }
}

/// The chat-bubble shape: a rounded rectangle with the trailing/leading bottom corner
/// tucked in on the sender's side. Outgoing bubbles use the accent fill; incoming bubbles
/// use a scheme-aware translucent fill with a hairline stroke.
private struct BubbleBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let isOutgoing: Bool

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: isOutgoing ? 20 : 6,
            bottomTrailingRadius: isOutgoing ? 6 : 20,
            topTrailingRadius: 20,
            style: .continuous
        )

        if isOutgoing {
            shape.fill(MessagesPalette.sentBubble)
        } else {
            shape
                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                .overlay {
                    shape.stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.24), lineWidth: 1)
                }
        }
    }
}

struct MessageImageGalleryPresentation: Identifiable, Equatable {
    let id: String
    let message: MessageItem
    let imageAttachments: [MessageMediaAttachment]
    let initialIndex: Int

    init?(message: MessageItem, initialAttachment: MessageMediaAttachment) {
        let imageAttachments = message.mediaAttachments.filter { $0.kind == .image }
        guard !imageAttachments.isEmpty else { return nil }
        self.id = "\(message.id)-image-gallery"
        self.message = message
        self.imageAttachments = imageAttachments
        self.initialIndex = imageAttachments.firstIndex(of: initialAttachment) ?? 0
    }
}

enum MessageVisualMediaTileTapAction: Equatable {
    case retryDownload
    case openImageGallery
    case none
}

enum MessageVisualMediaTileInteraction {
    static func tapAction(
        downloadState: MediaDownloadState,
        attachmentKind: MessageMediaKind
    ) -> MessageVisualMediaTileTapAction {
        if case .failed = downloadState { return .retryDownload }
        return attachmentKind == .image ? .openImageGallery : .none
    }
}

struct MessageVisualMediaGrid: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let attachments: [MessageMediaAttachment]
    let isOutgoing: Bool
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    private let maxWidth: CGFloat = 360
    private let spacing: CGFloat = 3
    private let cornerRadius: CGFloat = 10

    private var visibleAttachments: [MessageMediaAttachment] {
        Array(attachments.prefix(MessageMediaGridPresentation.visibleCount(totalCount: attachments.count)))
    }

    private var hiddenCount: Int {
        MessageMediaGridPresentation.hiddenCount(totalCount: attachments.count)
    }

    private var columnCount: Int {
        MessageMediaGridPresentation.columnCount(totalCount: attachments.count)
    }

    private var tileSide: CGFloat {
        MessageMediaGridPresentation.tileSide(totalCount: attachments.count, maxWidth: maxWidth, spacing: spacing)
    }

    private var gridHeight: CGFloat {
        MessageMediaGridPresentation.gridHeight(totalCount: attachments.count, maxWidth: maxWidth, spacing: spacing)
    }

    /// The visible attachments laid out row-major into `columnCount`-wide rows. Iterating
    /// this (keyed by `attachment.id`) instead of `ForEach(0..<columnCount)` over grid
    /// positions ties each tile's SwiftUI identity to its attachment, so a slot that comes
    /// to hold a different attachment gets a fresh tile/player rather than reusing the
    /// previous attachment's `@State` (and its decrypted scratch file). See #339.
    private var rows: [[MessageMediaAttachment]] {
        guard columnCount > 1 else { return visibleAttachments.map { [$0] } }
        return stride(from: 0, to: visibleAttachments.count, by: columnCount).map { start in
            Array(visibleAttachments[start..<min(start + columnCount, visibleAttachments.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { attachment in
                        tile(for: attachment)
                    }
                    // Pad a short trailing row (e.g. 3 attachments in a 2×2 grid) so tiles
                    // keep their square width instead of stretching to fill the row.
                    if row.count < columnCount {
                        Color.clear
                            .frame(width: tileSide, height: tileSide)
                    }
                }
            }
        }
        .frame(width: maxWidth, height: gridHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isOutgoing ? 0.16 : 0.1), lineWidth: 1)
        }
    }

    private func tile(for attachment: MessageMediaAttachment) -> some View {
        let isLastVisible = attachment.id == visibleAttachments.last?.id
        return MessageVisualMediaTile(
            downloadState: workspace.mediaDownloadStateStore(for: message, attachment: attachment),
            message: message,
            attachment: attachment,
            isOutgoing: isOutgoing,
            sideLength: tileSide,
            hiddenCount: isLastVisible ? hiddenCount : 0,
            onOpenImageGallery: onOpenImageGallery
        )
    }
}

struct MessageVisualMediaTile: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    let downloadState: MediaDownloadStateStore
    let message: MessageItem
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool
    let sideLength: CGFloat
    let hiddenCount: Int
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    var body: some View {
        ZStack {
            content

            if hiddenCount > 0 {
                Color.black.opacity(0.46)
                Text("+\(hiddenCount)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
        .clipped()
        .autoDownloadMediaAttachment(
            downloadState,
            attachment: attachment,
            message: message
        )
        .onTapGesture {
            switch MessageVisualMediaTileInteraction.tapAction(
                downloadState: downloadState.state,
                attachmentKind: attachment.kind
            ) {
            case .retryDownload:
                Task { await workspace.loadMediaAttachment(attachment, for: message) }
            case .openImageGallery:
                if let gallery = MessageImageGalleryPresentation(
                    message: message,
                    initialAttachment: attachment
                ) {
                    onOpenImageGallery(gallery)
                }
            case .none:
                break
            }
        }
        .accessibilityIdentifier("message.media.visualTile.\(attachment.id)")
    }

    @ViewBuilder
    private var content: some View {
        switch downloadState.state {
        case .idle, .loading:
            placeholder(systemImage: attachment.kind == .video ? "play.rectangle" : "photo", isLoading: true)
        case .failed:
            placeholder(systemImage: "arrow.clockwise", isLoading: false)
        case .loaded(let download):
            switch attachment.kind {
            case .image:
                DownsampledDataImage(
                    payload: download.payload,
                    maxPixelSize: sideLength * max(1, displayScale) * mediaThumbnailOversample
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: sideLength, height: sideLength)
                        .clipped()
                        .accessibilityLabel(attachment.fileName)
                } placeholder: {
                    placeholder(systemImage: "photo", isLoading: false)
                }
            case .video:
                MessageVideoAttachmentPlayer(
                    download: download,
                    attachment: attachment,
                    isOutgoing: isOutgoing,
                    sideLength: sideLength
                )
            case .audio, .file:
                placeholder(systemImage: attachment.kind.systemImageName, isLoading: false)
            }
        }
    }

    private func placeholder(systemImage: String, isLoading: Bool) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MessageMediaAttachmentView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    let downloadState: MediaDownloadStateStore
    let message: MessageItem
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool

    var body: some View {
        Group {
            switch downloadState.state {
            case .idle, .loading:
                MessageAttachmentStatusRow(
                    systemImage: "arrow.down.circle",
                    title: attachment.fileName,
                    detail: attachment.mediaType,
                    isOutgoing: isOutgoing,
                    isLoading: true
                )
            case .loaded(let download):
                loadedContent(download)
            case .failed:
                MessageAttachmentStatusRow(
                    systemImage: "exclamationmark.triangle",
                    title: attachment.fileName,
                    detail: L10n.string("Attachment unavailable"),
                    isOutgoing: isOutgoing,
                    isLoading: false
                ) {
                    Task { await workspace.loadMediaAttachment(attachment, for: message) }
                }
            }
        }
        .autoDownloadMediaAttachment(
            downloadState,
            attachment: attachment,
            message: message
        )
        .accessibilityIdentifier("message.media.attachment.\(attachment.id)")
    }

    @ViewBuilder
    private func loadedContent(_ download: MessageMediaDownload) -> some View {
        switch attachment.kind {
        case .image:
            DownsampledDataImage(
                payload: download.payload,
                maxPixelSize: 260 * max(1, displayScale) * mediaThumbnailOversample
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 260, height: 260)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(attachment.fileName)
            } placeholder: {
                MessageAttachmentStatusRow(
                    systemImage: "photo",
                    title: download.fileName.nilIfBlank ?? attachment.fileName,
                    detail: mediaDetail(download),
                    isOutgoing: isOutgoing
                )
            }
        case .audio:
            MessageAudioAttachmentPlayer(
                download: download,
                fallbackFileName: attachment.fileName,
                isOutgoing: isOutgoing
            )
        case .video:
            MessageVideoAttachmentPlayer(
                download: download,
                attachment: attachment,
                isOutgoing: isOutgoing,
                sideLength: 260
            )
        case .file:
            MessageDocumentAttachmentRow(
                download: download,
                attachment: attachment,
                isOutgoing: isOutgoing
            )
        }
    }

    private func mediaDetail(_ download: MessageMediaDownload) -> String {
        download.detailText(fallbackMediaType: attachment.mediaType)
    }
}

struct MessageDocumentAttachmentRow: View {
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool

    var body: some View {
        MessageAttachmentStatusRow(
            systemImage: "doc",
            title: download.fileName.nilIfBlank ?? attachment.fileName,
            detail: mediaDetail,
            isOutgoing: isOutgoing
        ) {
            Task { await openAttachment() }
        }
    }

    private var mediaDetail: String {
        download.detailText(fallbackMediaType: attachment.mediaType)
    }

    @MainActor
    private func openAttachment() async {
        guard
            let url = await MessageMediaPlaybackFileStore.fileURL(
                attachment: attachment,
                download: download
            )
        else { return }
        // `open` returns once LaunchServices accepts the handoff; the receiving app may
        // still be reading the file. Delete shortly after so we don't leave decrypted
        // plaintext on disk, while giving the app a brief window to read the bytes.
        let didOpen = NSWorkspace.shared.open(url)
        let cleanupDelay: TimeInterval = didOpen ? cleanupDelaySeconds : 0
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cleanupDelay) {
            MediaPlaybackTempStore.remove(at: url)
        }
    }

    private var cleanupDelaySeconds: TimeInterval { 30 }
}

struct MessageAttachmentStatusRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let isOutgoing: Bool
    var isLoading = false
    var retryAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 30, height: 30)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isOutgoing ? Color.white : Color.primary)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.72) : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retryAction {
                Button(action: retryAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(L10n.string("Retry"))
            }
        }
        .attachmentRowChrome(isOutgoing: isOutgoing)
    }

    private var iconBackground: Color {
        isOutgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)
    }
}

struct PreparedMessageAudioPlayer: @unchecked Sendable {
    let player: AVAudioPlayer
}

@MainActor
final class MessageAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onDidFinishPlaying: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        player.currentTime = 0
        onDidFinishPlaying?()
    }
}

struct MessageAudioAttachmentPlayer: View {
    let download: MessageMediaDownload
    let fallbackFileName: String
    let isOutgoing: Bool
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackPreparationID: UUID?
    @State private var playbackProgress: CGFloat = 0
    @State private var metadata: MediaWaveformAnalyzer.Metadata?
    @State private var metadataPayloadID: String?
    @State private var waveformBars = ComposerAudioWaveformPresentation.fallbackPlaybackBars
    @State private var playbackMonitor: Task<Void, Never>?
    @State private var audioPlayerDelegate = MessageAudioPlayerDelegate()

    private var isPreparingPlayback: Bool {
        playbackPreparationID != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Image(systemName: isPlaying || isPreparingPlayback ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(isOutgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
            .help(isPlaying || isPreparingPlayback ? L10n.string("Stop") : L10n.string("Play"))

            VStack(alignment: .leading, spacing: 2) {
                Text(download.fileName.nilIfBlank ?? fallbackFileName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    ComposerAudioWaveformView(
                        bars: visibleWaveformBars,
                        progress: playbackProgress,
                        barColor: isOutgoing ? Color.white.opacity(0.42) : Color.secondary.opacity(0.55),
                        playedColor: isOutgoing ? Color.white.opacity(0.9) : Color.accentColor
                    )
                    .frame(height: 24)

                    Text(durationLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.72) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .attachmentRowChrome(isOutgoing: isOutgoing)
        .onDisappear {
            stopPlayback()
        }
        // The prepared `AVAudioPlayer` is built from a specific payload's bytes; if this
        // view's identity outlives a change of `download.payload.id` (e.g. an edited or
        // progressively updated attachment), drop the stale player so `startPlayback`
        // rebuilds it for the new payload instead of replaying the previous one. See #339.
        .onChange(of: download.payload.id) { _, _ in
            stopPlayback()
            player = nil
        }
        .task(id: download.payload.id) {
            let payloadID = download.payload.id
            if metadataPayloadID != payloadID {
                metadata = nil
                waveformBars = ComposerAudioWaveformPresentation.fallbackPlaybackBars
            }
            let loaded = await MessageAudioMetadataCache.shared.metadata(for: download)
            let loadedWaveformBars = ComposerAudioWaveformPresentation.bars(
                for: loaded.samples,
                mode: .playback
            )
            guard !Task.isCancelled else { return }
            metadata = loaded
            metadataPayloadID = payloadID
            waveformBars = loadedWaveformBars
        }
    }

    private var visibleMetadata: MediaWaveformAnalyzer.Metadata? {
        metadataPayloadID == download.payload.id ? metadata : nil
    }

    private var visibleWaveformBars: [ComposerAudioWaveformBar] {
        ComposerAudioWaveformPresentation.visiblePlaybackBars(
            loadedBars: waveformBars,
            metadataPayloadID: metadataPayloadID,
            currentPayloadID: download.payload.id
        )
    }

    private var durationLabel: String {
        if let durationSeconds = visibleMetadata?.durationSeconds {
            return MediaDurationLabel.string(for: durationSeconds)
        }
        return download.sizeLabel
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
                let data = download.payload.data
                let nextPreparationID = UUID()
                preparationID = nextPreparationID
                playbackPreparationID = nextPreparationID
                let preparedPlayer = try await Task.detached(priority: .userInitiated) {
                    let audioPlayer = try AVAudioPlayer(data: data)
                    audioPlayer.prepareToPlay()
                    return PreparedMessageAudioPlayer(player: audioPlayer)
                }.value.player
                guard playbackPreparationID == nextPreparationID else { return }
                playbackPreparationID = nil
                player = preparedPlayer
                preparedPlayer.delegate = audioPlayerDelegate
            }
            audioPlayerDelegate.onDidFinishPlaying = handlePlaybackFinished
            player?.play()
            isPlaying = true
            updatePlaybackProgress()
            monitorPlaybackProgress()
        } catch {
            if preparationID == nil || playbackPreparationID == preparationID {
                playbackPreparationID = nil
                isPlaying = false
            }
        }
    }

    private func stopPlayback() {
        playbackPreparationID = nil
        audioPlayerDelegate.onDidFinishPlaying = nil
        player?.stop()
        player?.currentTime = 0
        finishPlayback()
    }

    private func handlePlaybackFinished() {
        finishPlayback()
    }

    private func finishPlayback() {
        playbackMonitor?.cancel()
        playbackMonitor = nil
        isPlaying = false
        playbackProgress = 0
    }

    private func monitorPlaybackProgress() {
        playbackMonitor?.cancel()
        playbackMonitor = Task { @MainActor in
            while !Task.isCancelled, isPlaying {
                updatePlaybackProgress()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func updatePlaybackProgress() {
        guard let player, player.duration > 0 else {
            playbackProgress = 0
            return
        }
        playbackProgress = min(1, max(0, CGFloat(player.currentTime / player.duration)))
    }
}

struct MessageVideoAttachmentPlayer: View {
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool
    let sideLength: CGFloat

    @State private var player: AVPlayer?
    @State private var playbackURL: URL?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var playbackPreparationID: UUID?
    @State private var playbackTask: Task<Void, Never>?
    @State private var endOfPlaybackObserver: NSObjectProtocol?

    private var isPreparingPlayback: Bool {
        playbackPreparationID != nil
    }

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: sideLength, height: sideLength)
                    .background(Color.black)
            } else {
                Color.black.opacity(0.86)
                Image(systemName: didFail ? "arrow.clockwise" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.45), in: Circle())

                VStack {
                    Spacer()
                    Text(download.fileName.nilIfBlank ?? attachment.fileName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
        .onTapGesture {
            if isPreparingPlayback {
                tearDownPlayback()
            } else {
                playbackTask?.cancel()
                playbackTask = Task { await togglePlayback() }
            }
        }
        // Transcript rows are intentionally eager, so scrolling this tile out of the viewport
        // does not trigger onDisappear. Tear down here as well to release the player and delete
        // its decrypted playback scratch file as soon as the tile is no longer visible.
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            guard !isVisible else { return }
            tearDownPlayback()
        }
        .onDisappear {
            tearDownPlayback()
        }
        // If this view's identity outlives a change of the attachment it renders (e.g. a
        // media grid slot flips to a different attachment, or the download's decrypted
        // payload changes), tear the player down so playback and the scratch-file cleanup
        // can never target the previous attachment's `playbackURL`. See #339.
        .onChange(of: attachment.id) { _, _ in
            resetForAttachmentChange()
        }
        .onChange(of: download.payload.id) { _, _ in
            resetForAttachmentChange()
        }
        .accessibilityLabel("Video attachment")
    }

    private func tearDownPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        stopPlayback()
    }

    private func resetForAttachmentChange() {
        didFail = false
        tearDownPlayback()
    }

    @MainActor
    private func togglePlayback() async {
        guard !Task.isCancelled else { return }

        if let player {
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
            return
        }

        if isPreparingPlayback {
            stopPlayback()
            return
        }

        await startPlayback()
    }

    @MainActor
    private func startPlayback() async {
        guard !Task.isCancelled else { return }

        let nextPreparationID = UUID()
        playbackPreparationID = nextPreparationID
        isLoading = true
        didFail = false
        defer {
            if playbackPreparationID == nextPreparationID {
                playbackPreparationID = nil
                isLoading = false
            }
        }

        let resolvedURL: URL?
        if let playbackURL {
            resolvedURL = playbackURL
        } else {
            resolvedURL = await MessageMediaPlaybackFileStore.fileURL(
                attachment: attachment,
                download: download
            )
        }
        guard playbackPreparationID == nextPreparationID, !Task.isCancelled else {
            // Preparation was superseded or cancelled after `fileURL` materialized a fresh
            // decrypted scratch file. `playbackURL` is still unset on this path, so the
            // teardown paths can't reclaim it — delete it here to avoid leaking plaintext.
            if let resolvedURL, resolvedURL != playbackURL {
                MessageMediaPlaybackFileStore.remove(at: resolvedURL)
            }
            return
        }
        guard let url = resolvedURL else {
            didFail = true
            return
        }
        playbackURL = url
        let next = AVPlayer(url: url)
        player = next
        observeEndOfPlayback(for: next)
        next.play()
    }

    /// Seeks the playhead back to the start when the item plays to completion so the next tap
    /// restarts playback instead of no-op-ing on the final frame. Mirrors the audio replay fix
    /// (#118) for the separate `AVPlayer` video code path.
    private func observeEndOfPlayback(for player: AVPlayer) {
        removeEndOfPlaybackObserver()
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
        }
    }

    private func removeEndOfPlaybackObserver() {
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
            self.endOfPlaybackObserver = nil
        }
    }

    /// Cancels in-flight preparation, releases the player, and deletes the decrypted scratch
    /// file. Ordered so `AVPlayer` no longer references the file before it is removed.
    private func stopPlayback() {
        playbackPreparationID = nil
        isLoading = false
        removeEndOfPlaybackObserver()
        player?.pause()
        player = nil
        if let url = playbackURL {
            MessageMediaPlaybackFileStore.remove(at: url)
            playbackURL = nil
        }
    }
}

enum MessageMediaPlaybackFileStore {
    /// Materializes decrypted attachment plaintext into the sandboxed playback scratch
    /// directory. Callers own the returned URL and must delete it via `remove(at:)` once
    /// the consuming action (open/playback) finishes.
    @MainActor
    static func fileURL(attachment: MessageMediaAttachment, download: MessageMediaDownload) async -> URL? {
        let resolvedFileName = download.fileName.nilIfBlank ?? attachment.fileName
        let resolvedMediaType = download.mediaType.nilIfBlank ?? attachment.mediaType
        let attachmentID = attachment.id
        let data = download.payload.data

        return await Task.detached(priority: .utility) {
            do {
                let directory = try MediaPlaybackTempStore.directoryURL()
                return try MediaPlaybackTempStore.materialize(
                    data: data,
                    id: attachmentID,
                    mediaType: resolvedMediaType,
                    fileName: resolvedFileName,
                    directory: directory
                )
            } catch {
                return nil
            }
        }.value
    }

    static func remove(at url: URL) {
        MediaPlaybackTempStore.remove(at: url)
    }
}

struct MessageImageGalleryOverlay: View {
    @Environment(WorkspaceState.self) private var workspace
    let presentation: MessageImageGalleryPresentation
    let onClose: () -> Void
    @State private var selectedIndex: Int

    init(presentation: MessageImageGalleryPresentation, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.onClose = onClose
        _selectedIndex = State(initialValue: presentation.initialIndex)
    }

    private var selectedAttachment: MessageMediaAttachment {
        presentation.imageAttachments[min(max(0, selectedIndex), presentation.imageAttachments.count - 1)]
    }

    private var canNavigate: Bool {
        presentation.imageAttachments.count > 1
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.92)

                imageContent
                    .frame(
                        maxWidth: max(1, geometry.size.width - 104),
                        maxHeight: max(1, geometry.size.height - 120)
                    )

                VStack {
                    HStack(spacing: 12) {
                        Text(selectedAttachment.fileName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer()

                        if canNavigate {
                            Text("\(selectedIndex + 1) / \(presentation.imageAttachments.count)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .help("Close")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                    Spacer()
                }

                if canNavigate {
                    HStack {
                        navigationButton(systemName: "chevron.left", isEnabled: selectedIndex > 0) {
                            selectedIndex = max(0, selectedIndex - 1)
                        }

                        Spacer()

                        navigationButton(
                            systemName: "chevron.right",
                            isEnabled: selectedIndex < presentation.imageAttachments.count - 1
                        ) {
                            selectedIndex = min(presentation.imageAttachments.count - 1, selectedIndex + 1)
                        }
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        MessageImageGalleryContent(
            downloadState: workspace.mediaDownloadStateStore(for: presentation.message, attachment: selectedAttachment),
            message: presentation.message,
            attachment: selectedAttachment
        )
    }

    private func navigationButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .bold))
                .frame(width: 54, height: 54)
                .background(Color.white.opacity(isEnabled ? 0.16 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.28))
        .disabled(!isEnabled)
        .help(systemName == "chevron.left" ? "Previous image" : "Next image")
    }
}

struct MessageImageGalleryContent: View {
    @Environment(WorkspaceState.self) private var workspace
    let downloadState: MediaDownloadStateStore
    let message: MessageItem
    let attachment: MessageMediaAttachment

    var body: some View {
        Group {
            switch downloadState.state {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            case .failed:
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("Image unavailable")
                        .font(.callout.weight(.semibold))
                    Button {
                        Task { await workspace.loadMediaAttachment(attachment, for: message) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                .foregroundStyle(.white)
            case .loaded(let download):
                DownsampledMessageGalleryImage(download: download, attachment: attachment)
            }
        }
        .autoDownloadMediaAttachment(
            downloadState,
            attachment: attachment,
            message: message,
            requiresScrollVisibility: false
        )
    }
}

struct DownsampledMessageGalleryImage: View {
    @Environment(\.displayScale) private var displayScale
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment

    var body: some View {
        GeometryReader { proxy in
            DownsampledDataImage(
                payload: download.payload,
                maxPixelSize: DownsampledImageSizing.galleryPixelSize(
                    for: proxy.size,
                    displayScale: displayScale
                )
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(attachment.fileName)
            } placeholder: {
                Text("Image unavailable")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct MessageDebugMetadataView: View {
    let message: MessageItem
    let isOutgoing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.debugTitle)
                .font(.caption2.weight(.semibold).monospaced())
            Text(message.debugDetail)
                .font(.caption2.monospaced())
                .lineLimit(1)
        }
        .foregroundStyle(isOutgoing ? Color.white.opacity(0.74) : Color.primary.opacity(0.52))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageInlineActions: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isEmojiPickerPresented = false
    @State private var isOverflowPresented = false
    @Binding var isPresentationActive: Bool
    let message: MessageItem

    var body: some View {
        HStack(spacing: 4) {
            if message.canReact {
                Button {
                    isEmojiPickerPresented = true
                } label: {
                    MessageInlineActionIcon(systemName: "face.smiling", label: "React")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isEmojiPickerPresented, arrowEdge: .bottom) {
                    MessageEmojiPickerPopover { emoji in
                        isEmojiPickerPresented = false
                        Task { await workspace.react(to: message, emoji: emoji) }
                    }
                }
                .help("React")
            }

            if message.canReply {
                Button {
                    workspace.startReply(to: message)
                } label: {
                    MessageInlineActionIcon(systemName: "arrowshape.turn.up.left", label: "Reply")
                }
                .buttonStyle(.plain)
                .help("Reply")
            }

            if message.supportsChatActions {
                Button {
                    isOverflowPresented = true
                } label: {
                    MessageInlineActionIcon(systemName: "ellipsis", label: "More")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isOverflowPresented, arrowEdge: .bottom) {
                    MessageOverflowPopover(message: message) {
                        isOverflowPresented = false
                    }
                }
                .help("More")
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .onChange(of: isEmojiPickerPresented) { _, _ in
            syncPresentationState()
        }
        .onChange(of: isOverflowPresented) { _, _ in
            syncPresentationState()
        }
        .onDisappear {
            isPresentationActive = false
        }
    }

    private func syncPresentationState() {
        isPresentationActive = isEmojiPickerPresented || isOverflowPresented
    }
}

struct MessageInlineActionIcon: View {
    @State private var isHovering = false
    let systemName: String
    let label: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isHovering ? Color.primary : Color.secondary.opacity(0.9))
            .frame(width: 40, height: 40)
            .background {
                Circle()
                    .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
                    .frame(width: 32, height: 32)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(label)
            .animation(.easeOut(duration: 0.08), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct MessageEmojiPickerPopover: View {
    @State private var isFullPickerPresented = false
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ChatReactionDefaults.quick, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 22))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: L10n.string("React with %@"), emoji))
            }

            Button {
                isFullPickerPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("More emoji"))
            .popover(isPresented: $isFullPickerPresented, arrowEdge: .bottom) {
                ChatEmojiPicker { emoji in
                    isFullPickerPresented = false
                    onPick(emoji)
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
    }
}

/// The actions available on a message row, gated by message and conversation capabilities.
/// Centralised here so both presentations — the native
/// `.contextMenu` (`MessageContextMenuItems`) and the inline hover popover
/// (`MessageOverflowPopover`) — share one source of truth for which actions exist and what
/// they do, while each keeps its own button styling.
struct MessageRowAction: Identifiable {
    enum Kind { case info, select, forward, edit, copy, delete }

    let kind: Kind
    let title: LocalizedStringKey
    let systemImage: String
    let role: ButtonRole?
    let run: () -> Void

    var id: Kind { kind }

    @MainActor
    static func all(
        for message: MessageItem,
        workspace: WorkspaceState,
        dismiss: @escaping () -> Void = {}
    ) -> [MessageRowAction] {
        var actions: [MessageRowAction] = []
        actions.append(
            MessageRowAction(kind: .info, title: "Message Info", systemImage: "info.circle", role: nil) {
                workspace.showMessageInfo(message)
                dismiss()
            })
        actions.append(
            MessageRowAction(kind: .select, title: "Select", systemImage: "checkmark.circle", role: nil) {
                workspace.beginMessageSelection(message)
                dismiss()
            })
        if message.canForward {
            actions.append(
                MessageRowAction(kind: .forward, title: "Forward", systemImage: "arrowshape.turn.up.right", role: nil) {
                    workspace.startForwarding([message])
                    dismiss()
                })
        }
        if message.canEdit {
            actions.append(
                MessageRowAction(kind: .edit, title: "Edit", systemImage: "pencil", role: nil) {
                    workspace.startEditingMessage(message)
                    dismiss()
                })
        }
        if message.canCopyText {
            actions.append(
                MessageRowAction(kind: .copy, title: "Copy Text", systemImage: "doc.on.doc", role: nil) {
                    workspace.copyText(of: message)
                    dismiss()
                })
        }
        if workspace.canDeleteMessage(message) {
            actions.append(
                MessageRowAction(kind: .delete, title: "Delete", systemImage: "trash", role: .destructive) {
                    dismiss()
                    workspace.messagePendingDeletion = message
                })
        }
        return actions
    }
}

struct MessageOverflowPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let dismiss: () -> Void

    var body: some View {
        let actions = MessageRowAction.all(for: message, workspace: workspace, dismiss: dismiss)
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                overflowButton(action)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 190)
        .presentationBackground(.regularMaterial)
        .glassCard(material: .regularMaterial)
    }

    private func overflowButton(_ action: MessageRowAction) -> some View {
        Button(role: action.role, action: action.run) {
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .frame(width: 18)
                Text(action.title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(action.role == .destructive ? Color.red : Color.primary)
    }
}

/// The right-click menu for a chat bubble. Unlike the inline hover bar this is always
/// reachable (no hover), so it mirrors the same React/Reply/Copy/Delete actions — gated on
/// the message's own capabilities — rather than only the Copy/Delete overflow subset. This
/// keeps React/Reply available for media-only bubbles, where the hover bar can be easy to
/// miss and text/copy actions don't apply. See whitenoise-mac#361.
struct MessageContextMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

    /// A short list of common reactions offered inline in the context menu; the hover bar's
    /// popover remains the path to the full emoji grid.
    private static let quickReactionEmojis = ChatReactionDefaults.quick

    var body: some View {
        let actions = MessageRowAction.all(for: message, workspace: workspace)

        if message.canReact {
            Menu {
                ForEach(Self.quickReactionEmojis, id: \.self) { emoji in
                    Button {
                        Task { await workspace.react(to: message, emoji: emoji) }
                    } label: {
                        Text(emoji)
                    }
                }
            } label: {
                Label("React", systemImage: "face.smiling")
            }
        }

        if message.canReply {
            Button {
                workspace.startReply(to: message)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }

        if (message.canReact || message.canReply) && !actions.isEmpty {
            Divider()
        }
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            if index > 0 { Divider() }
            Button(role: action.role, action: action.run) {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}

struct MessageReplyContextView: View {
    let context: MessageReplyContext
    let isOutgoing: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isOutgoing ? Color.white.opacity(0.72) : MessagesPalette.sentBubble.opacity(0.68))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : MessagesPalette.sentBubble)
                        .lineLimit(1)

                    Text(context.body)
                        .font(.caption)
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .help("Show replied-to message")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if isOutgoing {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.13))
            } else {
                GlassRoundedBackground(cornerRadius: 8)
            }
        }
    }
}

struct TimelineDayHeaderView: View {
    let title: String

    var body: some View {
        HStack {
            Spacer(minLength: 24)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background { GlassCapsuleBackground() }
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 24)
        }
        .padding(.vertical, 2)
    }
}
