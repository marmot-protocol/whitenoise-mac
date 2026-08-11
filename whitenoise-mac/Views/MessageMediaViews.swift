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
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    var showsDebugMetadata = false
    var timestampReferenceDate = Date()
    var timestampLocale = AppLanguage.currentLocale
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void
    let onNavigateToMessage: (String) -> Void

    // Receives the resolved MessageItem by value (not via a shared @Observable lookup),
    // so SwiftUI diffs each row by value and only re-runs the rows that actually changed
    // instead of invalidating every visible row on each page load / streaming update.
    var body: some View {
        // `mediaDownloads` is observation-ignored to keep unrelated timeline rows isolated. This
        // narrow token is the explicit invalidation path when Storage clears every attachment.
        let _ = workspace.mediaCacheGeneration
        // Only chat bubbles are selectable; `toggleMessageSelection` ignores system/notice rows,
        // so they must not show a checkbox or carry button semantics in selection mode.
        if workspace.isTimelineSelectionMode, message.presentation.isChatBubble {
            let isSelected = workspace.selectedTimelineMessageIds.contains(message.id)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .wnFont(.medium20)
                    .foregroundStyle(
                        isSelected ? WNColor.backgroundContentPrimary : WNColor.backgroundContentTertiary
                    )
                    .frame(width: 24)
                    .padding(.leading, 14)
                content
            }
            .padding(.vertical, 1)
            .background(isSelected ? WNColor.fillTertiaryHover : WNColor.fillTertiary)
            .contentShape(Rectangle())
            .onTapGesture { workspace.toggleMessageSelection(message) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(
                isSelected ? L10n.string("Deselect message") : L10n.string("Select message")
            )
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.presentation.isChatBubble {
            MessageBubble(
                message: message,
                showsDebugMetadata: showsDebugMetadata,
                timestampReferenceDate: timestampReferenceDate,
                timestampLocale: timestampLocale,
                onOpenImageGallery: onOpenImageGallery,
                onNavigateToMessage: onNavigateToMessage
            )
        } else {
            TimelineNoticeRow(
                message: message,
                showsDebugMetadata: showsDebugMetadata,
                timestampReferenceDate: timestampReferenceDate,
                timestampLocale: timestampLocale
            )
        }
    }
}

