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
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

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
    let safetyModel: GroupSafetyViewModel
    let conversationModel: ConversationViewModel
    /// Whether this account can vote here; mirrors whether the composer is usable.
    var canVoteInPolls = false
    var showsDebugMetadata = false
    var timestampReferenceDate = Date()
    var timestampLocale = AppLanguage.currentLocale
    /// Where the row sits in its run of messages from one person.
    var cluster: MessageClusterPosition = .standalone
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
                    .font(.title3)
                    .foregroundStyle(
                        isSelected ? WNColor.textPrimary : WNColor.backgroundContentTertiary
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
        if let item = message.agent?.item {
            AgentItemRow(
                message: message,
                item: item,
                timeLabel: message.timeLabel(at: timestampReferenceDate, locale: timestampLocale),
                actions: conversationModel.agents.actions(
                    memberCount: conversationModel.snapshot?.header.memberCount,
                    isDirect: workspace.selectedChat?.isDirect ?? false
                )
            )
        } else if message.presentation.isChatBubble {
            MessageBubble(
                message: message,
                safetyModel: safetyModel,
                customEmojiImages: conversationModel.customEmojiImages,
                conversationModel: conversationModel,
                showsDebugMetadata: showsDebugMetadata,
                timestampReferenceDate: timestampReferenceDate,
                timestampLocale: timestampLocale,
                cluster: cluster,
                onOpenImageGallery: onOpenImageGallery,
                onNavigateToMessage: onNavigateToMessage
            )
            // The agent's remark made while it works: quieter than its answer, and never alerts.
            .opacity(message.agent?.isCommentary == true ? 0.62 : 1)
        } else if message.presentation == .poll, let poll = message.poll {
            // Pass MDK's confirmed `poll` directly so bars, vote counts, and "Final results" never
            // claim an unconfirmed optimistic tally; `pendingSelection` only marks in-flight changes
            // while the poll is still open.
            PollMessageRow(
                poll: poll,
                isOutgoing: message.isOutgoing,
                senderName: showsSenderName ? message.senderName : nil,
                timeLabel: message.timeLabel(at: timestampReferenceDate, locale: timestampLocale),
                pendingSelection: conversationModel.pendingPollSelections[message.id],
                onVote: canVoteInPolls && message.invalidationStatus == nil ? vote(for: poll) : nil,
                onViewVotes: poll.participants > 0 ? viewVotes(for: poll) : nil
            )
        } else if let event = message.unsupportedEvent {
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                UnsupportedEventRow(
                    event: event,
                    isOutgoing: message.isOutgoing,
                    senderName: showsSenderName ? message.senderName : nil,
                    timeLabel: message.timeLabel(at: timestampReferenceDate, locale: timestampLocale),
                    onCopyJSON: { [workspace] json in workspace.copyText(json) }
                )
                if showsDebugMetadata {
                    MessageDebugMetadataView(message: message, isOutgoing: message.isOutgoing)
                }
            }
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

extension ConversationMessageRow {
    /// A poll or unsupported-event card names its sender only at the start of a run, like a bubble.
    fileprivate var showsSenderName: Bool {
        cluster.startsCluster && MessageBubble.showsSenderIdentity(for: message, in: workspace.selectedChat)
    }

    /// `poll` is MDK's tally, not the in-flight overlay: the sheet lists what MDK projected.
    fileprivate func viewVotes(for poll: MessagePoll) -> () -> Void {
        { [conversationModel, message] in
            conversationModel.showPollVotes(messageIdHex: message.id, poll: poll)
        }
    }

    fileprivate func vote(for poll: MessagePoll) -> (String) -> Void {
        { [workspace, conversationModel, message] optionId in
            Task {
                do {
                    try await conversationModel.votePoll(option: optionId, messageIdHex: message.id, poll: poll)
                } catch {
                    workspace.reportUserActionError(
                        "\(L10n.string("Vote failed")): \(UserFacingError.message(for: error))"
                    )
                }
            }
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
                        .font(.caption.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)

                    Text(message.body)
                        .font(.caption)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)

                    Text(message.timeLabel(at: timestampReferenceDate, locale: timestampLocale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                }

                if showsDebugMetadata {
                    MessageDebugMetadataView(message: message, isOutgoing: false)
                }
            }
            .foregroundStyle(WNColor.messageReceivedSecondaryContent)
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

/// The reaction details popover's body. It is the only view that reads
/// `conversationModel.reactionDetails`, so opening or closing one message's popover cannot widen
/// the observation of every bubble with reactions.
private struct MessageReactionDetailsPopoverContent: View {
    let conversationModel: ConversationViewModel
    let message: MessageItem
    @Binding var selectedEmoji: String?
    let dependencies: MessageReactionDetailsDependencies

    var body: some View {
        if let model = conversationModel.reactionDetails, model.messageIdHex == message.id {
            MessageReactionDetailsView(
                model: model,
                projected: MessageReactionDetails(projectedFrom: message),
                selectedEmoji: $selectedEmoji,
                dependencies: dependencies
            )
        }
    }
}

/// A reaction removal held for confirmation, with the details model whose complete list it was
/// resolved against (nil for a hover-strip or context-menu pick), so confirming re-validates it
/// against the same reactions.
private struct PendingReactionRemoval {
    let pick: MessageReactionPick
    let completeRead: MessageReactionsViewModel?
}

struct MessageBubble: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.conversationHoverSelectionCoordinator) private var hoverSelectionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Hover and the hover strip's open popover. See `MessageInlineActionPresentation`.
    @State private var inlineActionPresentation = MessageInlineActionPresentation()
    /// The hover strip's own width, measured. See `inlineActions`.
    @State private var inlineActionWidth: CGFloat = 0
    @State private var isSelectable = false
    /// Owned here, above the selection gate, so the link geometry the body text recorded
    /// survives the gate's branch flip on hover. See `MessageLinkRegions`.
    @State private var linkRegions = MessageLinkRegions()
    @State private var isReactionViewerPresented = false
    @State private var reactionViewerEmoji: String?
    /// Clock the delivery marker is resolved against, advanced once this row's send has been
    /// unconfirmed long enough to stop reading as "Sending". Separate from the shared
    /// `timestampReferenceDate`, which only moves on calendar-day changes.
    @State private var deliveryClock = Date.now
    /// The open Report Message sheet's model, built when Report is picked.
    @State private var reportModel: ReportMessageViewModel?
    /// The author a picked Block is waiting on confirmation for.
    @State private var blockTarget: MessageBlockTarget?
    /// A picked removal that would also retract the account's other reactions, held for
    /// confirmation. Owned here because the context menu that picks it is gone by the time the
    /// dialog shows.
    @State private var reactionPendingRemoval: PendingReactionRemoval?
    let message: MessageItem
    let safetyModel: GroupSafetyViewModel
    let customEmojiImages: CustomEmojiImageStore
    /// Owns the reaction details popover's model, so its read follows the conversation's window.
    let conversationModel: ConversationViewModel
    let showsDebugMetadata: Bool
    let timestampReferenceDate: Date
    let timestampLocale: Locale
    /// Where the row sits in its run of messages from one person: the sender's name heads the run,
    /// their avatar and the routine timestamp close it.
    var cluster: MessageClusterPosition = .standalone
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
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: Self.contentSpacing) {
            if showsSenderIdentity, cluster.startsCluster {
                if showsSenderContactLink {
                    Button {
                        Task { await workspace.showContactDetails(for: message) }
                    } label: {
                        Text(message.senderName)
                            .font(MessageTypography.senderName)
                            .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(format: L10n.string("View contact %@"), message.senderName)
                    )
                } else {
                    Text(message.senderName)
                        .font(MessageTypography.senderName)
                        .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                        .padding(.horizontal, 4)
                }
            }

            if !message.visualMediaAttachments.isEmpty, !embedsVisualMediaInBubble {
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

            // A sticker stands alone, above any caption or quote that came with it.
            if let sticker = message.sticker, let stickers = conversationModel.stickers {
                MessageStickerView(
                    library: stickers, loadingPreference: .shared, sticker: sticker,
                    isOutgoing: message.isOutgoing
                )
                .padding(.horizontal, 4)
            }

            if showsDebugMetadata || message.hasBubbleContent {
                bubbleContent
            }

            if message.supportsChatActions && !displayedReactions.isEmpty {
                MessageReactionChips(
                    reactions: displayedReactions,
                    omittedKinds: message.omittedReactionKinds,
                    emojiImages: reactionEmojiImages
                ) { emoji in
                    reactionViewerEmoji = emoji
                    // The read starts before the popover's first frame, so a truncated preview
                    // shows the read in flight rather than an empty list.
                    conversationModel.showReactionDetails(messageIdHex: message.id)
                    isReactionViewerPresented = true
                }
                .task(id: message.reactions) {
                    customEmojiImages.loadReactions(message.reactions)
                }
                // Hang the chips on the bubble's bottom edge (a slight upward overlap) instead of
                // floating as a detached row, matching the sibling clients' bubble-bound reactions.
                // The overlap comes from the chip so the pill's height and how much of it rides on
                // the bubble stay one decision.
                .padding(.horizontal, 10)
                .padding(.top, reactionChipPlacement.topPadding(contentSpacing: Self.contentSpacing))
                .popover(isPresented: $isReactionViewerPresented, arrowEdge: .bottom) {
                    MessageReactionDetailsPopoverContent(
                        conversationModel: conversationModel,
                        message: message,
                        selectedEmoji: $reactionViewerEmoji,
                        dependencies: reactionDetailsDependencies
                    )
                }
                .onChange(of: isReactionViewerPresented) { _, isPresented in
                    if !isPresented {
                        conversationModel.dismissReactionDetails(messageIdHex: message.id)
                    }
                }
                // A transcript cell can be recycled or torn down with its popover up, and then no
                // `false` is ever observed; the model would keep re-reading on every revision.
                // Dismissal is guarded by message id, so running it twice is harmless.
                .onDisappear {
                    conversationModel.dismissReactionDetails(messageIdHex: message.id)
                }
            }

            // After the chips, not before them: the pill rides up onto whatever precedes it, and a
            // caption-less row's metadata is a bare line of text rather than a surface with an edge
            // to spare. Emitted first, it was what the pill overlapped.
            if !message.hasBubbleContent, showsBubbleMetadata {
                compactMetadata(onBubble: false)
                    .padding(.horizontal, 5)
            }

            sendFailureActions
        }
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            if !usesBubbleSurface {
                inlineActions
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.12), value: showsInlineActions)
        .frame(maxWidth: 660, alignment: message.isOutgoing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .padding(message.isOutgoing ? .leading : .trailing, 72)
        // Sender avatar in a leading gutter for incoming group messages (never DMs or own). Every
        // row of a run keeps the gutter so its bubbles line up; only the run's last row fills it.
        .padding(.leading, showsSenderIdentity ? 36 : 0)
        .overlay(alignment: .bottomLeading) {
            if showsSenderIdentity, cluster.endsCluster {
                Button {
                    Task { await workspace.showContactDetails(for: message) }
                } label: {
                    ProfileImageAvatarView(
                        seed: message.senderAccountIdHex,
                        initials: message.senderName,
                        sanitizedPictureURL: message.senderSanitizedPictureURL,
                        localImagePayload: message.senderImagePayload,
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
                MessageContextMenuItems(
                    message: message,
                    onReactionPick: pickReaction,
                    moderation: moderationActions,
                    discardFailedSend: discardFailedSend
                )
            }
        }
        .messageModerationPresentations(
            report: $reportModel,
            blockTarget: $blockTarget,
            reporter: safetyModel.moderation
        )
        .confirmationDialog(
            L10n.string("Remove all your reactions?"),
            isPresented: Binding(
                get: { reactionPendingRemoval != nil },
                set: { presented in
                    if !presented { reactionPendingRemoval = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: reactionPendingRemoval
        ) { pending in
            Button(L10n.string("Remove all"), role: .destructive) {
                // The reactions may have changed while the dialog was open.
                guard let removal = confirmedRemoval(of: pending) else { return }
                Task { await removal.perform(on: message, in: workspace) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(L10n.string("Removing a reaction removes every reaction you added to this message."))
        }
        .onAppear {
            hoverSelectionCoordinator.register(messageID: message.id, isSelectable: $isSelectable)
        }
        .onDisappear {
            hoverSelectionCoordinator.unregister(messageID: message.id)
        }
        // A recycled row, a deleted message, or selection mode closes a popover the row no
        // longer offers instead of leaving it aimed at whatever the row now shows.
        .onChange(of: inlineActionEligibility) { _, eligibility in
            inlineActionPresentation.reconcile(with: eligibility)
        }
        .onHover { hovering in
            inlineActionPresentation.isHoveringRow = hovering
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
        inlineActionPresentation.showsStrip(
            supportsChatActions: message.supportsChatActions,
            isSelectionMode: workspace.isTimelineSelectionMode
        )
    }

    private var inlineActionEligibility: MessageInlineActionPresentation.Eligibility {
        MessageInlineActionPresentation.Eligibility(
            messageID: message.id,
            supportsChatActions: message.supportsChatActions,
            canReact: message.canReact,
            isSelectionMode: workspace.isTimelineSelectionMode
        )
    }

    /// Remove for a failed own send: discarded on this device and never published, because a
    /// delete would tell the group about a message nobody received. `nil` for every other row.
    private var discardFailedSend: (() -> Void)? {
        guard message.isLocalPublishFailure else { return nil }
        return { [conversationModel, workspace, message] in
            Task { await FailedSendDiscard.run(message, model: conversationModel, workspace: workspace) }
        }
    }

    /// Report and Block for the context menu and the hover strip's overflow. Resolved against the
    /// open conversation: a direct chat has no group report, and the White Noise copy and Block and
    /// Report depend on this build's reports key. An unknown chat is treated as direct, so a report
    /// is never shared with members the reporter cannot see.
    private var moderationActions: MessageModerationActions {
        let eligibility = safetyModel.moderationEligibility(
            for: message,
            isDirectChat: workspace.selectedChat?.isDirect ?? true
        )
        return MessageModerationActions(
            eligibility: eligibility,
            report: {
                reportModel = ReportMessageViewModel(
                    eligibility: eligibility,
                    dependencies: .live(
                        messageId: message.id,
                        authorAccountIdHex: eligibility.authorAccountIdHex,
                        safety: safetyModel,
                        reporter: safetyModel.moderation
                    )
                )
            },
            block: {
                guard let author = eligibility.authorAccountIdHex else { return }
                blockTarget = MessageBlockTarget(accountIdHex: author)
            }
        )
    }

    /// Sends a hover-strip or context-menu pick. Those menus only have the window preview, so the
    /// pick is resolved against it.
    private func pickReaction(_ emoji: String) {
        handleReactionPick(MessageReactionPick.resolve(emoji: emoji, reactions: message.reactions), completeRead: nil)
    }

    /// Sends a pick, or holds it for confirmation when retracting the picked emoji would retract
    /// the account's other reactions with it. `completeRead` is the details popover's model when
    /// the pick was resolved against its complete list.
    private func handleReactionPick(_ pick: MessageReactionPick, completeRead: MessageReactionsViewModel?) {
        // A custom emoji goes out with its image, so clients without it still draw it.
        if case .add(let emoji) = pick,
            let sendable = CustomEmojiSendCatalog.sendable(
                forReaction: emoji, in: conversationModel.customEmojiSendables)
        {
            Task { [conversationModel, message] in
                await conversationModel.customEmojiSender.react(with: sendable, to: message.id)
            }
            return
        }
        guard pick.needsConfirmation(on: message) else {
            Task { await pick.perform(on: message, in: workspace) }
            return
        }
        let pending = PendingReactionRemoval(pick: pick, completeRead: completeRead)
        guard completeRead != nil else {
            reactionPendingRemoval = pending
            return
        }
        // A pick from the details popover: a dialog presented while that transient popover is up
        // may not show, or show behind it. Close the popover, then present on the next turn. The
        // pending removal keeps the model, so its last complete read still re-validates the pick.
        isReactionViewerPresented = false
        Task { @MainActor in reactionPendingRemoval = pending }
    }

    /// The removal "Remove all" still sends, re-resolved against the same source the pick came
    /// from: a pick from the complete read may name an emoji the preview left out, and checking it
    /// against the preview would quietly send nothing.
    private func confirmedRemoval(of pending: PendingReactionRemoval) -> MessageReactionPick? {
        let current =
            pending.completeRead?.content(projected: MessageReactionDetails(projectedFrom: message))
            .listedReactions ?? message.reactions
        return pending.pick.confirmedRemoval(in: current)
    }

    /// This message's details model, while its popover owns one.
    private var reactionDetailsModel: MessageReactionsViewModel? {
        conversationModel.reactionDetails.flatMap { $0.messageIdHex == message.id ? $0 : nil }
    }

    private var usesBubbleSurface: Bool {
        showsDebugMetadata || message.hasBubbleContent
    }

    /// A reply that carries images or videos draws them inside its own bubble, under the quote,
    /// as iOS does — instead of as a detached card above a bubble holding only the quote.
    private var embedsVisualMediaInBubble: Bool {
        MessageReplyMediaLayout.embedsVisualMedia(
            hasReply: message.replyContext != nil,
            visualMediaCount: message.visualMediaAttachments.count
        )
    }

    /// The bubble's padding. A bubble wrapping media hugs it at `MessageReplyMediaLayout.outerInset`
    /// and moves the text back in by the difference, so captions and the metadata footer keep the
    /// text bubble's insets.
    private var bubbleHorizontalInset: CGFloat {
        embedsVisualMediaInBubble ? MessageReplyMediaLayout.outerInset : 12
    }

    private var bubbleVerticalInset: CGFloat {
        embedsVisualMediaInBubble ? MessageReplyMediaLayout.outerInset : 8
    }

    private var textHorizontalInset: CGFloat {
        12 - bubbleHorizontalInset
    }

    private var textBottomInset: CGFloat {
        8 - bubbleVerticalInset
    }

    /// Replies, media captions, deleted messages, and debug rows retain the normal bubble
    /// because they contain additional visual context that needs a shared surface.
    private var stickerEmoji: String? {
        guard !showsDebugMetadata,
            !message.isDeleted,
            message.replyContext == nil,
            message.contentMediaAttachments.isEmpty
        else { return nil }
        return message.singleEmoji
    }

    /// A message that is exactly one custom emoji takes the same bubble-free treatment, unless its
    /// image failed to load and it falls back to the literal `:shortcode:` in a bubble.
    private var customStickerEmoji: (shortcode: String, attachment: MessageMediaAttachment)? {
        guard !showsDebugMetadata,
            !message.isDeleted,
            message.replyContext == nil,
            message.contentMediaAttachments.isEmpty,
            let shortcode = CustomEmojiText.soleEmoji(
                in: message.trimmedBody, shortcodes: Set(message.customEmoji.keys)),
            let attachment = message.customEmoji[shortcode],
            !customEmojiImages.isUnavailable(attachment.reference)
        else { return nil }
        return (shortcode, attachment)
    }

    private var usesStickerStyle: Bool {
        stickerEmoji != nil || customStickerEmoji != nil
    }

    private var reactionDetailsDependencies: MessageReactionDetailsDependencies {
        MessageReactionDetailsDependencies(
            reactor: { [workspace] in workspace.reactionReactorDisplay(accountIdHex: $0) },
            emojiImage: { [customEmojiImages] in customEmojiImages.reactionImage(for: $0) },
            loadEmojiImages: { [customEmojiImages] in customEmojiImages.loadReactions($0) },
            requestProfiles: { [workspace] in workspace.requestPeerProfileRefresh($0) },
            // The same pick as the React control, so one popover has one removal rule: taking
            // back a reaction that retracts the others too is confirmed either way.
            removeOwnReaction: { reaction in
                handleReactionPick(.remove(reaction), completeRead: reactionDetailsModel)
            },
            quickReactions: workspace.quickReactions,
            customEmoji: .conversation(conversationModel),
            // The popover resolves the pick against its complete list; the bubble only confirms
            // and sends it, so a selected emoji is taken back rather than re-sent as a no-op.
            react: message.canReact ? { pick in handleReactionPick(pick, completeRead: reactionDetailsModel) } : nil
        )
    }

    /// Custom emoji reactions this device is still sending to this message.
    private var pendingCustomReactions: [CustomEmojiSendable] {
        conversationModel.customEmojiSender.pendingReactions(on: message.id)
    }

    /// The window's reactions plus the custom emoji reactions still being sent, so a pick shows at
    /// once instead of after its image uploads.
    private var displayedReactions: [MessageReaction] {
        PendingCustomEmojiReactions.merge(message.reactions, pending: pendingCustomReactions)
    }

    /// A pending reaction's image stands in until the window's own reaction resolves its artwork,
    /// so the chip never falls back to its literal `:shortcode:` in between.
    private var reactionEmojiImages: [String: NSImage] {
        var images: [String: NSImage] = [:]
        for emoji in pendingCustomReactions {
            images[emoji.token] = customEmojiImages.pendingReactionImage(for: emoji)
        }
        for reaction in message.reactions {
            if let image = customEmojiImages.reactionImage(for: reaction) { images[reaction.emoji] = image }
        }
        return images
    }

    /// The pill rides the caption bubble when there is one and the media card when there is not.
    /// A sticker carries no surface, and a row that is only a timestamp offers no edge — both take
    /// their own row instead of overlapping the text above them.
    private var reactionChipPlacement: MessageReactionChipPlacement {
        .value(
            usesSurface: usesBubbleSurface || !message.contentMediaAttachments.isEmpty,
            usesStickerStyle: usesStickerStyle
        )
    }

    /// Incoming messages in a group carry the sender's name above the bubble and their avatar in a
    /// leading gutter; DMs and the local account's own messages carry neither, since there is only
    /// one person the message can be from. Shared with poll rows so the two never disagree.
    static func showsSenderIdentity(for message: MessageItem, in chat: ChatItem?) -> Bool {
        !message.isOutgoing && !(chat?.isDirect ?? true)
    }

    private var showsSenderIdentity: Bool {
        Self.showsSenderIdentity(for: message, in: workspace.selectedChat)
    }

    private var showsSenderContactLink: Bool {
        showsSenderIdentity && !workspace.isTimelineSelectionMode
    }

    @ViewBuilder
    private var inlineActions: some View {
        if showsInlineActions {
            MessageInlineActions(
                presentation: $inlineActionPresentation,
                message: message,
                onReactionPick: pickReaction,
                moderation: moderationActions,
                discardFailedSend: discardFailedSend,
                customEmoji: .conversation(conversationModel)
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
        Group {
            if let stickerEmoji {
                stickerContent(
                    Text(verbatim: stickerEmoji)
                        .wnFont(.medium60)
                        .lineLimit(1)
                )
            } else if let customStickerEmoji {
                stickerContent(
                    CustomEmojiSticker(
                        shortcode: customStickerEmoji.shortcode,
                        image: customEmojiImages.image(for: customStickerEmoji.attachment.reference),
                        plaintextSha256: customStickerEmoji.attachment.reference.plaintextSha256
                    )
                )
            } else {
                standardBubbleContent
                    .environment(
                        \.customEmojiGlyphs, CustomEmojiGlyphs.value(for: message, store: customEmojiImages))
            }
        }
        .task(id: message.customEmoji.values.map(\.id).sorted()) {
            for attachment in message.customEmoji.values {
                customEmojiImages.load(attachment.reference)
            }
        }
    }

    private func stickerContent(_ glyph: some View) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            glyph
                .padding(.horizontal, 4)

            if showsBubbleMetadata {
                compactMetadata(onBubble: false)
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
                // Over media the quote sits at the media's inset, not the text's, on purpose: it
                // lines up with the grid under it, as the iOS rich-media bubble does.
                MessageReplyContextView(
                    context: replyContext,
                    isOutgoing: message.isOutgoing,
                    fillsWidth: embedsVisualMediaInBubble,
                    onOpen: { onNavigateToMessage(replyContext.targetMessageId) }
                )
            }

            if embedsVisualMediaInBubble {
                MessageVisualMediaGrid(
                    message: message,
                    attachments: message.visualMediaAttachments,
                    isOutgoing: message.isOutgoing,
                    onOpenImageGallery: onOpenImageGallery,
                    cornerRadius: MessageReplyMediaLayout.innerCornerRadius
                )
            }

            // One container, so the insets wrap the text block rather than each line of it.
            VStack(alignment: .leading, spacing: 8) {
                if let giphyMedia = message.remoteGiphyMedia {
                    RemoteGiphyMediaView(
                        media: giphyMedia,
                        mayLoadAutomatically: message.isOutgoing,
                        loadingPreference: .shared
                    )
                } else if !message.trimmedBody.isEmpty {
                    if let linkPreviewURL {
                        LinkPreviewCard(url: linkPreviewURL, loader: .shared)
                            .id(linkPreviewURL)
                    }

                    if let nostrEventReference {
                        NostrEventPreviewCard(
                            reference: nostrEventReference, store: conversationModel.nostrEventPreviews
                        )
                        .id(nostrEventReference)
                    }

                    MarkdownMessageView(
                        message: message,
                        trailingMetadata: showsInlineMetadata ? inlineMetadataSpacer : nil
                    )
                    .font(MessageTypography.body)
                    .foregroundStyle(bodyColor)
                    // A mention is a link run without a color, so the tint is what it draws in: the
                    // bubble's own content, as on iOS. Real links take the bubble's link role per run
                    // (`MessageLinkStyle`).
                    .tint(bodyColor)
                    .multilineTextAlignment(.leading)
                }

                if showsReservedMetadataRow {
                    compactMetadata(onBubble: true, isPlaceholder: true).hidden()
                }
            }
            .padding(.horizontal, textHorizontalInset)
            .padding(.bottom, textBottomInset)
        }
        // Media sets the bubble's width: the quote stretches to it and the caption wraps inside it.
        .frame(width: embedsVisualMediaInBubble ? MessageVisualMediaGrid.width : nil, alignment: .leading)
        // One hover-gated selection gate for the whole bubble: `.textSelection` propagates
        // through the environment to the body + reply-quote Text, so only the active bubble
        // (`isSelectable`) is backed by a selection NSView. See whitenoise-mac#205.
        .textSelectable(isSelectable)
        .environment(\.messageLinkRegions, linkRegions)
        // Quotes, links and Markdown's quieter runs take the bubble's own foreground set.
        .environment(\.messageBubblePolarity, bubblePolarity)
        // Metadata is pinned to the bubble's bottom-trailing corner no matter how the text
        // wraps. The inline spacer (flowing text) or hidden row (structured Markdown, empty
        // body) above reserves the space this overlay occupies, so it never covers content.
        .overlay(alignment: .bottomTrailing) {
            if showsBubbleMetadata {
                compactMetadata(onBubble: true)
                    .padding(.trailing, textHorizontalInset)
                    .padding(.bottom, textBottomInset)
            }
        }
        .padding(.horizontal, bubbleHorizontalInset)
        .padding(.vertical, bubbleVerticalInset)
        .background { BubbleBackground(polarity: bubblePolarity) }
        .modifier(HiddenMessageMetadata(isHidden: !showsClusterFooter, label: hiddenMetadataLabel))
        // Attach controls before the positioning frame so short messages use the visible
        // bubble edge instead of the frame's maximum width.
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            inlineActions
        }
        .frame(maxWidth: 540, alignment: message.isOutgoing ? .trailing : .leading)
    }

    /// Whether the row draws its routine timestamp/delivery footer: a run of messages shows the
    /// routine time once, on its last row (`MessageClusterPosition.showsFooter`).
    private var showsClusterFooter: Bool {
        Self.footerVisibility(cluster: cluster, message: message, indicator: footerIndicator).showsClusterFooter
    }

    /// Whether the footer slot renders at all: either the grouped timestamp footer or this
    /// message's own disappearing countdown (T11, #1040). Keeping the countdown independent of
    /// `showsClusterFooter` ensures earlier messages in a run keep their own expiry indicator
    /// without re-showing grouped timestamps.
    private var showsBubbleMetadata: Bool {
        Self.footerVisibility(cluster: cluster, message: message, indicator: footerIndicator).showsAnyMetadata
    }

    /// Per-row footer visibility split into grouped timestamp/status vs per-message disappearing
    /// countdown, so grouped messages keep timestamp grouping while each disappearing message
    /// shows its own expiry pie.
    nonisolated struct FooterVisibility: Equatable {
        let showsClusterFooter: Bool
        let showsRetentionCountdown: Bool

        var showsAnyMetadata: Bool {
            showsClusterFooter || showsRetentionCountdown
        }
    }

    static func footerVisibility(
        cluster: MessageClusterPosition,
        message: MessageItem,
        indicator: MessageDeliveryIndicator
    ) -> FooterVisibility {
        FooterVisibility(
            showsClusterFooter: cluster.showsFooter(
                isDeleted: message.isDeleted,
                isEdited: message.isEdited,
                hasReports: message.hasReports,
                indicator: indicator
            ),
            showsRetentionCountdown: MessageRetentionCountdown(message: message) != nil
        )
    }

    /// The marker the footer draws. A deleted message keeps its time but carries no delivery
    /// state: there is nothing left of it to deliver.
    private var footerIndicator: MessageDeliveryIndicator {
        message.isDeleted ? .none : deliveryIndicator
    }

    /// A send that did not go out says so where its time would be; the Retry link under the bubble
    /// is the action. An edited or reported failure keeps its time beside the notice.
    private var showsFailureNotice: Bool {
        showsClusterFooter && footerIndicator == .failed
    }

    private var showsFooterTime: Bool {
        showsClusterFooter && (!showsFailureNotice || message.isEdited || message.hasReports)
    }

    private var showsEditedLabel: Bool {
        showsClusterFooter && message.isEdited && !message.isDeleted
    }

    private var bubblePolarity: MessageBubblePolarity {
        MessageBubblePolarity(isOutgoing: message.isOutgoing)
    }

    /// The deleted label is quieter than a message, as on iOS, in the bubble's own secondary role.
    private var bodyColor: Color {
        message.isDeleted ? bubblePolarity.secondaryContent : bubblePolarity.content
    }

    /// This message's own disappearing countdown, when the core gives it a finite expiry.
    private var retentionCountdown: MessageRetentionCountdown? {
        MessageRetentionCountdown(message: message)
    }

    /// What a hidden footer would have said, kept for VoiceOver and the bubble's hover tooltip.
    private var hiddenMetadataLabel: String {
        message.metadataLabel(at: timestampReferenceDate, indicator: footerIndicator, locale: timestampLocale)
    }

    /// The first fetchable link in the message, while "Show Link Previews" is on.
    private var linkPreviewURL: URL? {
        guard !message.isDeleted, LinkPreviewPreference.shared.showsPreviews else { return nil }
        return LinkPreviewMetadata.previewURL(in: message.contentMarkdown)
    }

    /// The first public Nostr event the message links, while "Show Link Previews" is on: loading
    /// it asks relays the sender chose, the same cost a web preview has.
    private var nostrEventReference: String? {
        guard !message.isDeleted, LinkPreviewPreference.shared.showsPreviews else { return nil }
        return NostrEventPreview.previewReference(in: message.contentMarkdown)
    }

    private var showsInlineMetadata: Bool {
        showsBubbleMetadata && !showsDebugMetadata && message.supportsInlineMetadata
            && message.remoteGiphyMedia == nil
    }

    private var showsReservedMetadataRow: Bool {
        showsBubbleMetadata && (!showsInlineMetadata || message.trimmedBody.isEmpty)
    }

    /// Transparent replica of `compactMetadata`, appended to the final text line so the
    /// wrapped text reserves room under the pinned overlay. Same strings and fonts as the
    /// visible copy so their widths track; interaction (the edit-history control) lives on
    /// the overlay, so this carries no link.
    private var inlineMetadataSpacer: Text {
        let font = MessageTypography.footer
        var parts: [Text] = []
        if showsClusterFooter, let systemImage = MessageDeliveryMarker.systemImage(for: footerIndicator) {
            parts.append(Text(Image(systemName: systemImage)).font(font))
        }
        if showsFailureNotice {
            parts.append(Text(L10n.string("Not delivered")).font(font))
        }
        if retentionCountdown != nil {
            // The countdown's frame is this same symbol; see `MessageRetentionPie`.
            parts.append(Text(Image(systemName: "circle")).font(font))
        }
        if showsFooterTime {
            parts.append(
                Text(message.timeLabel(at: timestampReferenceDate, locale: timestampLocale))
                    .font(font)
                    .monospacedDigit())
        }
        if showsEditedLabel {
            parts.append(Text(L10n.string("Edited")).font(font))
        }
        var result = Text(verbatim: "  ")
        for (index, part) in parts.enumerated() {
            if index > 0 { result = result + Text(verbatim: " ") }
            result = result + part
        }
        return result.foregroundColor(.clear)
    }

    private static func deliveryMarkerColor(
        for indicator: MessageDeliveryIndicator,
        isOutgoing: Bool,
        otherwise: Color
    ) -> Color {
        switch indicator {
        case .failed:
            WNColor.backgroundContentDestructiveSecondary
        case .warning:
            // The sent bubble is `fillPrimary`, which the plain warning token does not clear in Dark.
            isOutgoing ? WNColor.intentionWarningContentOnFill : WNColor.intentionWarningContent
        case .none, .sending, .delivered:
            otherwise
        }
    }

    private var deliveryIndicator: MessageDeliveryIndicator {
        workspace.deliveryIndicator(for: message, at: deliveryClock)
    }

    /// Hover text for the failure and warning glyphs. The bubble keeps the message's own text now,
    /// so the glyph is the only visible thing saying something went wrong — the tooltip carries
    /// the reason the old tombstone body spelled out: "Not delivered" (an own send that did not go
    /// out) or "May not have reached everyone" (convergence retired it). Empty in every other
    /// state, which shows no tooltip.
    private var deliveryMarkerHelp: String {
        guard deliveryIndicator == .failed || deliveryIndicator == .warning else { return "" }
        return message.statusLabel(for: deliveryIndicator) ?? ""
    }

    /// The timestamp/delivery footer's tint: the sent or received bubble's own secondary role
    /// inside a bubble, and the native secondary label on the transcript surface beneath a sticker
    /// or a caption-less media card.
    private func metadataColor(onBubble: Bool) -> Color {
        onBubble ? bubblePolarity.secondaryContent : WNColor.messageReceivedSecondaryContent
    }

    /// The footer, in iOS's order: delivery marker, then the time (or the failure notice), then
    /// Edited. A message with its own finite expiry shows its twelve-step countdown just before the
    /// time. The chat's timer setting stays in the conversation header, and the exact expiry stays
    /// in the tooltip and the spoken label.
    private func compactMetadata(onBubble: Bool, isPlaceholder: Bool = false) -> some View {
        let tint = metadataColor(onBubble: onBubble)
        return HStack(spacing: 4) {
            if showsClusterFooter, MessageDeliveryMarker.systemImage(for: footerIndicator) != nil {
                MessageDeliveryMarker(indicator: footerIndicator)
                    // Only a real failure earns the alarm color, and a message some members may lack
                    // the warning color; an in-flight send stays in the metadata's own tint.
                    .foregroundStyle(
                        Self.deliveryMarkerColor(
                            for: footerIndicator,
                            isOutgoing: message.isOutgoing,
                            otherwise: tint
                        )
                    )
                    .help(deliveryMarkerHelp)
            }
            if showsFailureNotice {
                Text(L10n.string("Not delivered"))
                    .foregroundStyle(
                        Self.deliveryMarkerColor(for: .failed, isOutgoing: message.isOutgoing, otherwise: tint)
                    )
            }
            if let retentionCountdown {
                if isPlaceholder {
                    // Reserves the indicator's exact symbol frame without scheduling a second timeline.
                    Image(systemName: "circle")
                } else {
                    MessageRetentionIndicator(countdown: retentionCountdown)
                        .help(message.retentionExpirationLabel(locale: timestampLocale) ?? "")
                }
            }
            if showsFooterTime {
                Text(message.timeLabel(at: timestampReferenceDate, locale: timestampLocale))
                    .monospacedDigit()
                    .help(message.retentionExpirationLabel(locale: timestampLocale) ?? "")
            }
            if showsEditedLabel {
                Button(L10n.string("Edited")) { workspace.messagePendingEditHistory = message }
                    .buttonStyle(.plain)
                    .help(L10n.string("View edit history"))
            }
        }
        .font(MessageTypography.footer)
        .foregroundStyle(tint)
        .accessibilityLabel(
            message.metadataLabel(
                at: timestampReferenceDate,
                indicator: footerIndicator,
                locale: timestampLocale
            )
        )
    }
}

/// Keeps a run's hidden timestamp reachable: VoiceOver still reads it, and hovering the bubble
/// shows it as a tooltip — the pointer's answer to a footer only the run's last row draws.
private struct HiddenMessageMetadata: ViewModifier {
    let isHidden: Bool
    let label: String

    // No `if` around `content`: a run gaining a row flips the row above it, and a branch would
    // rebuild that bubble's whole subtree instead of updating it.
    func body(content: Content) -> some View {
        content
            .help(isHidden ? label : "")
            .overlay(alignment: .bottomTrailing) {
                if isHidden {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityRepresentation { Text(label) }
                        .allowsHitTesting(false)
                }
            }
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
    @State private var isVisibleInScrollView = false
    @State private var automaticDownloadTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        Group {
            if requiresScrollVisibility {
                content
                    // A tiny non-zero threshold means eager, non-lazy transcript rows do not
                    // auto-download until at least part of the tile intersects the ScrollView.
                    .onTranscriptVisibilityChange(threshold: 0.01) { isVisible in
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

/// The chat bubble's fill, in `MessageBubbleShape` — symmetric, and a capsule once the message is
/// short enough that half its height is the smaller radius.
///
/// The sent fill is the opaque inverted `fillPrimary`. The received fill is the native
/// `secondarySystemFill`, which always composites over the transcript's own opaque surface, so it
/// reads the same on every row. Neither carries a stroke. See `MessageBubblePolarity`.
private struct BubbleBackground: View {
    let polarity: MessageBubblePolarity

    var body: some View {
        MessageBubbleShape()
            .fill(polarity.fill)
    }
}

/// How a reply that carries images or videos is laid out: one bubble, quote on top, then the
/// media, then the caption — the iOS client's rich-media bubble. Audio and documents keep their
/// own rows above the bubble, as they do on iOS.
nonisolated enum MessageReplyMediaLayout {
    /// The gap between the bubble's edge and the media it wraps.
    static let outerInset: CGFloat = 6

    /// The wrapped media's corner radius: concentric with the bubble's, so the rim of bubble fill
    /// around the media is as thick at the corners as along the edges.
    static let innerCornerRadius = MessageBubbleShape.cornerRadius - outerInset

    static func embedsVisualMedia(hasReply: Bool, visualMediaCount: Int) -> Bool {
        hasReply && visualMediaCount > 0
    }
}

struct MessageImageGalleryPresentation: Identifiable, Equatable {
    let id: String
    let message: MessageItem
    let imageAttachments: [MessageMediaAttachment]
    let initialIndex: Int

    init?(message: MessageItem, initialAttachment: MessageMediaAttachment) {
        let imageAttachments = message.contentMediaAttachments.filter { $0.kind == .image }
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
    /// A standalone grid's own rounding; a bubble wrapping the grid passes its concentric radius.
    var cornerRadius: CGFloat = 10

    /// The grid's fixed width; a reply bubble that embeds the grid takes it as its content width.
    static let width: CGFloat = 360

    private let maxWidth = Self.width
    private let spacing: CGFloat = 3

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

    /// Only a GIF reads this: an off-screen tile stops animating.
    @State private var isVisible = false

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
        .onTranscriptVisibilityChange(threshold: 0.01) { isVisible = $0 }
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
                    .font(.title3.weight(.bold))
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
                    AttachmentGIFPlayback(
                        contentID: download.payload.id,
                        data: AttachmentGIF.isGIF(mediaType: attachment.mediaType) ? download.payload.data : nil,
                        isActive: isVisible
                    ) { frame in
                        (frame ?? image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: sideLength, height: sideLength)
                            .clipped()
                            .accessibilityLabel(attachment.fileName)
                    }
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
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WNColor.messageReceivedSecondaryContent)
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
        if let rejectionMessage = attachment.rejectionMessage {
            MessageAttachmentStatusRow(
                systemImage: "exclamationmark.triangle",
                title: L10n.string("Attachment"),
                detail: rejectionMessage,
                isOutgoing: isOutgoing,
                isLoading: false
            )
            .accessibilityIdentifier("message.media.attachment.\(attachment.id)")
        } else {
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
                isOutgoing: isOutgoing,
                openHandoff: documentHandoff
            )
        }
    }

    /// MDK's leased copy of this document's original slot, so another app opens a file with the
    /// attachment's real name rather than the host's own scratch export. Nil when MDK holds no slot
    /// for it — an own send still going out, or a record MDK did not resolve — and the row then
    /// opens the bytes it already has.
    private func documentHandoff(control: MediaFileTransferControlFfi) async throws -> AttachmentHandoffLease? {
        guard let target = attachment.localTarget(in: message),
            let runtime = workspace.client,
            let accountRef = workspace.activeAccount?.accountRef
        else { return nil }
        let workspace = workspace
        // Released through whichever runtime is open by then, not the one captured here.
        let releaser = LiveRuntimeHandoffReleaser { @MainActor [weak workspace] in
            workspace?.client.map { RuntimeHandoffReleaser(runtime: $0) }
        }
        return try await AttachmentHandoffOpening.openLease(
            runtime: runtime,
            accountRef: accountRef,
            groupIdHex: message.groupIdHex,
            target: target,
            control: control,
            releaser: releaser,
            hostHasBytes: true
        )
    }

    private func mediaDetail(_ download: MessageMediaDownload) -> String {
        download.detailText(fallbackMediaType: attachment.mediaType)
    }
}

/// Resolves a native macOS file-type icon via `UTType` and `NSWorkspace.shared.icon(for:)` (D02).
/// Used only for loaded document cards — never in place of a meaningful failed or loading state.
nonisolated enum AttachmentFileTypeIcon {
    static func contentType(mediaType: String, fileName: String) -> UTType {
        let trimmedMediaType = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMediaType.isEmpty,
            let mimeType = UTType(mimeType: trimmedMediaType),
            !mimeType.isDynamic
        {
            return mimeType
        }
        let ext = URL(fileURLWithPath: fileName).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, let extType = UTType(filenameExtension: ext) {
            return extType
        }
        return .data
    }

    static func icon(mediaType: String, fileName: String) -> NSImage {
        NSWorkspace.shared.icon(for: contentType(mediaType: mediaType, fileName: fileName))
    }
}

struct MessageDocumentAttachmentRow: View {
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool
    /// Opens MDK's handoff lease for this document; nil when MDK has no slot for it.
    var openHandoff: (MediaFileTransferControlFfi) async throws -> AttachmentHandoffLease? = { _ in nil }

    @State private var isOpening = false
    @State private var handoffControl: MediaFileTransferControlFfi?

    var body: some View {
        let resolvedFileName = download.fileName.nilIfBlank ?? attachment.fileName
        let resolvedMediaType = download.mediaType.nilIfBlank ?? attachment.mediaType
        // A finished document opens on click of the whole row — no trailing retry/download glyph
        // (the file is already in hand, especially for our own sends). A `Button` (not a tap
        // gesture) keeps it reachable by keyboard/VoiceOver.
        Button {
            guard !isOpening else { return }
            Task { await openAttachment() }
        } label: {
            MessageAttachmentStatusRow(
                systemImage: "doc",
                fileIcon: AttachmentFileTypeIcon.icon(mediaType: resolvedMediaType, fileName: resolvedFileName),
                title: resolvedFileName,
                detail: mediaDetail,
                isOutgoing: isOutgoing,
                isLoading: isOpening
            )
        }
        .buttonStyle(.plain)
        .help(L10n.string("Open"))
        // A copy still being written for a row that scrolled away is cancelled through its control,
        // never by cancelling the task awaiting it — that could drop a finished lease.
        .onDisappear { handoffControl?.cancel() }
    }

    private var mediaDetail: String {
        download.detailText(fallbackMediaType: attachment.mediaType)
    }

    @MainActor
    private func openAttachment() async {
        isOpening = true
        let control = MediaFileTransferControlFfi()
        handoffControl = control
        defer {
            isOpening = false
            if handoffControl === control { handoffControl = nil }
        }
        do {
            if let lease = try await openHandoff(control) {
                Self.open(lease)
                return
            }
        } catch is CancellationError {
            return
        } catch {
            // Fall through to the bytes this row already holds: the document is on screen, so the
            // host export still opens it even when MDK's copy could not be made.
        }
        await openHostExport()
    }

    /// `open` returns once LaunchServices accepts the handoff; the receiving app may still be
    /// reading the file. Release shortly after so the plaintext copy does not linger, while giving
    /// the app a window to read it. MDK wipes any copy still leased on the next launch.
    @MainActor
    private static func open(_ lease: AttachmentHandoffLease) {
        guard NSWorkspace.shared.open(lease.url) else {
            lease.release()
            return
        }
        let delay = Duration.seconds(cleanupDelaySeconds)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            lease.release()
        }
    }

    @MainActor
    private func openHostExport() async {
        guard
            let url = await MessageMediaPlaybackFileStore.handoffFileURL(
                attachment: attachment,
                download: download
            )
        else { return }
        // Delete shortly after so we don't leave decrypted plaintext on disk, while giving the
        // app a brief window to read the bytes. The whole handoff directory goes, so anything
        // the app wrote beside the file (Archive Utility's expanded `.zip`) goes with it.
        let didOpen = NSWorkspace.shared.open(url)
        let cleanupDelay: TimeInterval = didOpen ? Self.cleanupDelaySeconds : 0
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cleanupDelay) {
            MediaPlaybackTempStore.removeHandoff(at: url)
        }
    }

    private static let cleanupDelaySeconds: TimeInterval = 30
}

struct MessageAttachmentStatusRow: View {
    let systemImage: String
    /// Native macOS file-type icon for loaded documents (`D02`). Nil for loading, failed, or
    /// rejected rows so status glyphs are never replaced by a generic file thumbnail.
    var fileIcon: NSImage? = nil
    let title: String
    let detail: String
    let isOutgoing: Bool
    var isLoading = false
    var retryAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if !isLoading, let fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            } else {
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
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AttachmentRowPalette.detailContent(isOutgoing: isOutgoing))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retryAction {
                Button(action: retryAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help(L10n.string("Retry"))
                .accessibilityLabel(L10n.string("Retry"))
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AttachmentRowPalette.detailContent(isOutgoing: isOutgoing))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.audioRowWaveformCenter) { _ in Self.waveformHeight / 2 }

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
            .font(.caption2.weight(.bold))
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
                            .font(.subheadline.weight(.bold))
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
    @Environment(\.locale) private var locale
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackPreparationID: UUID?
    @State private var playbackProgress: CGFloat = 0
    @State private var metadata: MediaWaveformAnalyzer.Metadata?
    @State private var metadataPayloadID: String?
    @State private var waveformBars = ComposerAudioWaveformPresentation.fallbackPlaybackBars
    @State private var playbackMonitor: Task<Void, Never>?
    @State private var audioPlayerDelegate = MessageAudioPlayerDelegate()
    /// Per-row, like the iOS client's bubble: the speed a listener picked for one voice note is
    /// their reading of that note, not a preference to carry across the transcript.
    @State private var speed = AudioPlaybackSpeed.initial

    private var isPreparingPlayback: Bool {
        playbackPreparationID != nil
    }

    var body: some View {
        MessageAudioRow(
            bars: visibleWaveformBars,
            progress: playbackProgress,
            durationLabel: durationLabel,
            isOutgoing: isOutgoing,
            control: {
                Button {
                    Task { await togglePlayback() }
                } label: {
                    Image(systemName: isPlaying || isPreparingPlayback ? "stop.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .audioRowControlChrome(isOutgoing: isOutgoing)
                }
                .buttonStyle(.plain)
                .help(isPlaying || isPreparingPlayback ? L10n.string("Stop") : L10n.string("Play"))
            },
            speedControl: {
                Button(action: cycleSpeed) {
                    MessageAudioSpeedBadge(speed: speed, isOutgoing: isOutgoing)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Playback speed"))
                .accessibilityLabel(L10n.string("Playback speed"))
                .accessibilityValue(speed.label(locale: locale))
            }
        )
        // Transcript rows are intentionally eager, so scrolling this tile out of the viewport
        // does not trigger onDisappear. Stop playback here as well so the AVAudioPlayer and
        // progress monitor do not keep running offscreen.
        .onTranscriptVisibilityChange(threshold: 0.01) { isVisible in
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
            let loadedWaveformBars = ComposerAudioWaveformPresentation.bars(for: loaded.samples)
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
                    // `rate` is only honoured when rate control is armed before the player
                    // prepares its buffers, so the speed badge has to be enabled here — doing it
                    // on the first click of the badge is too late and leaves playback at 1x.
                    audioPlayer.enableRate = true
                    audioPlayer.prepareToPlay()
                    return PreparedMessageAudioPlayer(player: audioPlayer)
                }.value.player
                guard playbackPreparationID == nextPreparationID else { return }
                playbackPreparationID = nil
                player = preparedPlayer
                preparedPlayer.delegate = audioPlayerDelegate
            }
            audioPlayerDelegate.onDidFinishPlaying = handlePlaybackFinished
            applyPlaybackSpeed()
            player?.play()
            applyPlaybackSpeed()
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

    /// Advance the badge one step, wrapping 2x back to 1x, and make the new rate audible at once.
    ///
    /// Nothing is loaded on the first click of a row that has never played, and that is fine: the
    /// selection is remembered in `speed` and `startPlayback` applies it to the player it prepares.
    private func cycleSpeed() {
        speed = speed.next
        applyPlaybackSpeed()
        guard isPlaying else { return }
        // A rate assigned to an already-playing `AVAudioPlayer` does not always take until the
        // player is told to play again, and `play()` in turn can reset the rate to 1 — so the new
        // speed is applied on both sides of the call. Without this the change is inaudible until
        // the listener stops and restarts the note.
        player?.play()
        applyPlaybackSpeed()
    }

    private func applyPlaybackSpeed() {
        player?.rate = speed.rate
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
        .onTranscriptVisibilityChange(threshold: 0.01) { isVisible in
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
                .font(.title2.weight(.bold))
                .foregroundStyle(WNColor.fillContentQuaternary)
                .frame(width: 48, height: 48)
                .background(WNColor.overlayTertiary, in: Circle())

            VStack {
                Spacer()
                Text(download.fileName.nilIfBlank ?? attachment.fileName)
                    .font(.caption.weight(.semibold))
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
        await materialize(attachment: attachment, download: download, forHandoff: false)
    }

    /// Like `fileURL`, but for a file handed to another app: it lives in its own directory,
    /// which the caller deletes with `MediaPlaybackTempStore.removeHandoff(at:)`.
    @MainActor
    static func handoffFileURL(attachment: MessageMediaAttachment, download: MessageMediaDownload) async -> URL? {
        await materialize(attachment: attachment, download: download, forHandoff: true)
    }

    @MainActor
    private static func materialize(
        attachment: MessageMediaAttachment,
        download: MessageMediaDownload,
        forHandoff: Bool
    ) async -> URL? {
        let resolvedFileName = download.fileName.nilIfBlank ?? attachment.fileName
        let resolvedMediaType = download.mediaType.nilIfBlank ?? attachment.mediaType
        let attachmentID = attachment.id
        let data = download.payload.data

        return await Task.detached(priority: .utility) {
            do {
                let directory = try MediaPlaybackTempStore.directoryURL()
                if forHandoff {
                    return try MediaPlaybackTempStore.materializeHandoff(
                        data: data,
                        id: attachmentID,
                        mediaType: resolvedMediaType,
                        fileName: resolvedFileName,
                        directory: directory
                    )
                }
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
    @State private var zoom = ImageZoomState()

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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WNColor.fillContentQuaternary)
                            .lineLimit(1)

                        Spacer()

                        if canNavigate {
                            Text(verbatim: "\(selectedIndex + 1) / \(presentation.imageAttachments.count)")
                                .font(.caption.weight(.semibold).monospacedDigit())
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
                                            .font(.body.weight(.semibold))
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
                                .font(.body.weight(.semibold))
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
                            isEnabled: selectedIndex > 0 && !zoom.isZoomed
                        ) {
                            selectedIndex = max(0, selectedIndex - 1)
                        }
                        .keyboardShortcut(.leftArrow, modifiers: [])

                        Spacer()

                        navigationButton(
                            systemName: "chevron.right",
                            accessibilityLabel: L10n.string("Next image"),
                            isEnabled: selectedIndex < presentation.imageAttachments.count - 1
                                && !zoom.isZoomed
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
        // Paging out of a magnified photo would drop the next one in at someone else's
        // zoom, so each image starts fitted. Flutter suppresses paging entirely while
        // zoomed; the chevrons above disable for the same reason.
        .onChange(of: selectedIndex) { zoom.reset() }
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
                .font(.title.weight(.semibold))
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
                        .font(.title3)
                    Text(L10n.string("Image unavailable"))
                        .font(.subheadline.weight(.semibold))
                    Button {
                        Task { await workspace.loadMediaAttachment(attachment, for: message) }
                    } label: {
                        Label(L10n.string("Retry"), systemImage: "arrow.clockwise")
                    }
                    .wnSecondaryButtonStyle()
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
                .font(.subheadline.weight(.semibold))
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
    @Environment(\.composerFocusRequester) private var composerFocusRequester
    /// Owned by the bubble, so an open popover outlives this strip being rebuilt. See
    /// `MessageInlineActionPresentation`.
    @Binding var presentation: MessageInlineActionPresentation
    let message: MessageItem
    /// Receives the picked emoji; the bubble decides whether it reacts, retracts or confirms.
    let onReactionPick: (String) -> Void
    let moderation: MessageModerationActions
    var discardFailedSend: (() -> Void)?
    var customEmoji: CustomEmojiPickerContent?

    var body: some View {
        HStack(spacing: 4) {
            if message.canReact {
                Button {
                    presentation.setPresented(true, .reactionPicker, for: message.id)
                } label: {
                    MessageInlineActionIcon(systemName: "face.smiling", label: L10n.string("React"))
                }
                .buttonStyle(.plain)
                .popover(isPresented: isPresented(.reactionPicker), arrowEdge: .bottom) {
                    MessageEmojiPickerPopover(
                        selectedEmojis: MessageReactionPick.selectedEmojis(in: message.reactions),
                        customEmoji: customEmoji
                    ) { [message] emoji in
                        // Only the message that opened the picker takes its pick.
                        guard presentation.acceptsReactionPick(for: message.id) else { return }
                        presentation.setPresented(false, .reactionPicker, for: message.id)
                        onReactionPick(emoji)
                    }
                }
                .help(L10n.string("React"))
            }

            if message.canReply {
                Button {
                    workspace.startReply(to: message)
                    composerFocusRequester.request()
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
                    presentation.setPresented(true, .overflow, for: message.id)
                } label: {
                    MessageInlineActionIcon(systemName: "ellipsis", label: L10n.string("More"))
                }
                .buttonStyle(.plain)
                .popover(isPresented: isPresented(.overflow), arrowEdge: .bottom) {
                    MessageOverflowPopover(
                        message: message,
                        moderation: moderation,
                        discardFailedSend: discardFailedSend,
                        dismiss: { [message] in presentation.setPresented(false, .overflow, for: message.id) }
                    )
                }
                .help(L10n.string("More"))
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        // The strip can overhang a short bubble's row; pointing at that part keeps it up too.
        .onHover { presentation.isHoveringStrip = $0 }
        // Only the hover flag: an open popover belongs to the bubble and survives the strip.
        .onDisappear { presentation.isHoveringStrip = false }
    }

    /// A popover's `isPresented`, read from and written to the bubble's presentation for this
    /// message only.
    private func isPresented(_ popover: MessageInlineActionPresentation.Popover) -> Binding<Bool> {
        let presentation = $presentation
        let messageID = message.id
        return Binding(
            get: { presentation.wrappedValue.isPresented(popover, for: messageID) },
            set: { presentation.wrappedValue.setPresented($0, popover, for: messageID) }
        )
    }
}

struct MessageInlineActionIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    let systemName: String
    let label: String

    var body: some View {
        Image(systemName: systemName)
            .font(.body)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(
                isHovering ? WNColor.textPrimary : WNColor.messageReceivedSecondaryContent
            )
            .frame(width: 40, height: 40)
            .background {
                Circle()
                    .fill(isHovering ? WNColor.fillTertiaryHover : WNColor.fillTertiary)
                    .frame(width: 28, height: 28)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(label)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// The quick reactions, with the ones the viewing account already holds marked as selected.
/// Picking a selected emoji takes the reaction back (`MessageReactionPick`), so the mark is also
/// what tells the user a second click removes it.
struct QuickReactionButtons<Label: View>: View {
    enum Presentation {
        /// Plain buttons the caller styles; the label draws the selection.
        case palette
        /// Native menu items: a selected emoji carries the menu's own checkmark.
        case menu
    }

    let emojis: [String]
    let selectedEmojis: Set<String>
    let presentation: Presentation
    let onPick: (String) -> Void
    let label: (_ emoji: String, _ isSelected: Bool) -> Label

    init(
        emojis: [String],
        selectedEmojis: Set<String>,
        presentation: Presentation = .palette,
        onPick: @escaping (String) -> Void,
        @ViewBuilder label: @escaping (_ emoji: String, _ isSelected: Bool) -> Label
    ) {
        self.emojis = emojis
        self.selectedEmojis = selectedEmojis
        self.presentation = presentation
        self.onPick = onPick
        self.label = label
    }

    var body: some View {
        ForEach(emojis, id: \.self) { emoji in
            let isSelected = selectedEmojis.contains(emoji)
            Group {
                switch presentation {
                case .palette:
                    Button {
                        onPick(emoji)
                    } label: {
                        label(emoji, isSelected)
                    }
                case .menu:
                    Toggle(
                        isOn: Binding(get: { isSelected }, set: { _ in onPick(emoji) })
                    ) {
                        label(emoji, isSelected)
                    }
                }
            }
            // A selected emoji's control takes the reaction back, so it says so before activation.
            .accessibilityLabel(
                String(
                    format: isSelected ? L10n.string("Remove %@ reaction") : L10n.string("React with %@"),
                    emoji
                )
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

extension MessageReactionPick {
    /// Sends the pick: a new reaction, or the retraction of one the account already holds.
    @MainActor
    func perform(on message: MessageItem, in workspace: WorkspaceState) async {
        switch self {
        case .add(let emoji):
            await workspace.react(to: message, emoji: emoji)
        case .remove(let reaction):
            await workspace.removeReaction(reaction, from: message)
        }
    }
}

struct MessageEmojiPickerPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    /// The emoji the viewing account already reacted with, drawn selected.
    let selectedEmojis: Set<String>
    var customEmoji: CustomEmojiPickerContent?
    let onPick: (String) -> Void

    var body: some View {
        QuickReactionPicker(
            emojis: workspace.quickReactions, selectedEmojis: selectedEmojis,
            customEmoji: customEmoji, onPick: onPick)
    }
}

/// The quick-reaction strip with its "more emoji" control, taking the configured reactions as a
/// value so a view that cannot read the workspace — the reaction details popover — can offer the
/// same picker the hover React control does.
struct QuickReactionPicker: View {
    @State private var isFullPickerPresented = false
    @State private var isMoreHovering = false
    let emojis: [String]
    /// The emoji the viewing account already reacted with, drawn selected. Required, so no caller
    /// can offer the picker without the mark that tells a second click takes the reaction back.
    let selectedEmojis: Set<String>
    /// The conversation's custom emoji, offered in the full picker.
    var customEmoji: CustomEmojiPickerContent?
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            QuickReactionButtons(emojis: emojis, selectedEmojis: selectedEmojis, onPick: onPick) { emoji, isSelected in
                QuickReactionButtonLabel(emoji: emoji, isSelected: isSelected)
            }
            .buttonStyle(.plain)

            Button {
                isFullPickerPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WNColor.fillContentSecondary)
                    .frame(width: 32, height: 32)
                    .background(isMoreHovering ? WNColor.fillSecondaryHover : WNColor.fillSecondary, in: Circle())
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isMoreHovering = $0 }
            .help(L10n.string("More emoji"))
            .accessibilityLabel(L10n.string("More emoji"))
            .popover(isPresented: $isFullPickerPresented, arrowEdge: .bottom) {
                ChatEmojiPicker(custom: customEmoji) { emoji in
                    isFullPickerPresented = false
                    onPick(emoji)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct QuickReactionButtonLabel: View {
    @State private var isHovering = false
    let emoji: String
    let isSelected: Bool

    var body: some View {
        Text(emoji)
            .font(.title2)
            .frame(width: 36, height: 36)
            .background {
                if isSelected {
                    // The same selected pair the reaction chip under the bubble uses, so
                    // the menu and the chip agree about which emoji is yours.
                    Circle()
                        .fill(WNColor.fillSecondaryActive)
                        .overlay {
                            Circle().strokeBorder(WNColor.borderPrimary, lineWidth: 1)
                        }
                } else if isHovering {
                    Circle()
                        .fill(WNColor.fillTertiaryHover)
                }
            }
            .contentShape(Circle())
            .onHover { isHovering = $0 }
    }
}

/// The actions available on a message row, gated by message and conversation capabilities.
/// Centralised here so both presentations — the native
/// `.contextMenu` (`MessageContextMenuItems`) and the inline hover popover
/// (`MessageOverflowPopover`) — share one source of truth for which actions exist and what
/// they do, while each keeps its own button styling.
struct MessageRowAction: Identifiable {
    enum Kind { case retry, info, select, forward, edit, copy, report, block, delete }

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
        moderation: MessageModerationActions? = nil,
        discardFailedSend: (() -> Void)? = nil,
        focusComposer: @escaping () -> Void = {},
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
                    focusComposer()
                })
        }
        if message.canCopyText {
            actions.append(
                MessageRowAction(kind: .copy, title: L10n.string("Copy Text"), systemImage: "doc.on.doc", role: nil) {
                    workspace.copyText(of: message)
                    dismiss()
                })
        }
        if let moderation, moderation.eligibility.canReport {
            actions.append(
                MessageRowAction(
                    kind: .report,
                    title: L10n.string("Report"),
                    systemImage: "exclamationmark.bubble",
                    role: nil
                ) {
                    dismiss()
                    moderation.report()
                })
        }
        if let moderation, moderation.eligibility.canBlockAuthor {
            actions.append(
                MessageRowAction(
                    kind: .block,
                    title: L10n.string("Block User"),
                    systemImage: "hand.raised",
                    role: .destructive
                ) {
                    dismiss()
                    moderation.block()
                })
        }
        if message.isLocalPublishFailure, let discardFailedSend {
            // "Remove", as for a staged send that never got out: nobody received this message, so
            // it is discarded here without a delete for everyone and without that confirmation.
            actions.append(
                MessageRowAction(kind: .delete, title: L10n.string("Remove"), systemImage: "trash", role: .destructive)
                {
                    dismiss()
                    discardFailedSend()
                })
        } else if workspace.canDeleteMessage(message) {
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

/// Removes a failed own send for the row menu and the selection toolbar alike: discarded on this
/// device through the conversation model, with its own decrypted media dropped from the host cache
/// and any failure on the error line.
@MainActor
enum FailedSendDiscard {
    static func run(_ message: MessageItem, model: ConversationViewModel, workspace: WorkspaceState) async {
        let failure = await model.discardFailedSend(messageIdHex: message.id) { [cache = workspace.mediaDiskCache] in
            await cache.purgeEntries(accountId: model.account.id, ciphertextSha256s: $0)
        }
        if let failure { workspace.reportUserActionError(failure) }
    }
}

struct MessageOverflowPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.composerFocusRequester) private var composerFocusRequester
    let message: MessageItem
    let moderation: MessageModerationActions
    var discardFailedSend: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        MessageOverflowMenu(
            actions: MessageRowAction.all(
                for: message,
                workspace: workspace,
                moderation: moderation,
                discardFailedSend: discardFailedSend,
                focusComposer: composerFocusRequester.request,
                dismiss: dismiss
            )
        )
    }
}

/// The popover body behind the ⋯ control: a list of `MessageRowAction`s in the transcript's own
/// menu chrome.
///
/// Split from `MessageOverflowPopover` so the staged-media bubble
/// (`PendingOutgoingMessageOverflowButton`) opens the same menu rather than a lookalike — it
/// builds its actions from a message the core has never seen, but a failed row is a failed row and
/// the two must not drift into different shapes.
/// Partitions message actions into non-destructive and destructive groups while preserving relative
/// order within each group (K02, K03).
nonisolated enum MessageRowActionGrouping {
    static func split(_ actions: [MessageRowAction]) -> (standard: [MessageRowAction], destructive: [MessageRowAction])
    {
        (
            standard: actions.filter { $0.role != .destructive },
            destructive: actions.filter { $0.role == .destructive }
        )
    }
}

struct MessageOverflowMenu: View {
    let actions: [MessageRowAction]

    var body: some View {
        let grouped = MessageRowActionGrouping.split(actions)
        VStack(spacing: 2) {
            ForEach(grouped.standard) { action in
                MessageOverflowMenuItem(action: action)
            }
            if !grouped.standard.isEmpty, !grouped.destructive.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            }
            ForEach(grouped.destructive) { action in
                MessageOverflowMenuItem(action: action)
            }
        }
        .padding(6)
        .frame(width: 196)
    }
}

private struct MessageOverflowMenuItem: View {
    @State private var isHovering = false
    let action: MessageRowAction

    var body: some View {
        Button(role: action.role, action: action.run) {
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .frame(width: 18)
                Text(action.title)
                Spacer(minLength: 0)
            }
            .font(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? WNColor.fillTertiaryHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            action.role == .destructive
                ? WNColor.intentionErrorContent : WNColor.textPrimary
        )
        .onHover { isHovering = $0 }
    }
}

/// The right-click menu for a chat bubble. The reaction submenu and hover popover both render
/// `QuickReactionButtons` from the workspace preference, while the remaining actions mirror the
/// hover bar's overflow (`MessageRowAction.all`).
///
/// React, Reply and Download are built here rather than in `MessageRowAction.all`: all three also sit in the
/// hover bar as controls of their own, and `.all` backs the bar's overflow popover, so routing
/// them through it would show each of them twice, inches apart.
struct MessageContextMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.composerFocusRequester) private var composerFocusRequester
    let message: MessageItem
    /// Receives the picked emoji; the bubble decides whether it reacts, retracts or confirms.
    let onReactionPick: (String) -> Void
    let moderation: MessageModerationActions
    var discardFailedSend: (() -> Void)?

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
                        emojis: workspace.quickReactions,
                        selectedEmojis: MessageReactionPick.selectedEmojis(in: message.reactions),
                        presentation: .menu,
                        onPick: onReactionPick
                    ) { emoji, _ in
                        Text(emoji)
                    }
                } label: {
                    Label(L10n.string("React"), systemImage: "face.smiling")
                }
            }

            // The hover bar's Reply is only there while the pointer is on the row; the menu is the
            // path that does not depend on hovering (keyboard, VoiceOver, a trackpad right-click).
            // Deliberately not a `MessageRowAction`: the hover bar's overflow popover sits beside
            // its own Reply button and would offer it twice.
            if message.canReply {
                Button {
                    workspace.startReply(to: message)
                    composerFocusRequester.request()
                } label: {
                    Label(L10n.string("Reply"), systemImage: "arrowshape.turn.up.left")
                }
            }

            if message.canReact || message.canReply {
                Divider()
            }

            let grouped = MessageRowActionGrouping.split(
                MessageRowAction.all(
                    for: message,
                    workspace: workspace,
                    moderation: moderation,
                    discardFailedSend: discardFailedSend,
                    focusComposer: composerFocusRequester.request
                )
            )

            ForEach(grouped.standard) { action in
                Button(role: action.role, action: action.run) {
                    Label(action.title, systemImage: action.systemImage)
                }
            }

            if !grouped.standard.isEmpty, !grouped.destructive.isEmpty {
                Divider()
            }

            ForEach(grouped.destructive) { action in
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
    /// Stretch the card to the width it is offered — set when it heads media, so the quote spans
    /// the grid under it instead of hugging its text. A text bubble leaves it off, or a short quote
    /// would widen the bubble to its maximum.
    var fillsWidth = false
    let onOpen: () -> Void

    private var polarity: MessageBubblePolarity {
        MessageBubblePolarity(isOutgoing: isOutgoing)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(polarity.secondaryContent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    // The quoted author at full strength and the quoted words one step down, so
                    // the quote reads as someone else's message and not as part of this one.
                    Text(context.senderName)
                        .font(MessageTypography.quoteSender)
                        .foregroundStyle(polarity.content)
                        .lineLimit(1)

                    Text(context.body)
                        .font(MessageTypography.quoteBody)
                        .foregroundStyle(polarity.secondaryContent)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            // A plain button hit-tests only the pixels its label draws, so without this the gaps
            // between the lines and beside a short name miss — on every quote, not only a
            // stretched one.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.string("Show replied-to message"))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // An inset one step into the bubble it sits in, not a window-colored card: on the sent
        // bubble that is the opposite polarity from the window, so the quote's text takes the
        // bubble's own pair rather than a generic label color (T02, T07).
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(polarity.quoteFill)
        }
    }
}

struct TimelineDayHeaderView: View {
    let title: String

    var body: some View {
        HStack {
            Spacer(minLength: 24)
            Text(title)
                .font(MessageTypography.dayDivider)
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

#if DEBUG
    #Preview("Attachment rows – Polarities") {
        VStack(alignment: .leading, spacing: 12) {
            MessageAttachmentStatusRow(
                systemImage: "doc",
                fileIcon: AttachmentFileTypeIcon.icon(mediaType: "application/pdf", fileName: "architecture.pdf"),
                title: "architecture.pdf",
                detail: "2.4 MB",
                isOutgoing: false
            )
            MessageAttachmentStatusRow(
                systemImage: "doc",
                fileIcon: AttachmentFileTypeIcon.icon(mediaType: "application/pdf", fileName: "architecture.pdf"),
                title: "architecture.pdf",
                detail: "2.4 MB",
                isOutgoing: true
            )
            MessageAttachmentStatusRow(
                systemImage: "exclamationmark.triangle",
                title: "missing.zip",
                detail: L10n.string("Attachment unavailable"),
                isOutgoing: false,
                retryAction: {}
            )
            MessageAudioAttachmentPlaceholder(
                isOutgoing: true,
                accessibilityLabel: "Voice message"
            )
        }
        .padding()
        .background(WNColor.backgroundPrimary)
    }

    #Preview("Message actions & quick reactions") {
        VStack(spacing: 16) {
            QuickReactionPicker(
                emojis: ChatReactionDefaults.quick,
                selectedEmojis: ["👍"],
                onPick: { _ in }
            )
            MessageOverflowMenu(
                actions: [
                    MessageRowAction(kind: .info, title: "Message Info", systemImage: "info.circle", role: nil) {},
                    MessageRowAction(kind: .copy, title: "Copy Text", systemImage: "doc.on.doc", role: nil) {},
                    MessageRowAction(kind: .delete, title: "Delete", systemImage: "trash", role: .destructive) {},
                ]
            )
        }
        .padding()
    }
#endif
