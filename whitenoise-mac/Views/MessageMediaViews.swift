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
    /// The hover strip's own width, measured. See `inlineActions`.
    @State private var inlineActionWidth: CGFloat = 0
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

    /// Gap between the row's stacked parts — sender name, media, bubble, reactions. Named because
    /// the reaction chips' negative top padding has to cancel it before it can overlap the bubble.
    private static let contentSpacing: CGFloat = 6

    var body: some View {
        // Alignment is done with a fill-frame + opposite-side padding rather than the old
        // `HStack { Spacer(minLength: 72); … }`. Two flexible `Spacer`s plus the nested
        // `maxWidth` frames formed an underdetermined flexible-width system that SwiftUI
        // re-solved on every `sizeThatFits` — and the transcript's lazy stack issues dozens
        // of those per row while resolving the bottom scroll anchor. Frame-alignment is a
        // single deterministic pass with the same result: bubble pinned to its side, ≥72pt
        // gutter opposite. See whitenoise-mac#205 (scroll-layout hangs).
        // The order is `MessageBubbleLayout`'s, not this stack's: the reaction pill is drawn with a
        // negative top padding, so it rides up onto whatever was emitted immediately before it, and
        // getting that neighbour wrong put the reactions on top of the timestamp.
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: Self.contentSpacing) {
            ForEach(
                MessageBubbleLayout.elements(for: message, showsDebugMetadata: showsDebugMetadata),
                id: \.self
            ) { element in
                bubbleElement(element)
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

    @ViewBuilder
    private func bubbleElement(_ element: MessageBubbleElement) -> some View {
        switch element {
        case .senderName:
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

        case .visualMediaGrid:
            MessageVisualMediaGrid(
                message: message,
                attachments: message.visualMediaAttachments,
                isOutgoing: message.isOutgoing,
                onOpenImageGallery: onOpenImageGallery
            )

        case .nonvisualMediaRows:
            ForEach(message.nonvisualMediaAttachments) { attachment in
                MessageMediaAttachmentView(
                    downloadState: workspace.mediaDownloadStateStore(for: message, attachment: attachment),
                    message: message,
                    attachment: attachment,
                    isOutgoing: message.isOutgoing
                )
            }

        case .bubbleContent:
            bubbleContent

        case .reactionChips:
            MessageReactionChips(reactions: message.reactions) { emoji in
                reactionViewerEmoji = emoji
                isReactionViewerPresented = true
            }
            // Hang the chips on the bubble's bottom edge (a slight upward overlap) instead of
            // floating as a detached row, matching the sibling clients' bubble-bound reactions.
            // The overlap comes from the chip so the pill's height and how much of it rides on
            // the bubble stay one decision.
            .padding(.horizontal, 10)
            .padding(.top, reactionChipPlacement.topPadding(contentSpacing: Self.contentSpacing))
            .popover(isPresented: $isReactionViewerPresented, arrowEdge: .bottom) {
                MessageReactionDetailsView(message: message, selectedEmoji: $reactionViewerEmoji)
            }

        case .standaloneMetadata:
            compactMetadata
                .padding(.horizontal, 5)

        case .sendFailureActions:
            sendFailureActions
        }
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

    /// The pill rides the caption bubble when there is one and the media card when there is not.
    /// A sticker carries no surface, and a row that is only a timestamp offers no edge — both take
    /// their own row instead of overlapping the text above them.
    private var reactionChipPlacement: MessageReactionChipPlacement {
        .value(
            usesSurface: usesBubbleSurface || !message.mediaAttachments.isEmpty,
            usesStickerStyle: usesStickerStyle
        )
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
            // The strip is an overlay on the bubble's edge, pushed clear of it by the width
            // SwiftUI measured — not by a count of the controls kept in step with the row's `if`
            // ladder by hand, which is a mirror that goes stale the next time a control is added.
            //
            // `.alignmentGuide` would say this without the state, but an explicit guide does not
            // survive the `ViewBuilder` conditionals between here and the overlay that consumes
            // it: the guide is dropped and the strip renders on top of the bubble. `.offset` is a
            // draw-time transform, so it does not care what it is nested in.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                inlineActionWidth = width
            }
            .offset(x: message.isOutgoing ? -inlineActionOffset : inlineActionOffset)
            // Hidden for the frame between first layout and the width arriving, so the strip is
            // never seen at a position derived from a width of zero.
            .opacity(inlineActionWidth > 0 ? 1 : 0)
            .transition(
                .opacity.combined(
                    with: .scale(
                        scale: 0.96,
                        anchor: message.isOutgoing ? .trailing : .leading
                    )))
        }
    }

    /// Retry under a failed own send.
    ///
    /// The red footer glyph and its tooltip are the whole of the failure story otherwise, and a
    /// tooltip is not an affordance. Retry is in the row's ⋯ menu too, where every other thing that
    /// can be done to a message lives — but a failure is worth answering without making the user go
    /// looking, so this one action is answered twice on purpose. Delete is not: it is destructive
    /// and belongs with the rest of the menu. Suppressed during multi-select, where the row is a
    /// checkbox target rather than a message.
    ///
    /// Gated on `deliveryIndicator`, which reads `.sending` again while a retry runs — so this
    /// stands down for that window and the bubble shows the same clock a first attempt shows,
    /// inside its own footer, instead of a progress line hanging underneath it.
    @ViewBuilder
    private var sendFailureActions: some View {
        if message.canRetryDelivery(at: deliveryClock), deliveryIndicator == .failed,
            !workspace.isTimelineSelectionMode
        {
            MessageSendFailureActions {
                Task { await workspace.retryDelivery(of: message) }
            }
            .padding(.horizontal, 5)
        }
    }

    /// Breathing room between the hover strip and the bubble edge.
    private static let inlineActionBubbleGap: CGFloat = 8

    private var inlineActionOffset: CGFloat {
        inlineActionWidth + Self.inlineActionBubbleGap
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
        .padding(.horizontal, 12)
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
        workspace.deliveryIndicator(for: message, at: deliveryClock)
    }

    /// Hover text for the failure glyph. The bubble keeps the message's own text now, so this
    /// glyph is the only visible thing saying the send failed — the tooltip carries the reason
    /// ("Did not reach group" vs. "Not delivered") that the old tombstone body spelled out.
    /// Empty in every other state, which shows no tooltip.
    private var deliveryFailureHelp: String {
        guard deliveryIndicator == .failed else { return "" }
        return message.statusLabel(for: .failed) ?? ""
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
                            ? WNColor.backgroundContentDestructiveSecondary : metadataColor
                    )
                    .help(deliveryFailureHelp)
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

    /// The circular well behind an audio row's control. Shared by the placeholder's spinner and
    /// retry icon and by the player's play/stop icon, so a finished download swaps the glyph
    /// without moving anything around it.
    func audioRowControlChrome(isOutgoing: Bool) -> some View {
        frame(width: 30, height: 30)
            .background {
                Circle()
                    .fill(AttachmentRowPalette.controlFill(isOutgoing: isOutgoing))
            }
    }

    /// The pill behind an audio row's playback-speed label, a capsule counterpart to
    /// `audioRowControlChrome`. Its width is fixed rather than hugging the label because the three
    /// labels are not the same width: at the 10pt rung `1x` lays out at 12pt and `1.5x` at 22pt, so
    /// a self-sizing pill would shove the waveform sideways on every click of the badge.
    func audioRowSpeedChrome(isOutgoing: Bool) -> some View {
        frame(width: 34, height: 22)
            .background {
                Capsule()
                    .fill(AttachmentRowPalette.controlFill(isOutgoing: isOutgoing))
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
    @State private var coordinator = AutomaticMediaDownloadCoordinator()

    func body(content: Content) -> some View {
        Group {
            if requiresScrollVisibility {
                content
                    // A tiny non-zero threshold means eager, non-lazy transcript rows do not
                    // auto-download until at least part of the tile intersects the ScrollView.
                    .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                        coordinator.scrollVisibilityChanged(
                            to: isVisible,
                            isReady: downloadState.shouldStartAutomaticDownload,
                            download: download
                        )
                    }
            } else {
                content
                    .onAppear {
                        coordinator.appeared(
                            isReady: downloadState.shouldStartAutomaticDownload,
                            download: download
                        )
                    }
            }
        }
        .onChange(of: attachment.id) { _, _ in
            coordinator.attachmentChanged(
                isReady: downloadState.shouldStartAutomaticDownload,
                requiresScrollVisibility: requiresScrollVisibility,
                download: download
            )
        }
        .onChange(of: downloadState.shouldStartAutomaticDownload) { _, shouldStart in
            coordinator.readinessChanged(
                to: shouldStart,
                requiresScrollVisibility: requiresScrollVisibility,
                download: download
            )
        }
        .onDisappear {
            coordinator.disappeared()
        }
    }

    private func download() async {
        await workspace.loadMediaAttachment(attachment, for: message)
    }
}

/// The chat bubble's fill, in `MessageBubbleShape` — symmetric, and a capsule once the message is
/// short enough that half its height is the smaller radius.
///
/// Both fills are opaque palette tokens — `fillPrimary` for sent, `backgroundMessageIncoming` for
/// received — and neither carries a stroke, matching the other clients. The received bubble used to
/// be a translucent wash, which meant its apparent color depended on whatever it happened to be
/// scrolled over.
private struct BubbleBackground: View {
    let isOutgoing: Bool

    var body: some View {
        MessageBubbleShape()
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

    /// Carrying out the action `tapAction` chose.
    ///
    /// Here rather than inside the tile so the routing is reachable: a failed tile's press has to
    /// reach the *explicit* download entry point — the same one a retry from the bubble menu uses —
    /// and an image's press has to hand back the gallery it opens on. Neither is observable from a
    /// SwiftUI control a test cannot press.
    @MainActor
    static func perform(
        _ action: MessageVisualMediaTileTapAction,
        message: MessageItem,
        attachment: MessageMediaAttachment,
        workspace: WorkspaceState,
        onOpenImageGallery: (MessageImageGalleryPresentation) -> Void
    ) async {
        switch action {
        case .retryDownload:
            await workspace.loadMediaAttachment(attachment, for: message)
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
        let action = MessageVisualMediaTileInteraction.tapAction(
            downloadState: downloadState.state,
            attachmentKind: attachment.kind
        )
        Task {
            await MessageVisualMediaTileInteraction.perform(
                action,
                message: message,
                attachment: attachment,
                workspace: workspace,
                onOpenImageGallery: onOpenImageGallery
            )
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
                // Audio keeps the player's shell while it downloads so the row does not reflow
                // when the payload lands; every other kind still names the file it is fetching.
                if attachment.kind == .audio {
                    MessageAudioAttachmentPlaceholder(
                        isOutgoing: isOutgoing,
                        accessibilityLabel: attachment.previewLabel
                    )
                } else {
                    MessageAttachmentStatusRow(
                        systemImage: "arrow.down.circle",
                        title: attachment.fileName,
                        detail: attachment.mediaType,
                        isOutgoing: isOutgoing,
                        isLoading: true
                    )
                }
            case .loaded(let download):
                loadedContent(download)
            case .failed:
                if attachment.kind == .audio {
                    MessageAudioAttachmentPlaceholder(
                        isOutgoing: isOutgoing,
                        accessibilityLabel: L10n.string("Attachment unavailable")
                    ) {
                        Task { await workspace.loadMediaAttachment(attachment, for: message) }
                    }
                } else {
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
                    .foregroundStyle(AttachmentRowPalette.detailContent(isOutgoing: isOutgoing))
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

/// The geometry every audio attachment row shares, whatever its download state: a circular
/// control, then the waveform with the duration beneath it.
///
/// The placeholder and the loaded player both render through this so the row cannot reflow as a
/// download finishes — only the control's glyph changes. Nothing here shows the file name; an
/// audio attachment is almost always a voice recording whose name the sender never chose.
struct MessageAudioRow<Control: View, SpeedControl: View>: View {
    static var waveformHeight: CGFloat { 24 }

    /// Where the row's controls meet its middle column: half the waveform's own height, so the
    /// guide follows the band it names rather than a literal that can drift away from it.
    ///
    /// The duration label hangs below the bars inside that column, so the column's centre — and the
    /// row box's with it — sits about half a line below the bars. Meeting on `.center` therefore
    /// hangs the play control and the speed badge low against the waveform they belong to.
    static var waveformCenterGuide: CGFloat { waveformHeight / 2 }

    let bars: [ComposerAudioWaveformBar]
    let progress: CGFloat
    let durationLabel: String
    let isOutgoing: Bool
    @ViewBuilder let control: Control
    @ViewBuilder let speedControl: SpeedControl

    var body: some View {
        // Aligned on the waveform's own midline rather than on the row box. The duration label
        // hangs below the bars, so the box's centre sits about half a line lower than they do —
        // enough that a centred play button read as riding low against the waveform beside it.
        // Only the middle column needs to state its guide; the control and the badge fall back to
        // their own centres, which is exactly where they should meet the bars.
        HStack(alignment: .audioRowWaveformCenter, spacing: 10) {
            control

            VStack(alignment: .leading, spacing: 5) {
                ComposerAudioWaveformView(
                    bars: bars,
                    progress: progress,
                    barColor: AttachmentRowPalette.waveformBar(isOutgoing: isOutgoing),
                    playedColor: AttachmentRowPalette.waveformPlayedBar(isOutgoing: isOutgoing)
                )
                .frame(height: Self.waveformHeight)

                Text(durationLabel)
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(AttachmentRowPalette.detailContent(isOutgoing: isOutgoing))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.audioRowWaveformCenter) { _ in Self.waveformCenterGuide }

            speedControl
        }
        .attachmentRowChrome(isOutgoing: isOutgoing)
    }
}

/// `nonisolated` because `AlignmentID.defaultValue` is: the module defaults to MainActor
/// isolation, which would otherwise isolate the conformance and the alignment constant with it.
nonisolated extension VerticalAlignment {
    /// The midline of an audio row's waveform, so the play control and the speed badge sit level
    /// with the bars instead of with the box the bars and their duration label share.
    private enum AudioRowWaveformCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let audioRowWaveformCenter = VerticalAlignment(AudioRowWaveformCenter.self)
}

/// The `1x` / `1.5x` / `2x` pill at the trailing edge of an audio row.
///
/// Rendered by `MessageAudioAttachmentPlayer` as a button's label and by
/// `MessageAudioAttachmentPlaceholder` as inert text, so a finished download turns the badge live
/// without moving anything around it — the same reason both rows share `MessageAudioRow` itself.
struct MessageAudioSpeedBadge: View {
    let speed: AudioPlaybackSpeed
    let isOutgoing: Bool
    // Read here rather than passed in so the badge re-renders on a language switch: the decimal
    // separator in `1.5x` is language-specific, and the environment locale is the only form of the
    // preference SwiftUI tracks as a dependency.
    @Environment(\.locale) private var locale

    var body: some View {
        Text(speed.label(locale: locale))
            .wnFont(.bold10)
            .lineLimit(1)
            .audioRowSpeedChrome(isOutgoing: isOutgoing)
    }
}

/// An audio attachment with no payload to play yet — one still downloading, or one still on its
/// way out.
///
/// It stands in for `MessageAudioAttachmentPlayer` at exactly the same size, which is the whole
/// point: the spinner sits in the well the play button lands in, so the row swaps a glyph rather
/// than reflowing when the payload arrives. A download defaults to flat fallback bars and a `--:--`
/// duration because neither the real waveform nor the real duration is known before it lands — the
/// mac's imeta reference carries only `dim` and `thumbhash`. A send passes both in: the sender
/// recorded the audio, so this client already knows them.
///
/// Audio deliberately does not fall back to `MessageAttachmentStatusRow`: that row leads with the
/// file name and the raw media type, which is the wrong thing to show for a voice message and
/// reflows the bubble once playback is ready.
struct MessageAudioAttachmentPlaceholder: View {
    let isOutgoing: Bool
    let accessibilityLabel: String
    var bars: [ComposerAudioWaveformBar] = ComposerAudioWaveformPresentation.fallbackPlaybackBars
    var durationLabel: String = MediaDurationLabel.placeholder
    /// `nil` while the payload is still in flight; set once it has failed and can be retried.
    var retryAction: (() -> Void)?
    /// What the retry control's tooltip says. A download is retried; a send that never left is not.
    var retryHelp: String = L10n.string("Retry download")

    var body: some View {
        MessageAudioRow(
            bars: bars,
            progress: 0,
            durationLabel: durationLabel,
            isOutgoing: isOutgoing,
            control: {
                if let retryAction {
                    Button(action: retryAction) {
                        Image(systemName: "arrow.clockwise")
                            .wnFont(.bold14)
                            .audioRowControlChrome(isOutgoing: isOutgoing)
                    }
                    .buttonStyle(.plain)
                    .help(retryHelp)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AttachmentRowPalette.content(isOutgoing: isOutgoing))
                        .audioRowControlChrome(isOutgoing: isOutgoing)
                }
            },
            // Inert until the payload arrives: there is no player to set a rate on yet, and the
            // badge is here so the finished download does not reflow the row around it.
            speedControl: {
                MessageAudioSpeedBadge(speed: .initial, isOutgoing: isOutgoing)
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MessageAudioAttachmentPlayer: View {
    let download: MessageMediaDownload
    let isOutgoing: Bool
    @Environment(\.locale) private var locale
    @State private var playback = MessageAudioPlaybackController()
    @State private var metadata: MediaWaveformAnalyzer.Metadata?
    @State private var metadataPayloadID: String?
    @State private var waveformBars = ComposerAudioWaveformPresentation.fallbackPlaybackBars

    var body: some View {
        MessageAudioRow(
            bars: visibleWaveformBars,
            progress: playback.progress,
            durationLabel: durationLabel,
            isOutgoing: isOutgoing,
            control: {
                Button {
                    Task { await playback.toggle(payload: download.payload.data) }
                } label: {
                    Image(systemName: isStopControl ? "stop.fill" : "play.fill")
                        .wnFont(.bold14)
                        .audioRowControlChrome(isOutgoing: isOutgoing)
                }
                .buttonStyle(.plain)
                .help(isStopControl ? L10n.string("Stop") : L10n.string("Play"))
            },
            speedControl: {
                Button(action: playback.cycleSpeed) {
                    MessageAudioSpeedBadge(speed: playback.speed, isOutgoing: isOutgoing)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Playback speed"))
                .accessibilityLabel(L10n.string("Playback speed"))
                .accessibilityValue(playback.speed.label(locale: locale))
            }
        )
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            playback.scrollVisibilityChanged(to: isVisible)
        }
        .onDisappear {
            playback.disappeared()
        }
        .onChange(of: download.payload.id) { _, _ in
            playback.payloadChanged()
        }
        .task(id: download.payload.id) {
            let payloadID = download.payload.id
            if metadataPayloadID != payloadID {
                metadata = nil
                waveformBars = ComposerAudioWaveformPresentation.fallbackPlaybackBars
            }
            let loaded = await MessageAudioMetadataCache.shared.metadata(for: download)
            let loadedWaveformBars = ComposerAudioWaveformPresentation.bars(for: loaded.samples)
            guard !Task.isCancelled else { return }
            metadata = loaded
            metadataPayloadID = payloadID
            waveformBars = loadedWaveformBars
        }
    }

    private var isStopControl: Bool {
        playback.isPlaying || playback.isPreparingPlayback
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
}

struct MessageVideoAttachmentPlayer: View {
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool
    let sideLength: CGFloat

    @State private var playback = MessageVideoPlaybackController()

    var body: some View {
        ZStack {
            if let player = playback.player {
                // Outside the button on purpose: AVKit's own transport controls have to stay
                // interactive, and a button wrapping them would swallow every click.
                VideoPlayer(player: player)
                    .frame(width: sideLength, height: sideLength)
                    .background(WNColor.shadow)
            } else {
                Button {
                    playback.activatePlayback(attachment: attachment, download: download)
                } label: {
                    playbackPlaceholder
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.accessibilityLabel)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            playback.scrollVisibilityChanged(to: isVisible)
        }
        .onDisappear {
            playback.disappeared()
        }
        .onChange(of: attachment.id) { _, _ in
            playback.attachmentChanged()
        }
        .onChange(of: download.payload.id) { _, _ in
            playback.attachmentChanged()
        }
    }

    // Chrome that sits over a video frame, so it follows the other clients' media pairing rather
    // than the app surface's: `overlayTertiary` for the scrim (black at 50% in both appearances,
    // since a video frame is not light or dark in a way the palette can know) and
    // `fillContentQuaternary` for everything drawn on it.
    private var playbackPlaceholder: some View {
        ZStack {
            WNColor.overlayTertiary
            Image(systemName: playback.didFail ? "arrow.clockwise" : "play.fill")
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

            if playback.isLoading {
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
    @State private var navigation: MessageImageGalleryNavigation
    @State private var zoom = ImageZoomState()

    init(presentation: MessageImageGalleryPresentation, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.onClose = onClose
        _navigation = State(
            initialValue: MessageImageGalleryNavigation(
                imageCount: presentation.imageAttachments.count,
                selectedIndex: presentation.initialIndex
            )
        )
    }

    private var selectedAttachment: MessageMediaAttachment {
        presentation.imageAttachments[navigation.clampedIndex()]
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

                        if navigation.showsNavigation {
                            Text(verbatim: navigation.positionLabel)
                                .wnFont(.semiBold10.monospacedDigit())
                                .foregroundStyle(WNColor.fillContentQuaternary.opacity(0.72))
                        }

                        // Downloads the photo on screen, not the whole message: the bubble's own
                        // action is the one that takes every attachment.
                        if let download = MessageMediaDownloadAction(
                            message: presentation.message,
                            attachments: [selectedAttachment],
                            workspace: workspace
                        ) {
                            Button(action: download.perform) {
                                Group {
                                    if download.isInFlight {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(WNColor.fillContentQuaternary)
                                    } else {
                                        Image(systemName: "square.and.arrow.down")
                                            .wnFont(.bold16)
                                    }
                                }
                                .frame(width: 34, height: 34)
                                .background(
                                    WNColor.fillContentQuaternary.opacity(0.14), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(WNColor.fillContentQuaternary)
                            .disabled(download.isInFlight)
                            .help(download.title)
                            .accessibilityLabel(download.title)
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
                        .help(MessageImageGalleryNavigation.closeLabel)
                        .accessibilityLabel(MessageImageGalleryNavigation.closeLabel)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                    Spacer()
                }

                if navigation.showsNavigation {
                    HStack {
                        navigationButton(
                            systemName: "chevron.left",
                            accessibilityLabel: MessageImageGalleryNavigation.previousImageLabel,
                            isEnabled: navigation.canGoToPreviousImage
                        ) {
                            navigation.goToPreviousImage()
                        }
                        .keyboardShortcut(.leftArrow, modifiers: [])

                        Spacer()

                        navigationButton(
                            systemName: "chevron.right",
                            accessibilityLabel: MessageImageGalleryNavigation.nextImageLabel,
                            isEnabled: navigation.canGoToNextImage
                        ) {
                            navigation.goToNextImage()
                        }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
        .onExitCommand(perform: onClose)
        // Paging out of a magnified photo would drop the next one in at someone else's
        // zoom, so each image starts fitted. Flutter suppresses paging entirely while
        // zoomed; the chevrons above disable for the same reason.
        .onChange(of: navigation.selectedIndex) { zoom.reset() }
        .onChange(of: zoom.isZoomed) { _, isZoomed in navigation.isZoomed = isZoomed }
    }

    @ViewBuilder
    private var imageContent: some View {
        MessageImageGalleryContent(
            downloadState: workspace.mediaDownloadStateStore(for: presentation.message, attachment: selectedAttachment),
            message: presentation.message,
            attachment: selectedAttachment,
            zoom: $zoom
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
    @Binding var zoom: ImageZoomState

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
                DownsampledMessageGalleryImage(download: download, attachment: attachment, zoom: $zoom)
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
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment
    @Binding var zoom: ImageZoomState

    var body: some View {
        ZoomableMediaImage(
            payload: download.payload,
            zoom: $zoom,
            accessibilityLabel: attachment.fileName
        ) {
            Text(L10n.string("Image unavailable"))
                .wnFont(.semiBold12)
                .foregroundStyle(WNColor.fillContentQuaternary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            // Sits beside the overflow control rather than inside it: with media on the message
            // this is the action people reach for, and burying it one popover deep is the same
            // mistake the retry affordance made.
            if let download = MessageMediaDownloadAction(message: message, workspace: workspace) {
                Button(action: download.perform) {
                    MessageInlineActionIcon(systemName: "square.and.arrow.down", label: download.title)
                }
                .buttonStyle(.plain)
                .disabled(download.isInFlight)
                .help(download.title)
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
            QuickReactionButtons(
                emojis: MessageQuickReactionSurface.emojis(in: workspace),
                onPick: onPick
            ) { emoji in
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
/// The emoji row every quick-reaction surface offers.
///
/// One function rather than two call sites reading the preference for themselves: the hover popover
/// and the right-click menu answer the same gesture, and while each named its own array one of them
/// went on offering the built-in defaults after the reader had chosen their own.
@MainActor
enum MessageQuickReactionSurface {
    static func emojis(in workspace: WorkspaceState) -> [String] {
        workspace.quickReactions
    }
}

/// Whether a pending row shows the ⋯ that carries the rest of its recovery.
///
/// Failed sends only: a message still on its way out has nothing to retry and no cancellation story
/// in the core, so an open menu would offer actions that do nothing. Shared by the media and text
/// bubbles, which are two rows for one rule.
nonisolated enum PendingOutgoingMessageRecovery {
    static func showsOverflowControl(
        hasFailed: Bool,
        isHovering: Bool,
        isMenuPresented: Bool
    ) -> Bool {
        hasFailed && (isHovering || isMenuPresented)
    }
}

struct MessageRowAction: Identifiable {
    enum Kind { case retry, info, select, forward, edit, copy, delete }

    let kind: Kind
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let run: () -> Void

    var id: Kind { kind }

    /// `now` resolves the delivery-grace-sensitive actions. Both presentations build their list when
    /// the menu opens and throw it away when it closes, so reading the clock here is exact rather
    /// than a snapshot that could go stale under a long-lived view.
    @MainActor
    static func all(
        for message: MessageItem,
        workspace: WorkspaceState,
        now: Date = .now,
        dismiss: @escaping () -> Void = {}
    ) -> [MessageRowAction] {
        var actions: [MessageRowAction] = []
        // Dropped rather than disabled while a retry is already running, so this list agrees with
        // the bubble's own recovery row — which trades Retry for a progress line for that window.
        // `retryDelivery` would refuse the second call anyway; the point is not to offer a click
        // that does nothing.
        if message.canRetryDelivery(at: now), !workspace.isRetryingDelivery(of: message) {
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

    /// The same two recovery actions for a media message that never reached the core: the bubble
    /// the transcript renders while a send is on its way out, once that send has failed.
    ///
    /// Deliberately the same type the committed rows build, so both open `MessageOverflowMenu` and
    /// a failed row's actions live in one place whichever half of the send it is stranded in. The
    /// list is empty until then — the core has no cancellation story for a publish in flight, so
    /// neither action would do anything.
    @MainActor
    static func all(
        for message: PendingOutgoingMediaMessage,
        workspace: WorkspaceState,
        dismiss: @escaping () -> Void = {}
    ) -> [MessageRowAction] {
        guard message.state == .failed else { return [] }
        return [
            MessageRowAction(kind: .retry, title: L10n.string("Retry"), systemImage: "arrow.clockwise", role: nil) {
                dismiss()
                workspace.retryPendingOutgoingMediaMessage(message.id)
            },
            // "Remove", not "Delete": nothing has been committed anywhere yet, so dropping the
            // bubble takes the message with it rather than hiding a message the group has. It also
            // skips the deletion confirmation the committed rows go through, for the same reason.
            MessageRowAction(kind: .delete, title: L10n.string("Remove"), systemImage: "trash", role: .destructive) {
                dismiss()
                workspace.discardPendingOutgoingMediaMessage(message.id)
            },
        ]
    }

    /// The same two recovery actions again, for a text message that never got out. Text reaches this
    /// state two ways media cannot: queued behind a send that is still timing out, or rolled back by
    /// the core after its own publish failed.
    @MainActor
    static func all(
        for message: PendingOutgoingTextMessage,
        workspace: WorkspaceState,
        dismiss: @escaping () -> Void = {}
    ) -> [MessageRowAction] {
        guard message.state == .failed else { return [] }
        return [
            MessageRowAction(kind: .retry, title: L10n.string("Retry"), systemImage: "arrow.clockwise", role: nil) {
                dismiss()
                workspace.retryPendingOutgoingTextMessage(message.id)
            },
            MessageRowAction(kind: .delete, title: L10n.string("Remove"), systemImage: "trash", role: .destructive) {
                dismiss()
                workspace.discardPendingOutgoingTextMessage(message.id)
            },
        ]
    }
}

struct MessageOverflowPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let dismiss: () -> Void

    var body: some View {
        MessageOverflowMenu(actions: MessageRowAction.all(for: message, workspace: workspace, dismiss: dismiss))
    }
}

/// The popover body behind the ⋯ control: a list of `MessageRowAction`s in the transcript's own
/// menu chrome.
///
/// Split from `MessageOverflowPopover` so the staged-media bubble
/// (`PendingOutgoingMessageOverflowButton`) opens the same menu rather than a lookalike — it
/// builds its actions from a message the core has never seen, but a failed row is a failed row and
/// the two must not drift into different shapes.
struct MessageOverflowMenu: View {
    let actions: [MessageRowAction]

    var body: some View {
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
///
/// React and Download are built here rather than in `MessageRowAction.all`: both also sit in the
/// hover bar as controls of their own, and `.all` backs the bar's overflow popover, so routing
/// them through it would show each of them twice, inches apart.
struct MessageContextMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

    var body: some View {
        Group {
            if let download = MessageMediaDownloadAction(message: message, workspace: workspace) {
                // The hover bar's download button is revealed by pointing at the row, which leaves
                // the right-click menu as the only path to it for a document or an audio file —
                // neither of which opens a viewer with a save control of its own. Same action
                // value as the bar's, so the two cannot disagree about when it is offered.
                Button(action: download.perform) {
                    Label(download.title, systemImage: "square.and.arrow.down")
                }
                .disabled(download.isInFlight)

                Divider()
            }

            if message.canReact {
                Menu {
                    QuickReactionButtons(
                        emojis: MessageQuickReactionSurface.emojis(in: workspace),
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