struct TimelineNoticeRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let showsDebugMetadata: Bool
    let timestampReferenceDate: Date
    let timestampLocale: Locale

    var body: some View {
        HStack {
            Spacer(minLength: 24)

            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: message.presentation.systemImage)
                        .wnFont(.semiBold12)
                        .symbolRenderingMode(.hierarchical)

                    Text(message.body)
                        .wnFont(.medium10)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)

                    Text(message.timeLabel(at: timestampReferenceDate, locale: timestampLocale))
                        .wnFont(.medium10.monospacedDigit())
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                }

                if showsDebugMetadata {
                    MessageDebugMetadataView(message: message, isOutgoing: false)
                }
            }
            .foregroundStyle(WNColor.backgroundContentSecondary)
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
                    Label(L10n.string("Copy Text"), systemImage: "doc.on.doc")
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
    @State private var isReactionViewerPresented = false
    @State private var reactionViewerEmoji: String?
    /// Clock the delivery marker is resolved against, advanced once this row's send has been
    /// unconfirmed long enough to stop reading as "Sending". Separate from the shared
    /// `timestampReferenceDate`, which only moves on calendar-day changes.
    @State private var deliveryClock = Date.now
    let message: MessageItem
    let showsDebugMetadata: Bool
    let timestampReferenceDate: Date
    let timestampLocale: Locale
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
                if showsSenderContactLink {
                    Button {
                        Task { await workspace.showContactDetails(for: message) }
                    } label: {
                        Text(message.senderName)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(format: L10n.string("View contact %@"), message.senderName)
                    )
                } else {
                    Text(message.senderName)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .padding(.horizontal, 4)
                }
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
                MessageReactionChips(reactions: message.reactions, isOutgoing: message.isOutgoing) { emoji in
                    reactionViewerEmoji = emoji
                    isReactionViewerPresented = true
                }
                // Hang the chips on the bubble's bottom edge (a slight upward overlap) instead of
                // floating as a detached row, matching the sibling clients' bubble-bound reactions.
                .padding(.horizontal, 10)
                .padding(.top, usesStickerStyle ? 0 : -10)
                .popover(isPresented: $isReactionViewerPresented, arrowEdge: .bottom) {
                    MessageReactionDetailsView(message: message, selectedEmoji: $reactionViewerEmoji)
                }
            }
        }
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            if !usesBubbleSurface {
                inlineActions
            }
        }
        .animation(.smooth(duration: 0.12), value: showsInlineActions)
        .frame(maxWidth: 660, alignment: message.isOutgoing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .padding(message.isOutgoing ? .leading : .trailing, 72)
        // Sender avatar in a leading gutter for incoming group messages (never DMs or own).
        .padding(.leading, showsSenderAvatar ? 36 : 0)
        .overlay(alignment: .bottomLeading) {
            if showsSenderAvatar {
                Button {
                    Task { await workspace.showContactDetails(for: message) }
                } label: {
                    ProfileImageAvatarView(
                        seed: message.senderAccountIdHex,
                        initials: message.senderName,
                        sanitizedPictureURL: message.senderSanitizedPictureURL,
                        size: 28,
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(format: L10n.string("View contact %@"), message.senderName)
                )
                .allowsHitTesting(!workspace.isTimelineSelectionMode)
                .padding(.bottom, 2)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !workspace.isTimelineSelectionMode {
                MessageContextMenuItems(message: message)
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
        // Keyed on the delivery-relevant fields only: a new reaction or a resolved sender name
        // must not restart a grace window that is already counting down.
        .task(id: message.deliverySignature) {
            deliveryClock = .now
            guard let remaining = message.pendingDeliveryGraceRemaining(at: deliveryClock) else { return }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            deliveryClock = .now
        }
    }

    private var showsInlineActions: Bool {
        message.supportsChatActions && (isHovering || isInlineActionPresentationActive)
    }

    private var usesBubbleSurface: Bool {
        showsDebugMetadata || message.hasBubbleContent
    }

    /// Replies, media captions, deleted messages, and debug rows retain the normal bubble
    /// because they contain additional visual context that needs a shared surface.
    private var stickerEmoji: String? {
        guard !showsDebugMetadata,
            !message.isDeleted,
            message.replyContext == nil,
            message.mediaAttachments.isEmpty
        else { return nil }
        return message.singleEmoji
    }

    private var usesStickerStyle: Bool {
        stickerEmoji != nil
    }

    /// Incoming messages in a group carry the sender's avatar in a leading gutter; DMs and the
    /// local account's own messages do not (the peer/self is unambiguous there).
    private var showsSenderAvatar: Bool {
        !message.isOutgoing && !(workspace.selectedChat?.isDirect ?? true)
    }

    private var showsSenderContactLink: Bool {
        showsSenderAvatar && !workspace.isTimelineSelectionMode
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

    @ViewBuilder
    private var bubbleContent: some View {
        if let stickerEmoji {
            stickerContent(stickerEmoji)
        } else {
            standardBubbleContent
        }
    }

    private func stickerContent(_ emoji: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: emoji)
                .wnFont(.medium60)
                .lineLimit(1)
                .padding(.horizontal, 4)

            if showsBubbleMetadata {
                compactMetadata
                    .padding(.horizontal, 4)
            }
        }
        .textSelectable(isSelectable)
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            inlineActions
        }
        .frame(maxWidth: 540, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var standardBubbleContent: some View {
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
                    trailingMetadata: showsInlineMetadata ? inlineMetadataSpacer : nil
                )
                .wnFont(.medium16)
                .foregroundStyle(MessagesPalette.bubbleContent(isOutgoing: message.isOutgoing))
                // Links take `intentionInfoContent` — the palette's one blue outside the accent
                // sets, and the same token the other clients use for a link inside a bubble. Its
                // `600`/`500` step clears both bubble fills, so it needs no per-direction variant.
                // Mentions carry the mentioned person's accent and override this per run.
                .tint(WNColor.intentionInfoContent)
                .multilineTextAlignment(.leading)
            }

            if showsReservedMetadataRow {
                compactMetadata.hidden()
            }
        }
        // One hover-gated selection gate for the whole bubble: `.textSelection` propagates
        // through the environment to the body + reply-quote Text, so only the active bubble
        // (`isSelectable`) is backed by a selection NSView. See whitenoise-mac#205.
        .textSelectable(isSelectable)
        // Metadata is pinned to the bubble's bottom-trailing corner no matter how the text
        // wraps. The inline spacer (flowing text) or hidden row (structured Markdown, empty
        // body) above reserves the space this overlay occupies, so it never covers content.
        .overlay(alignment: .bottomTrailing) {
            if showsBubbleMetadata {
                compactMetadata
            }
        }
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

    private var showsBubbleMetadata: Bool {
        !message.isDeleted
    }

    private var showsInlineMetadata: Bool {
        showsBubbleMetadata && !showsDebugMetadata && message.supportsInlineMetadata
    }

    private var showsReservedMetadataRow: Bool {
        showsBubbleMetadata && (!showsInlineMetadata || message.trimmedBody.isEmpty)
    }

    /// Transparent replica of `compactMetadata`, appended to the final text line so the
    /// wrapped text reserves room under the pinned overlay. Same strings and fonts as the
    /// visible copy so their widths track; interaction (the edit-history control) lives on
    /// the overlay, so this carries no link.
    private var inlineMetadataSpacer: Text {
        var result = Text(verbatim: "  ")
        if message.isEdited {
            result =
                result
                + Text(L10n.string("Edited")).wnFont(.medium10)
                + Text(verbatim: " ")
        }
        result =
            result
            + Text(message.timeLabel(at: timestampReferenceDate, locale: timestampLocale))
            .wnFont(.medium10.monospacedDigit())
        if let systemImage = Self.deliveryMarkerSystemImage(for: deliveryIndicator) {
            result =
                result + Text(verbatim: " ")
                + Text(Image(systemName: systemImage))
                .wnFont(.medium10)
        }
        return result.foregroundColor(.clear)
    }

    /// The footer glyph for each delivery marker, or nil for the rows that carry none. Shared with
    /// `inlineMetadataSpacer` so the transparent replica reserves exactly the visible width.
    private static func deliveryMarkerSystemImage(for indicator: MessageDeliveryIndicator) -> String? {
        switch indicator {
        case .none:
            return nil
        case .sending:
            return "clock"
        case .delivered:
            return "checkmark"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private var deliveryIndicator: MessageDeliveryIndicator {
        message.deliveryIndicator(at: deliveryClock)
    }

    /// The timestamp/delivery footer. One token in both directions, as on the other clients:
    /// `backgroundContentTertiary` is the neutral `400`/`500` step, which is the only rung that
    /// clears the sent bubble and the received bubble in both appearances.
    private var metadataColor: Color {
        WNColor.backgroundContentTertiary
    }

    private var compactMetadata: some View {
        HStack(spacing: 4) {
            if message.isEdited {
                Button(L10n.string("Edited")) { workspace.messagePendingEditHistory = message }
                    .buttonStyle(.plain)
                    .help(L10n.string("View edit history"))
            }
            Text(message.timeLabel(at: timestampReferenceDate, locale: timestampLocale))
                .monospacedDigit()
            if let systemImage = Self.deliveryMarkerSystemImage(for: deliveryIndicator) {
                Image(systemName: systemImage)
                    // Only a real failure earns the alarm color; an in-flight send stays in the
                    // metadata's own tint next to the timestamp.
                    .foregroundStyle(
                        deliveryIndicator == .failed
                            ? WNColor.backgroundContentDestructiveSecondary : metadataColor)
            }
        }
        .wnFont(.medium10)
        .foregroundStyle(metadataColor)
        .accessibilityLabel(
            message.metadataLabel(
                at: timestampReferenceDate,
                indicator: deliveryIndicator,
                locale: timestampLocale
            )
        )
    }
}

private extension View {
    /// Enable text selection only when `enabled`. `.textSelection(.enabled)` and `.disabled`
    /// are distinct types, so a ternary won't type-check. The inactive case states `.disabled`
    /// rather than leaving the bubble to inherit: the app enables selection globally
    /// (ContentView), so a bubble that applied nothing would pick up a selection NSView from
    /// the environment — exactly what whitenoise-mac#205 forbids across the transcript.
    @ViewBuilder
    func textSelectable(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }

    /// Chrome shared by every non-visual attachment presentation: the audio player, the
    /// download/failed status rows, and the document row. See `AttachmentRowPalette` for why the
    /// outgoing fill is the opaque accent rather than a wash over whatever sits behind the row.
    func attachmentRowChrome(isOutgoing: Bool) -> some View {
        foregroundStyle(AttachmentRowPalette.content(isOutgoing: isOutgoing))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 260, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AttachmentRowPalette.fill(isOutgoing: isOutgoing))
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
/// tucked in on the sender's side.
///
/// Both fills are opaque palette tokens — `fillPrimary` for sent, `backgroundMessageIncoming` for
/// received — and neither carries a stroke, matching the other clients. The received bubble used to
/// be a translucent wash, which meant its apparent color depended on whatever it happened to be
/// scrolled over.
private struct BubbleBackground: View {
    let isOutgoing: Bool

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: isOutgoing ? 20 : 6,
            bottomTrailingRadius: isOutgoing ? 6 : 20,
            topTrailingRadius: 20,
            style: .continuous
        )
        .fill(MessagesPalette.bubbleFill(isOutgoing: isOutgoing))
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

    static func accessibilityLabel(for action: MessageVisualMediaTileTapAction) -> String? {
        switch action {
        case .retryDownload:
            return L10n.string("Retry download")
        case .openImageGallery:
            return L10n.string("Open image")
        case .none:
            return nil
        }
    }
}

enum MessageVideoAttachmentPlayerAccessibility {
    static func label(isPreparingPlayback: Bool, didFail: Bool) -> String {
        if didFail {
            return L10n.string("Retry video")
        }
        if isPreparingPlayback {
            return L10n.string("Cancel video loading")
        }
        return L10n.string("Play video")
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

    private var gridHeight: CGFloat {
        MessageMediaGridPresentation.gridHeight(totalCount: attachments.count, maxWidth: maxWidth, spacing: spacing)
    }

    private var rows: [MediaGridRow] {
        let visible = visibleAttachments
        return MessageMediaGridPresentation.rowRanges(totalCount: attachments.count)
            .enumerated()
            .compactMap { index, range in
                guard !range.isEmpty, range.upperBound <= visible.count else { return nil }
                return MediaGridRow(
                    id: index,
                    side: MessageMediaGridPresentation.tileSide(
                        rowCount: range.count,
                        maxWidth: maxWidth,
                        spacing: spacing
                    ),
                    attachments: Array(visible[range])
                )
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows) { row in
                HStack(spacing: spacing) {
                    ForEach(row.attachments) { attachment in
                        tile(for: attachment, side: row.side)
                    }
                }
            }
        }
        .frame(width: maxWidth, height: gridHeight, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
    }

    private func tile(for attachment: MessageMediaAttachment, side: CGFloat) -> some View {
        let isLastVisible = attachment.id == visibleAttachments.last?.id
        return MessageVisualMediaTile(
            downloadState: workspace.mediaDownloadStateStore(for: message, attachment: attachment),
            message: message,
            attachment: attachment,
            isOutgoing: isOutgoing,
            sideLength: side,
            hiddenCount: isLastVisible ? hiddenCount : 0,
            onOpenImageGallery: onOpenImageGallery
        )
    }
}

private struct MediaGridRow: Identifiable {
    let id: Int
    let side: CGFloat
    let attachments: [MessageMediaAttachment]
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
        let tapAction = MessageVisualMediaTileInteraction.tapAction(
            downloadState: downloadState.state,
            attachmentKind: attachment.kind
        )
        Group {
            if tapAction == .none {
                tileBody
            } else {
                Button(action: performPrimaryAction) {
                    tileBody
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    MessageVisualMediaTileInteraction.accessibilityLabel(for: tapAction) ?? ""
                )
            }
        }
        .accessibilityIdentifier("message.media.visualTile.\(attachment.id)")
    }

    private var tileBody: some View {
        ZStack {
            content

            if hiddenCount > 0 {
                // Chrome over media: `overlayTertiary` is the palette's scrim, and content on it
                // takes `fillContentQuaternary` — white in both appearances, because the scrim is
                // dark in both.
                WNColor.overlayTertiary
                Text(verbatim: "+\(hiddenCount)")
                    .wnFont(.bold18)
                    .foregroundStyle(WNColor.fillContentQuaternary)
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
    }

    private func performPrimaryAction() {
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
            WNColor.backgroundTertiary
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .wnFont(.semiBold24)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
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
        // A finished document opens on click of the whole row — no trailing retry/download glyph
        // (the file is already in hand, especially for our own sends). A `Button` (not a tap
        // gesture) keeps it reachable by keyboard/VoiceOver.
        Button {
            Task { await openAttachment() }
        } label: {
            MessageAttachmentStatusRow(
                systemImage: "doc",
                title: download.fileName.nilIfBlank ?? attachment.fileName,
                detail: mediaDetail,
                isOutgoing: isOutgoing
            )
        }
        .buttonStyle(.plain)
        .help(L10n.string("Open"))
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
                    .fill(AttachmentRowPalette.controlFill(isOutgoing: isOutgoing))
                    .frame(width: 30, height: 30)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AttachmentRowPalette.content(isOutgoing: isOutgoing))
                } else {
                    Image(systemName: systemImage)
                        .wnFont(.semiBold14)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .wnFont(.semiBold10)
                    .lineLimit(1)
                Text(detail)
                    .wnFont(.medium10)
                    .foregroundStyle(AttachmentRowPalette.detailContent)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retryAction {
                Button(action: retryAction) {
                    Image(systemName: "arrow.clockwise")
                        .wnFont(.semiBold14)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Retry"))
            }
        }
        .attachmentRowChrome(isOutgoing: isOutgoing)
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
                    .wnFont(.bold14)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(AttachmentRowPalette.controlFill(isOutgoing: isOutgoing))
                    }
            }
            .buttonStyle(.plain)
            .help(isPlaying || isPreparingPlayback ? L10n.string("Stop") : L10n.string("Play"))

            // No file name: an audio attachment is almost always a voice recording whose
            // name the sender never chose, so it is noise next to the waveform. The composer
            // preview and the pending-outgoing row already omit it, and so does iOS — the
            // waveform takes the full row width with the duration beneath it.
            VStack(alignment: .leading, spacing: 5) {
                ComposerAudioWaveformView(
                    bars: visibleWaveformBars,
                    progress: playbackProgress,
                    barColor: AttachmentRowPalette.waveformBar(isOutgoing: isOutgoing),
                    playedColor: AttachmentRowPalette.waveformPlayedBar(isOutgoing: isOutgoing)
                )
                .frame(height: 24)

                Text(durationLabel)
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(AttachmentRowPalette.detailContent)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .attachmentRowChrome(isOutgoing: isOutgoing)
        // Transcript rows are intentionally eager, so scrolling this tile out of the viewport
        // does not trigger onDisappear. Stop playback here as well so the AVAudioPlayer and
        // progress monitor do not keep running offscreen.
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            guard !isVisible else { return }
            stopPlayback()
        }
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
                    .background(WNColor.shadow)
            } else {
                Button(action: activatePlayback) {
                    playbackPlaceholder
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    MessageVideoAttachmentPlayerAccessibility.label(
                        isPreparingPlayback: isPreparingPlayback,
                        didFail: didFail
                    )
                )
            }
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
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
    }

    // Chrome that sits over a video frame, so it follows the other clients' media pairing rather
    // than the app surface's: `overlayTertiary` for the scrim (black at 50% in both appearances,
    // since a video frame is not light or dark in a way the palette can know) and
    // `fillContentQuaternary` for everything drawn on it.
    private var playbackPlaceholder: some View {
        ZStack {
            WNColor.overlayTertiary
            Image(systemName: didFail ? "arrow.clockwise" : "play.fill")
                .wnFont(.bold24)
                .foregroundStyle(WNColor.fillContentQuaternary)
                .frame(width: 48, height: 48)
                .background(WNColor.overlayTertiary, in: Circle())

            VStack {
                Spacer()
                Text(download.fileName.nilIfBlank ?? attachment.fileName)
                    .wnFont(.semiBold10)
                    .foregroundStyle(WNColor.fillContentQuaternary.opacity(0.86))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(WNColor.fillContentQuaternary)
                    .frame(width: 42, height: 42)
                    .background(WNColor.overlayTertiary, in: Circle())
            }
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
    }

    private func activatePlayback() {
        if isPreparingPlayback {
            tearDownPlayback()
        } else {
            playbackTask?.cancel()
            playbackTask = Task { await togglePlayback() }
        }
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
        // Re-resolve the selected attachment's ignored state store after a manual cache clear.
        let _ = workspace.mediaCacheGeneration
        GeometryReader { geometry in
            ZStack {
                // The full-bleed viewer backdrop. `shadow` is the palette's black — the only pure
                // black it defines, and black in both appearances — held at viewer strength rather
                // than `overlayTertiary`'s 50%, which would leave the transcript legible behind the
                // photo.
                WNColor.shadow.opacity(0.92)
                    .onTapGesture(perform: onClose)

                imageContent
                    .frame(
                        maxWidth: max(1, geometry.size.width - 104),
                        maxHeight: max(1, geometry.size.height - 120)
                    )

                VStack {
                    HStack(spacing: 12) {
                        Text(selectedAttachment.fileName)
                            .wnFont(.semiBold12)
                            .foregroundStyle(WNColor.fillContentQuaternary)
                            .lineLimit(1)

                        Spacer()

                        if canNavigate {
                            Text(verbatim: "\(selectedIndex + 1) / \(presentation.imageAttachments.count)")
                                .wnFont(.semiBold10.monospacedDigit())
                                .foregroundStyle(WNColor.fillContentQuaternary.opacity(0.72))
                        }

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .wnFont(.bold16)
                                .frame(width: 34, height: 34)
                                .background(
                                    WNColor.fillContentQuaternary.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(WNColor.fillContentQuaternary)
                        .help(L10n.string("Close"))
                        .accessibilityLabel(L10n.string("Close"))
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                    Spacer()
                }

                if canNavigate {
                    HStack {
                        navigationButton(
                            systemName: "chevron.left",
                            accessibilityLabel: L10n.string("Previous image"),
                            isEnabled: selectedIndex > 0
                        ) {
                            selectedIndex = max(0, selectedIndex - 1)
                        }
                        .keyboardShortcut(.leftArrow, modifiers: [])

                        Spacer()

                        navigationButton(
                            systemName: "chevron.right",
                            accessibilityLabel: L10n.string("Next image"),
                            isEnabled: selectedIndex < presentation.imageAttachments.count - 1
                        ) {
                            selectedIndex = min(presentation.imageAttachments.count - 1, selectedIndex + 1)
                        }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
        .onExitCommand(perform: onClose)
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
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .wnFont(.bold28)
                .frame(width: 54, height: 54)
                .background(
                    WNColor.fillContentQuaternary.opacity(isEnabled ? 0.16 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(WNColor.fillContentQuaternary.opacity(isEnabled ? 0.96 : 0.28))
        .disabled(!isEnabled)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
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
                    .tint(WNColor.fillContentQuaternary)
            case .failed:
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .wnFont(.medium18)
                    Text(L10n.string("Image unavailable"))
                        .wnFont(.semiBold12)
                    Button {
                        Task { await workspace.loadMediaAttachment(attachment, for: message) }
                    } label: {
                        Label(L10n.string("Retry"), systemImage: "arrow.clockwise")
                    }
                }
                .foregroundStyle(WNColor.fillContentQuaternary)
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
                Text(L10n.string("Image unavailable"))
                    .wnFont(.semiBold12)
                    .foregroundStyle(WNColor.fillContentQuaternary)
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
        .foregroundStyle(WNColor.backgroundContentTertiary)
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
                    MessageInlineActionIcon(systemName: "face.smiling", label: L10n.string("React"))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isEmojiPickerPresented, arrowEdge: .bottom) {
                    MessageEmojiPickerPopover { emoji in
                        isEmojiPickerPresented = false
                        Task { await workspace.react(to: message, emoji: emoji) }
                    }
                }
                .help(L10n.string("React"))
            }

            if message.canReply {
                Button {
                    workspace.startReply(to: message)
                } label: {
                    MessageInlineActionIcon(systemName: "arrowshape.turn.up.left", label: L10n.string("Reply"))
                }
                .buttonStyle(.plain)
                .help(L10n.string("Reply"))
            }

            if message.supportsChatActions {
                Button {
                    isOverflowPresented = true
                } label: {
                    MessageInlineActionIcon(systemName: "ellipsis", label: L10n.string("More"))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isOverflowPresented, arrowEdge: .bottom) {
                    MessageOverflowPopover(message: message) {
                        isOverflowPresented = false
                    }
                }
                .help(L10n.string("More"))
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
            .wnFont(.medium18)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(
                isHovering ? WNColor.backgroundContentPrimary : WNColor.backgroundContentSecondary
            )
            .frame(width: 40, height: 40)
            .background {
                Circle()
                    .fill(isHovering ? WNColor.fillTertiaryHover : WNColor.fillTertiary)
                    .frame(width: 32, height: 32)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(label)
            .animation(.easeOut(duration: 0.08), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct QuickReactionButtons<Label: View>: View {
    let emojis: [String]
    let onPick: (String) -> Void
    let label: (String) -> Label

    init(
        emojis: [String],
        onPick: @escaping (String) -> Void,
        @ViewBuilder label: @escaping (String) -> Label
    ) {
        self.emojis = emojis
        self.onPick = onPick
        self.label = label
    }

    var body: some View {
        ForEach(emojis, id: \.self) { emoji in
            Button {
                onPick(emoji)
            } label: {
                label(emoji)
            }
            .accessibilityLabel(String(format: L10n.string("React with %@"), emoji))
        }
    }
}

struct MessageEmojiPickerPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isFullPickerPresented = false
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            QuickReactionButtons(emojis: workspace.quickReactions, onPick: onPick) { emoji in
                Text(emoji)
                    .wnFont(.medium24)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                isFullPickerPresented = true
            } label: {
                Image(systemName: "plus")
                    .wnFont(.bold14)
                    .foregroundStyle(WNColor.fillContentTertiary)
                    .frame(width: 32, height: 32)
                    .background(WNColor.fillSecondary, in: Circle())
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
    enum Kind { case retry, info, select, forward, edit, copy, delete }

    let kind: Kind
    let title: String
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
        if message.canRetryDelivery {
            actions.append(
                MessageRowAction(
                    kind: .retry,
                    title: L10n.string("Retry"),
                    systemImage: "arrow.clockwise",
                    role: nil
                ) {
                    Task { await workspace.retryDelivery(of: message) }
                    dismiss()
                })
        }
        actions.append(
            MessageRowAction(kind: .info, title: L10n.string("Message Info"), systemImage: "info.circle", role: nil) {
                workspace.showMessageInfo(message)
                dismiss()
            })
        actions.append(
            MessageRowAction(kind: .select, title: L10n.string("Select"), systemImage: "checkmark.circle", role: nil) {
                workspace.beginMessageSelection(message)
                dismiss()
            })
        if message.canForward {
            actions.append(
                MessageRowAction(
                    kind: .forward, title: L10n.string("Forward"), systemImage: "arrowshape.turn.up.right", role: nil
                ) {
                    workspace.startForwarding([message])
                    dismiss()
                })
        }
        if message.canEdit {
            actions.append(
                MessageRowAction(kind: .edit, title: L10n.string("Edit"), systemImage: "pencil", role: nil) {
                    workspace.startEditingMessage(message)
                    dismiss()
                })
        }
        if message.canCopyText {
            actions.append(
                MessageRowAction(kind: .copy, title: L10n.string("Copy Text"), systemImage: "doc.on.doc", role: nil) {
                    workspace.copyText(of: message)
                    dismiss()
                })
        }
        if workspace.canDeleteMessage(message) {
            actions.append(
                MessageRowAction(kind: .delete, title: L10n.string("Delete"), systemImage: "trash", role: .destructive)
                {
                    dismiss()
                    workspace.messagePendingDeletion = workspace.messageDeletionTarget(for: message)
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
        .foregroundStyle(
            action.role == .destructive
                ? WNColor.backgroundContentDestructive : WNColor.backgroundContentPrimary)
    }
}

/// The right-click menu for a chat bubble. The reaction submenu and hover popover both render
/// `QuickReactionButtons` from the workspace preference, while the remaining actions mirror the
/// hover bar's overflow (`MessageRowAction.all`).
struct MessageContextMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

    var body: some View {
        Group {
            if message.canReact {
                Menu {
                    QuickReactionButtons(
                        emojis: workspace.quickReactions,
                        onPick: { emoji in
                            Task { await workspace.react(to: message, emoji: emoji) }
                        }
                    ) { emoji in
                        Text(emoji)
                    }
                } label: {
                    Label(L10n.string("React"), systemImage: "face.smiling")
                }

                Divider()
            }

            ForEach(MessageRowAction.all(for: message, workspace: workspace)) { action in
                Button(role: action.role, action: action.run) {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
        .menuLabelIcons()
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
                    .fill(WNColor.borderTertiary)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.senderName)
                        .wnFont(.semiBold10)
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                        .lineLimit(1)

                    Text(context.body)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .help(L10n.string("Show replied-to message"))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The quote is its own card on `backgroundPrimary`, identically in both directions, as on
        // the other clients — which is what lets its content take `background*` tokens instead of
        // having to be picked per bubble fill. It cannot inherit a translucent material here: it
        // sits *inside* the bubble, so a material would composite against `fillPrimary` and leave
        // the quote's text colors undefined.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WNColor.backgroundPrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(WNColor.borderTertiary, lineWidth: 1)
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
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background { GlassCapsuleBackground() }
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 24)
        }
        .padding(.vertical, 2)
    }
}
