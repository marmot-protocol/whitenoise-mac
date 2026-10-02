import AVFoundation
import AVKit
import AppKit
import CoreImage
import ImageIO
import MarmotKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct MessengerShellView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session

    private var productScreen: ProductScreen? {
        guard workspace.phase == .ready, workspace.activeAccount != nil else { return nil }
        switch workspace.selection {
        case .settings:
            return .settings
        case .chat:
            return workspace.selectedChat == nil ? .inbox : .conversation
        case nil:
            return .inbox
        }
    }

    var body: some View {
        let ignoredEdges: Edge.Set = workspace.showsMessengerChrome ? .top : []

        VStack(spacing: 0) {
            // Laid out above the content rather than floating over it: being offline is a
            // standing condition, and a card on this edge sits on the pane title and the
            // conversation header for as long as it lasts. Outside the `showsMessengerChrome`
            // branch so it also reaches the onboarding and login surfaces, which is where a
            // user with no network is most likely to be stuck.
            if workspace.isOffline {
                OfflineNoticeBand()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if workspace.showsMessengerChrome {
                    HStack(spacing: 0) {
                        AccountRailView()
                        GlassSeparator()

                        Group {
                            if workspace.isChatListVisible {
                                ChatListDrawerView(
                                    model: session.accountScope?.chatListModel,
                                    historyNotices: session.accountScope?.historyNotices
                                )
                                // Deliberately un-animated: the width is dragged, so animating
                                // it would re-wrap the non-lazy transcript on every frame of the
                                // drag *and* again through the collapse snap — the same layout
                                // storm the `isChatListVisible` transition below is scoped away
                                // from. The snap is a single jump instead.
                                .frame(width: workspace.chatListDrawerWidth, alignment: .leading)
                                .transition(.move(edge: .leading).combined(with: .opacity))

                                ChatListResizeHandle()
                                    .transition(.opacity)
                                    // The handle's grab area is an overlay reaching a few points
                                    // into both neighbours, and later siblings in an `HStack` are
                                    // hit-tested first — without this the detail pane would swallow
                                    // the right half of the strip and the divider would only be
                                    // grabbable from the drawer side.
                                    .zIndex(1)
                            }
                        }
                        // Scope the sidebar transition to the drawer. The detail pane
                        // width should jump once, not animate through every intermediate
                        // width and force the non-lazy transcript to re-wrap each frame.
                        .animation(.smooth(duration: 0.18), value: workspace.isChatListVisible)

                        DetailPaneView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    DetailPaneView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // A dismissible, transient failure keeps floating over the content instead of
            // shifting the transcript down and back up for a few seconds. It hangs off the top
            // of the content, which the band above has already moved, so the two cannot
            // collide the way two views claiming the same edge would.
            .overlay(alignment: .top) {
                BackgroundStatusBanner()
            }
        }
        .background {
            MessagesWindowBackground()
        }
        // The band has taken the strip the traffic lights float in, so the headers it pushed
        // down must drop the clearance they keep for those buttons.
        .environment(\.hasWindowTopNoticeBand, workspace.isOffline)
        .animation(.smooth(duration: 0.2), value: workspace.isOffline)
        // Above the conversation pane rather than inside it: the image gallery is an overlay on
        // the transcript, and a download started from the gallery has to confirm itself over the
        // gallery, not underneath it.
        .overlay(alignment: .bottomLeading) {
            MediaDownloadFeedbackToast()
        }
        .ignoresSafeArea(.container, edges: ignoredEdges)
        .task(id: productScreen) {
            guard let productScreen else { return }
            session.accountScope?.productAnalytics.record(.screen(productScreen))
        }
    }
}

private struct DetailPaneView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session

    var body: some View {
        Group {
            switch workspace.phase {
            case .bootstrapping:
                StartupView()
            case .onboarding:
                OnboardingView(model: session.accountScope?.onboarding)
            case .failed(let message):
                FailureView(message: message)
            case .ready:
                if workspace.activeAccount == nil {
                    // Nothing is signed in, so there is nothing to show but the way in. This used
                    // to be a `SignedOutAccountsView` listing the deactivated identities on this
                    // Mac, each one a single click from being reactivated — a sign-in that asked
                    // for no key. Getting into an identity is Sign In or Sign Up now, both of
                    // which `OnboardingView` already owns, and the core reactivates a matching
                    // signed-out account on login rather than creating a second one, so the
                    // stored chats come back with it.
                    //
                    // Defensive: the state paths that empty the signed-in list — `bootstrap()`,
                    // `signOutAccount`, `removeAccount` — all move to `.onboarding` themselves,
                    // so this branch should be unreachable. It renders the same surface as that
                    // phase rather than a blank pane if one is ever missed.
                    OnboardingView(model: session.accountScope?.onboarding)
                } else {
                    switch workspace.selection {
                    case .chat:
                        if let chat = workspace.selectedChat,
                            let model = session.accountScope?.selectedConversationModel,
                            model.groupIdHex == chat.id,
                            let scope = session.accountScope
                        {
                            ConversationView(
                                chat: chat,
                                model: model,
                                chatListModel: scope.chatListModel,
                                attachmentModel: scope.attachmentModel(groupIdHex: chat.id),
                                safetyModel: scope.safetyModel(groupIdHex: chat.id),
                                blockedUsersModel: scope.blockedUsers
                            )
                        } else {
                            EmptyDetailView()
                        }
                    case .settings:
                        if let model = session.accountScope?.settingsModel {
                            SettingsPanelView(model: model)
                        } else {
                            EmptyDetailView()
                        }
                    case nil:
                        EmptyDetailView()
                    }
                }
            }
        }
        .task(id: session.accountScope?.onboarding.snapshot?.revision) {
            guard workspace.phase == .onboarding,
                session.accountScope?.onboarding.isDurablyReady == true,
                workspace.activeAccount != nil
            else { return }
            let enteredAccountIdHex = workspace.activeAccount?.accountIdHex
            await workspace.activateReadyState()
            workspace.presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: enteredAccountIdHex)
        }
    }
}

/// A history page the transcript should load for the messages on screen.
nonisolated struct TimelinePageRequest: Equatable {
    let direction: ConversationPageDirectionFfi
    /// The top visible message, reported to MarmotKit with `set_visible_anchor` before paging.
    let visibleAnchorMessageId: String
}

/// Older history when a visible message is within `edgeRows` of the window's first row, newer
/// when one is within `edgeRows` of its last; older wins when both are due, and the next
/// visibility report asks for the other. Decided from which messages are on screen, not from
/// pixel distances, so it reads the same however tall the rows are.
func timelinePageRequest(
    visibleMessageIds: Set<String>,
    messageIDs: [String],
    hasMoreBefore: Bool,
    hasMoreAfter: Bool,
    edgeRows: Int = 15
) -> TimelinePageRequest? {
    let visibleIndices = messageIDs.indices.filter { visibleMessageIds.contains(messageIDs[$0]) }
    guard let first = visibleIndices.first, let last = visibleIndices.last else { return nil }
    let anchor = messageIDs[first]
    if hasMoreBefore, first < edgeRows {
        return TimelinePageRequest(direction: .older, visibleAnchorMessageId: anchor)
    }
    if hasMoreAfter, last >= messageIDs.count - edgeRows {
        return TimelinePageRequest(direction: .newer, visibleAnchorMessageId: anchor)
    }
    return nil
}

/// The visible messages the reader has reached, for read marking. The bottom-most visible message
/// is only partly on screen unless the transcript is at its foot — a tall message being read, or
/// the next one peeking in — so it counts once the reader reaches the bottom or a later message
/// comes into view.
func timelineReadableMessageIds(
    visibleMessageIds: Set<String>,
    messageIDs: [String],
    isAtBottom: Bool
) -> Set<String> {
    guard !isAtBottom, let lowest = messageIDs.last(where: visibleMessageIds.contains) else {
        return visibleMessageIds
    }
    return visibleMessageIds.subtracting([lowest])
}

/// What reaching the foot of the window should do. A window that ends before the newest message
/// loads the next page; one that ends at it but retains an anchor (an unread open, a jump, a page
/// that reported a visible anchor) is re-attached to the tail, or later arrivals would only flip
/// `hasMoreAfter` and the reader would sit at a foot that never grows.
nonisolated enum TimelineFootAction: Equatable {
    case none
    case loadNewer
    case returnToLatest
}

func timelineFootAction(isAtBottom: Bool, hasMoreAfter: Bool, isFollowingTail: Bool) -> TimelineFootAction {
    guard isAtBottom else { return .none }
    if hasMoreAfter { return .loadNewer }
    return isFollowingTail ? .none : .returnToLatest
}

/// What a transcript row's height depends on beyond its own message: anything here changing
/// re-measures the row. Kept in the row value so the table's height cache sees it.
nonisolated struct TranscriptRowContext: Equatable {
    let canVoteInPolls: Bool
    let showsDebugMetadata: Bool
    let isSelectionMode: Bool
    let localeIdentifier: String
    let referenceDay: Int
}

/// One row of the transcript table.
nonisolated enum TranscriptRow: Identifiable, Equatable {
    case loadingOlder(isLoading: Bool)
    case message(TimelineMessageDisplayItem, showsUnreadDivider: Bool, context: TranscriptRowContext)
    case loadingNewer(isLoading: Bool)
    case pending(PendingOutgoingMessageRow)
    case footer

    /// Loading indicators and the foot do not travel with the messages, so they never anchor the
    /// reader's position (`TranscriptTableView.anchorsPosition`).
    var anchorsPosition: Bool {
        switch self {
        case .message, .pending: true
        case .loadingOlder, .loadingNewer, .footer: false
        }
    }

    var id: String {
        switch self {
        case .loadingOlder: "transcript-loading-older"
        case .message(let item, _, _): item.message.id
        case .loadingNewer: "transcript-loading-newer"
        case .pending(let row): "transcript-pending-\(row.id.uuidString)"
        case .footer: "transcript-footer"
        }
    }

    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        switch (lhs, rhs) {
        case (.loadingOlder(let a), .loadingOlder(let b)), (.loadingNewer(let a), .loadingNewer(let b)):
            return a == b
        case (.message(let a, let dividerA, let contextA), .message(let b, let dividerB, let contextB)):
            return a.message == b.message && a.dayLabel == b.dayLabel && dividerA == dividerB
                && contextA == contextB
        case (.pending(let a), .pending(let b)):
            return a == b
        case (.footer, .footer):
            return true
        default:
            return false
        }
    }

    /// The transcript's rows: the window's messages between its loading indicators, then the
    /// messages still being sent, then the foot.
    static func rows(
        displayItems: [TimelineMessageDisplayItem],
        paging: TimelinePagingState,
        pendingOutgoingRows: [PendingOutgoingMessageRow],
        unreadDividerMessageId: String?,
        context: TranscriptRowContext
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(displayItems.count + pendingOutgoingRows.count + 3)
        if paging.hasMoreBefore { rows.append(.loadingOlder(isLoading: paging.isLoadingBefore)) }
        for item in displayItems {
            rows.append(
                .message(item, showsUnreadDivider: item.message.id == unreadDividerMessageId, context: context))
        }
        if paging.hasMoreAfter { rows.append(.loadingNewer(isLoading: paging.isLoadingAfter)) }
        rows += pendingOutgoingRows.map(TranscriptRow.pending)
        rows.append(.footer)
        return rows
    }
}

/// One transcript row's SwiftUI content, hosted in a table cell. A cell's `NSHostingView` does not
/// inherit the conversation's environment, so everything the rows read is passed in and applied
/// here — including the transcript's `.textSelection(.disabled)`, which bubbles re-enable on hover.
private struct TranscriptRowCell: View {
    let row: TranscriptRow
    let workspace: WorkspaceState
    let session: SessionState
    let safetyModel: GroupSafetyViewModel
    let conversationModel: ConversationViewModel
    let locale: Locale
    let timestampReferenceDate: Date
    let openURL: OpenURLAction
    let hoverSelectionCoordinator: ConversationHoverSelectionCoordinator
    let composerFocusRequester: ComposerFocusRequester
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void
    let onNavigateToMessage: (String) -> Void

    var body: some View {
        Group {
            switch row {
            case .loadingOlder(let isLoading), .loadingNewer(let isLoading):
                TimelinePageLoadingRow(isLoading: isLoading)
            case .message(let item, let showsUnreadDivider, let context):
                VStack(spacing: 12) {
                    if showsUnreadDivider {
                        UnreadMessagesDivider()
                    }
                    if let dayLabel = item.dayLabel {
                        TimelineDayHeaderView(title: dayLabel)
                    }
                    ConversationMessageRow(
                        message: item.message,
                        safetyModel: safetyModel,
                        conversationModel: conversationModel,
                        canVoteInPolls: context.canVoteInPolls,
                        showsDebugMetadata: context.showsDebugMetadata,
                        timestampReferenceDate: timestampReferenceDate,
                        timestampLocale: locale,
                        onOpenImageGallery: onOpenImageGallery,
                        onNavigateToMessage: onNavigateToMessage
                    )
                }
            case .pending(.text(let message)):
                PendingOutgoingTextBubble(
                    message: message,
                    timestampReferenceDate: timestampReferenceDate,
                    timestampLocale: locale
                )
            case .pending(.media(let message)):
                PendingOutgoingMessageBubble(
                    message: message,
                    timestampReferenceDate: timestampReferenceDate,
                    timestampLocale: locale
                )
            case .footer:
                Color.clear.frame(height: 28)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .textSelection(.disabled)
        .tint(WNColor.fillPrimary)
        .foregroundStyle(WNColor.backgroundContentPrimary)
        .environment(workspace)
        .environment(session)
        .environment(\.locale, locale)
        .environment(\.timestampReferenceDate, timestampReferenceDate)
        .environment(\.openURL, openURL)
        .environment(\.conversationHoverSelectionCoordinator, hoverSelectionCoordinator)
        .environment(\.composerFocusRequester, composerFocusRequester)
    }
}

private struct TranscriptOpeningKey: Equatable {
    let chatId: String
    let model: ObjectIdentifier
    let hasPresentedWindow: Bool
}

private struct PendingNavigationKey: Equatable {
    let requestId: UUID?
    let hasPresentedWindow: Bool
}

private struct ConversationView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    @Environment(\.timestampReferenceDate) private var timestampReferenceDate
    @Environment(\.openURL) private var openURL
    @Environment(SessionState.self) private var session
    /// Whether the transcript is scrolled to the foot of its content, as the table reports it.
    @State private var isPinnedToBottom = false
    /// The pending scroll command for the transcript table, applied once per request id.
    @State private var scrollRequest: TranscriptScrollRequest?
    /// The open's starting scroll (the unread divider, the newest message, or a search target).
    /// The open has landed once the table confirms it applied this request; until then neither
    /// paging nor read marking acts on what is on screen.
    @State private var openingRequestId: UUID?
    @State private var hasLanded = false
    /// The model whose opening position has been applied; a new open gets its own.
    @State private var openedModel: ObjectIdentifier?
    @State private var isFileImporterPresented = false
    @State private var isPollComposerPresented = false
    @State private var isFileDropTargeted = false
    @State private var isComposerEmojiPickerPresented = false
    @State private var composerEmojiInsertion: ComposerEmojiInsertion?
    @State private var composerMentionContext: ComposerMentionContext?
    /// The picker row Tab or Return would take. Back to the top whenever the "@query" changes.
    @State private var mentionHighlightIndex = 0
    @State private var composerMentionInsertion: ComposerMentionInsertion?
    @State private var imageGallery: MessageImageGalleryPresentation?
    /// Hover-scoped text-selection gate for chat bubbles. Not read by `body` — bubbles
    /// register local `isSelectable` state so hover only updates the previous and active row
    /// (whitenoise-mac#397).
    @State private var hoverSelectionCoordinator = ConversationHoverSelectionCoordinator()
    @State private var composerFocusRequester = ComposerFocusRequester()
    /// True during a live scroll (the user dragging or flinging). Read marking waits for it to end.
    @State private var isActivelyScrolling = false
    let chat: ChatItem
    let model: ConversationViewModel
    let chatListModel: ChatListViewModel
    let attachmentModel: AttachmentViewModel
    let safetyModel: GroupSafetyViewModel
    let blockedUsersModel: BlockedUsersViewModel

    private var isBlockedDirectPeer: Bool {
        chat.directPeerAccountIdHex.map {
            blockedUsersModel.isBlocked(accountID: $0)
        } ?? false
    }

    private var canUseComposer: Bool {
        chat.canUseComposer && !isBlockedDirectPeer
    }

    var body: some View {
        @Bindable var workspace = workspace
        let displayItems = workspace.selectedTimelineDisplayItems
        let messageIDs = workspace.selectedMessageIDs
        let paging = workspace.selectedTimelinePaging
        let isLoadingInitialPage = workspace.selectedTimelineIsLoadingInitialPage
        let pendingOutgoingRows = workspace.selectedPendingOutgoingMessageRows
        let transcriptRows = TranscriptRow.rows(
            displayItems: displayItems,
            paging: paging,
            pendingOutgoingRows: pendingOutgoingRows,
            unreadDividerMessageId: model.unreadDivider?.messageIdHex,
            context: TranscriptRowContext(
                canVoteInPolls: canUseComposer,
                showsDebugMetadata: workspace.streamingDebugEnabled,
                isSelectionMode: workspace.isTimelineSelectionMode,
                localeIdentifier: locale.identifier,
                referenceDay: Calendar.current.ordinality(of: .day, in: .era, for: timestampReferenceDate) ?? 0
            )
        )

        ZStack {
            VStack(spacing: 0) {
                ConversationHeader(chat: chat)
                    .messageDeletionConfirmation()
                    .messageEditHistory(model: model)
                GlassSeparator(axis: .horizontal)

                Group {
                    if messageIDs.isEmpty && pendingOutgoingRows.isEmpty {
                        VStack {
                            if isLoadingInitialPage {
                                TimelineInitialLoadingView()
                            } else {
                                EmptyConversationView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // An `NSTableView`: rows measured once and cached, only visible rows
                        // hosted, and the reader's row held in place by explicit offset arithmetic
                        // whenever the window changes — see `TranscriptTableView`.
                        TranscriptTableView(
                            rows: transcriptRows,
                            scrollRequest: scrollRequest,
                            // Pin the foot only while the reader follows the live edge.
                            followsBottom: hasLanded && !paging.hasMoreAfter,
                            onViewportChanged: viewportChanged,
                            onLiveScrollChanged: { isScrolling in
                                isActivelyScrolling = isScrolling
                                if !isScrolling { markVisibleMessagesRead() }
                            },
                            onScrollRequestApplied: scrollRequestApplied,
                            anchorsPosition: \.anchorsPosition,
                            cell: { row in
                                TranscriptRowCell(
                                    row: row,
                                    workspace: workspace,
                                    session: session,
                                    safetyModel: safetyModel,
                                    conversationModel: model,
                                    locale: locale,
                                    timestampReferenceDate: timestampReferenceDate,
                                    openURL: openURL,
                                    hoverSelectionCoordinator: hoverSelectionCoordinator,
                                    composerFocusRequester: composerFocusRequester
                                ) { gallery in
                                    imageGallery = gallery
                                } onNavigateToMessage: { targetMessageId in
                                    Task { await revealMessage(targetMessageId) }
                                }
                            }
                        )
                    }
                }
                .accessibilityIdentifier("conversation.transcript")
                .id(chat.id)
                // An arrival into a window the reader is at the foot of can change only
                // `hasMoreAfter`, with no row or viewport change to react to.
                .onChange(of: paging.hasMoreAfter) { _, _ in
                    handleFoot()
                }
                // Switching chats resets the per-chat state in the same handler that opens the
                // new window: a cached model can arrive already presented, in the same update as
                // the new chat id, and SwiftUI does not order two `onChange` handlers, so a
                // separate reset could run after the opening and leave the chat unlanded.
                .onChange(
                    of: TranscriptOpeningKey(
                        chatId: chat.id,
                        model: ObjectIdentifier(model),
                        hasPresentedWindow: model.hasPresentedWindow
                    ),
                    initial: true
                ) { previous, key in
                    if previous.chatId != key.chatId { resetForNewChat() }
                    applyOpeningPosition(key)
                }
                // Opening a chat puts the caret in its composer, ready to type. A chat with no
                // composer (pending invite, membership ended) leaves the request pending until
                // one appears.
                .onChange(of: chat.id, initial: true) { _, _ in
                    composerFocusRequester.request()
                }
                // Pressing Send scrolls to the live edge, off the send itself rather than off
                // the message it produces. Arrivals while following are pinned by the table, and
                // a new last row is not a send: a newer history page can end in an old message of
                // the reader's own. A window detached from the live edge is re-attached first,
                // the same path the jump-to-latest button takes. GIF and poll sends bypass
                // `sendDraft()` and call `jumpToNewest()` themselves.
                .onChange(of: workspace.outgoingSendScrollGeneration) { _, _ in
                    guard workspace.selectedChat?.id == chat.id else { return }
                    Task { await jumpToNewest() }
                }
                // Keyed on the window being presented too: a search can open a chat whose
                // projection has not delivered its first window, and the jump to the target
                // needs that window's revision. The task reruns once it is on screen.
                .task(
                    id: PendingNavigationKey(
                        requestId: workspace.pendingMessageNavigation?.requestId,
                        hasPresentedWindow: model.hasPresentedWindow
                    )
                ) {
                    guard model.hasPresentedWindow,
                        let target = workspace.pendingMessageNavigation,
                        target.groupId == chat.id
                    else { return }
                    let requestId = await revealMessage(target.messageId)
                    if !hasLanded {
                        if let requestId {
                            openingRequestId = requestId
                        } else {
                            // The jump could not bring the target into the window; the open
                            // stands where it is.
                            land()
                        }
                    }
                    workspace.completePendingMessageNavigation(target)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasLanded && !isPinnedToBottom {
                        Button {
                            Task { await jumpToNewest() }
                        } label: {
                            Image(systemName: "arrow.down")
                                .wnFont(.bold14)
                                .frame(width: 40, height: 40)
                                .background(.regularMaterial, in: Circle())
                                .overlay {
                                    Circle().strokeBorder(WNColor.borderTertiary, lineWidth: 1)
                                }
                                .shadow(color: WNColor.shadow.opacity(0.1), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Jump to latest message"))
                        .padding(18)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }

                GlassSeparator(axis: .horizontal)

                VStack(spacing: 8) {
                    // The core rejects sends to a group the local account left or was
                    // removed from (`invalid_transition`), so the whole composer —
                    // reply/media drafts included — gives way to an explanatory notice.
                    if workspace.isTimelineSelectionMode {
                        MessageSelectionToolbar()
                    } else if chat.isNoLongerMember {
                        MembershipEndedComposerNotice(membership: chat.selfMembership)
                    } else if isBlockedDirectPeer {
                        BlockedConversationComposerNotice()
                    } else if chat.pendingConfirmation {
                        PendingGroupInviteComposerNotice(chat: chat)
                    } else {
                        composerControls
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .background {
                    MessagesComposerBarBackground()
                }
            }
            .background {
                MessagesTranscriptBackground()
            }
            .overlay {
                if let imageGallery {
                    MessageImageGalleryOverlay(presentation: imageGallery) {
                        self.imageGallery = nil
                    }
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: OutgoingMediaAttachmentPolicy.fileImporterAllowedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await workspace.addMediaAttachments(from: urls) }
                case .failure(let error):
                    workspace.reportUserActionError(error.localizedDescription)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // Refuse drops whenever the composer is hidden: accepted files would
                // accumulate invisibly behind the replacement notice and could never be
                // sent. `addMediaAttachments` re-checks via
                // `canBeginMediaAttachmentSelection()` as defense in depth.
                guard canUseComposer else { return false }
                Task { await workspace.addMediaAttachments(from: urls) }
                return !urls.isEmpty
            } isTargeted: { isTargeted in
                isFileDropTargeted = isTargeted && canUseComposer
            }
            .overlay {
                if isFileDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(WNColor.borderPrimary, lineWidth: 2)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }

            // Chat info / settings slides in from the right as a full-size pane
            // over the mounted conversation. Keeping the transcript mounted preserves
            // scroll position, while the details pane supplies its own opaque base so
            // chat content and media never visually bleed through during the slide.
            if workspace.isGroupDetailsPresented {
                GroupDetailsPane(
                    chat: chat,
                    conversationModel: model,
                    attachmentModel: attachmentModel,
                    safetyModel: safetyModel
                )
                .transition(.move(edge: .trailing))
                .zIndex(3)
            }

            if let contact = workspace.contactDetailsTarget {
                ContactDetailsPane(contact: contact, blockedUsersModel: blockedUsersModel)
                    .transition(.move(edge: .trailing))
                    .zIndex(4)
            }
        }
        .animation(.smooth(duration: 0.24), value: workspace.isGroupDetailsPresented)
        .animation(.smooth(duration: 0.24), value: workspace.contactDetailsTarget?.accountIdHex)
        .task(id: chat.id) {
            await workspace.refreshConversationMetadata(for: chat)
        }
        .sheet(
            item: Binding(
                get: { workspace.messageInfoTarget },
                set: { workspace.messageInfoTarget = $0 }
            )
        ) { message in
            MessageInfoSheet(message: message)
        }
        .sheet(
            isPresented: Binding(
                get: { workspace.isForwardPickerPresented },
                set: { isPresented in
                    if !isPresented { workspace.cancelForwarding() }
                }
            )
        ) {
            MessageForwardSheet(chatListModel: chatListModel)
        }
        .sheet(isPresented: $isPollComposerPresented) {
            PollComposerSheet(
                onSend: { submission in
                    try await model.createPoll(submission)
                    isPollComposerPresented = false
                    // Not a `sendDraft()`, so the send signal never moves; scroll to it here.
                    Task { await jumpToNewest() }
                },
                onCancel: { isPollComposerPresented = false }
            )
            .environment(\.locale, locale)
        }
        // Switching conversations must not leave the previous chat's body-level
        // overlays open over a different transcript.
        .onChange(of: chat.id) { _, _ in
            isPollComposerPresented = false
            imageGallery = nil
            composerMentionContext = nil
            composerMentionInsertion = nil
            workspace.cancelMessageSelection()
            workspace.cancelForwarding()
            workspace.messageInfoTarget = nil
            workspace.closeContactDetails()
            if workspace.isGroupDetailsPresented {
                workspace.closeGroupDetails()
            }
        }
    }

    private func mentionCandidates(for context: ComposerMentionContext) -> [ComposerMentionCandidate] {
        workspace.mentionCandidates(
            matching: context.query,
            projectedIdentities: model.snapshot?.identities ?? []
        )
    }

    /// The highlight, clamped to `candidates` — a roster that loads under an unchanged query can
    /// shrink the list beneath it.
    private func highlightedMentionIndex(in candidates: [ComposerMentionCandidate]) -> Int {
        min(mentionHighlightIndex, max(candidates.count - 1, 0))
    }

    /// Replaces the open "@query" with `candidate`, whether it was clicked in the picker or taken
    /// with Tab or Return. Returns false when there is no draft to insert into.
    @discardableResult
    private func insertMention(_ candidate: ComposerMentionCandidate, for context: ComposerMentionContext) -> Bool {
        guard let draftKey = workspace.selectedComposerDraftKey else { return false }
        composerMentionInsertion = ComposerMentionInsertion(
            scope: draftKey,
            context: context,
            candidate: candidate
        )
        composerMentionContext = nil
        return true
    }

    @ViewBuilder
    private var composerControls: some View {
        @Bindable var workspace = workspace

        if let editingMessageContext = workspace.editingMessageContext {
            EditComposerContextView(context: editingMessageContext)
        } else if let replyDraftContext = workspace.replyDraftContext {
            ReplyComposerContextView(context: replyDraftContext) {
                workspace.cancelReply()
            }
        }

        // A staged recording is presented by the voice-draft bar below, not as a thumbnail.
        if !workspace.pendingMediaAttachments.isEmpty, workspace.stagedVoiceMessage == nil {
            PendingMediaDraftStrip(
                attachments: workspace.pendingMediaAttachments,
                uploadStates: workspace.pendingMediaUploadStates,
                isSending: workspace.isSending,
                onRemove: workspace.removePendingMediaAttachment,
                onRetryUpload: workspace.retryPendingMediaUpload
            )
        }

        if let context = composerMentionContext {
            let candidates = mentionCandidates(for: context)
            if !candidates.isEmpty {
                ComposerMentionPicker(
                    candidates: candidates,
                    highlightedIndex: highlightedMentionIndex(in: candidates),
                    onHighlight: { mentionHighlightIndex = $0 }
                ) { candidate in
                    insertMention(candidate, for: context)
                }
                .padding(.bottom, 6)
            }
        }

        if workspace.isRecordingVoiceMessage {
            VoiceRecordingComposerView(
                samples: workspace.voiceRecordingSamples,
                durationSeconds: workspace.voiceRecordingDurationSeconds,
                onStop: {
                    Task { await workspace.finishVoiceRecording() }
                }
            )
        } else if let stagedVoiceMessage = workspace.stagedVoiceMessage {
            VoiceMessageDraftComposerView(
                attachment: stagedVoiceMessage,
                uploadState: workspace.pendingMediaUploadStates[stagedVoiceMessage.id],
                isSending: workspace.isSending,
                canSend: workspace.canSend,
                sendHelp: L10n.string("Send"),
                onDiscard: workspace.discardStagedVoiceMessage,
                onRetryUpload: {
                    workspace.retryPendingMediaUpload(stagedVoiceMessage.id)
                },
                onSend: {
                    Task { await workspace.sendDraft() }
                }
            )
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if workspace.editingMessageContext == nil {
                    Button {
                        isComposerEmojiPickerPresented.toggle()
                    } label: {
                        Image(systemName: "face.smiling")
                            .wnFont(.medium18)
                            .frame(width: 30, height: 30)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending)
                    .help(L10n.string("Emoji"))
                    .popover(isPresented: $isComposerEmojiPickerPresented, arrowEdge: .bottom) {
                        ChatEmojiPicker { emoji in
                            composerEmojiInsertion = ComposerEmojiInsertion(emoji: emoji)
                            isComposerEmojiPickerPresented = false
                        }
                    }

                    // A GIF goes out as its GIPHY text envelope, through the same durable text
                    // send the conversation model uses, so it needs no composer state of its own.
                    ComposerAttachmentMenu(
                        giphyAPIKey: canUseComposer ? GiphyBuildConfig.current().apiKey : nil,
                        isDisabled: workspace.isSending,
                        onAttachFiles: { isFileImporterPresented = true },
                        // Not a `sendDraft()`, so the send signal never moves; scroll to it here.
                        sendGIF: { media in
                            try await model.sendText(media.wireText)
                            Task { await jumpToNewest() }
                        },
                        // MDK accepts polls only in group conversations, never direct messages.
                        onCreatePoll: chat.isDirect ? nil : { isPollComposerPresented = true }
                    )
                }

                ComposerMessageInputView(
                    text: $workspace.draftText,
                    placeholder: workspace.editingMessageContext == nil
                        ? L10n.string("Message") : L10n.string("Edit message"),
                    emojiInsertion: composerEmojiInsertion,
                    onEmojiInsertionConsumed: { insertionID in
                        guard composerEmojiInsertion?.id == insertionID else { return }
                        composerEmojiInsertion = nil
                    },
                    mentionInsertion: composerMentionInsertion,
                    onMentionInsertionConsumed: { insertionID in
                        guard composerMentionInsertion?.id == insertionID else { return }
                        composerMentionInsertion = nil
                    },
                    mentionSelections: $workspace.composerMentionSelections,
                    mentionContextScope: workspace.selectedComposerDraftKey,
                    onMentionContextChange: { context in
                        if context != composerMentionContext {
                            mentionHighlightIndex = 0
                        }
                        composerMentionContext = context
                        if context != nil {
                            workspace.ensureMentionRosterLoaded()
                        }
                    },
                    onMentionCommand: { command in
                        guard let context = composerMentionContext else { return false }
                        let candidates = mentionCandidates(for: context)
                        guard !candidates.isEmpty else { return false }
                        let index = highlightedMentionIndex(in: candidates)
                        if command == .accept {
                            return insertMention(candidates[index], for: context)
                        }
                        // The arrows stay consumed at either end, so the caret never jumps
                        // while the picker is showing.
                        mentionHighlightIndex = command.movingHighlight(index, among: candidates.count)
                        return true
                    },
                    onPasteMedia: { attachments in
                        guard workspace.editingMessageContext == nil else { return }
                        Task { await workspace.addPastedMediaAttachments(attachments) }
                    },
                    onSend: {
                        Task { await workspace.sendDraft() }
                    },
                    focusRequestID: composerFocusRequester.requestID,
                    onFocusRequestConsumed: composerFocusRequester.consume
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    MessagesComposerFieldBackground()
                }
                .accessibilityIdentifier("composer.message")

                if workspace.editingMessageContext != nil {
                    Button {
                        workspace.cancelEditingMessage()
                    } label: {
                        Image(systemName: "xmark")
                            .wnFont(.bold14)
                            .frame(width: 32, height: 32)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending)
                    .help(L10n.string("Cancel edit"))
                } else {
                    Button {
                        Task { await workspace.toggleVoiceRecording() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .wnFont(.semiBold14)
                            .frame(width: 32, height: 32)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending || !workspace.canRecordVoiceMessage)
                    .help(voiceRecordingButtonHelp)
                }

                Button {
                    Task { await workspace.sendDraft() }
                } label: {
                    MessagesSendButtonLabel(
                        systemImage: workspace.editingMessageContext == nil ? "paperplane.fill" : "checkmark",
                        isEnabled: workspace.canSend,
                        isSending: workspace.isSending
                    )
                }
                .buttonStyle(.plain)
                .disabled(!workspace.canSend)
                .help(workspace.editingMessageContext == nil ? L10n.string("Send") : L10n.string("Save edit"))
            }
        }
    }

    /// Explains a mic button that is off because the composer already holds something. A
    /// recording is sent on its own, so it can only start from an empty composer — saying so on
    /// hover is friendlier than letting the tap silently discard the draft.
    private var voiceRecordingButtonHelp: String {
        workspace.canRecordVoiceMessage
            ? L10n.string("Voice message") : L10n.string("A voice message is sent on its own")
    }

    /// Scrolls to a message, jumping the window to it first when it is not loaded. Returns the
    /// scroll request, or nil when the message could not be brought into the window.
    @discardableResult
    private func revealMessage(_ messageId: String) async -> UUID? {
        if !workspace.selectedTimelineContainsMessage(messageId) {
            await model.jump(to: messageId)
        }
        guard workspace.selectedChat?.id == chat.id,
            workspace.selectedTimelineContainsMessage(messageId)
        else { return nil }
        let request = TranscriptScrollRequest(target: .center(id: messageId))
        scrollRequest = request
        return request.id
    }

    /// Re-attaches any window that does not follow the tail, not only one with newer history: an
    /// unread open can hold the newest row yet stop taking arrivals, so a GIF or poll sent from
    /// it (which inserts no pending row) would otherwise land below the old foot.
    private func jumpToNewest() async {
        if !model.isFollowingTail {
            await model.returnToLatest()
        }
        guard workspace.selectedChat?.id == chat.id else { return }
        scrollRequest = TranscriptScrollRequest(target: .bottom)
    }

    private func resetForNewChat() {
        isPinnedToBottom = false
        scrollRequest = nil
        openingRequestId = nil
        hasLanded = false
        openedModel = nil
        isActivelyScrolling = false
        hoverSelectionCoordinator.reset()
        composerMentionContext = nil
        composerMentionInsertion = nil
    }

    /// Starts a newly presented window where this open should begin, once per model: at the
    /// unread divider (the first unread message's row draws it at its top), at a pending
    /// navigation target (the navigation task scrolls there), or at the newest message.
    private func applyOpeningPosition(_ key: TranscriptOpeningKey) {
        guard key.hasPresentedWindow, openedModel != key.model else { return }
        openedModel = key.model
        hasLanded = false
        if let navigation = workspace.pendingMessageNavigation, navigation.groupId == chat.id {
            return
        }
        let target: TranscriptScrollTarget
        if let divider = model.unreadDivider, workspace.selectedTimelineContainsMessage(divider.messageIdHex) {
            target = .top(id: divider.messageIdHex, inset: 8)
        } else {
            target = .bottom
        }
        let request = TranscriptScrollRequest(target: target)
        openingRequestId = request.id
        scrollRequest = request
    }

    private func scrollRequestApplied(_ id: UUID) {
        guard id == openingRequestId else { return }
        land()
    }

    /// The open is where it should start: from here what is on screen counts.
    private func land() {
        openingRequestId = nil
        hasLanded = true
        readingPositionChanged()
    }

    /// The table's visible rows or foot changed.
    private func viewportChanged(_ viewport: TranscriptViewport) {
        isPinnedToBottom = viewport.isAtBottom
        let ids = Set(viewport.visibleRowIds)
        model.setVisibleMessageIds(ids.filter(workspace.selectedTimelineContainsMessage))
        guard hasLanded else { return }
        // A foot that re-attaches the window must not also start an older page in the same turn:
        // both would quote one revision, and the loser's retry could page the re-attached tail.
        let returnsToLatest = handleFoot()
        readingPositionChanged(pages: !returnsToLatest)
    }

    /// The reader's position counts from here: page toward the edge they are near and mark what
    /// they have reached.
    private func readingPositionChanged(pages: Bool = true) {
        updateReadableMessages()
        if pages { requestPageIfNeeded() }
        if !isActivelyScrolling { markVisibleMessagesRead() }
    }

    private func updateReadableMessages() {
        guard hasLanded else {
            model.setReadableMessageIds([])
            return
        }
        model.setReadableMessageIds(
            timelineReadableMessageIds(
                visibleMessageIds: model.visibleMessageIds,
                messageIDs: workspace.selectedMessageIDs,
                isAtBottom: isPinnedToBottom
            )
        )
    }

    /// Loads history toward the edge the visible messages are near (`timelinePageRequest`). The
    /// table keeps the reader's row in place as the page lands, so nothing is restored afterwards.
    /// A page that lands without moving the visible rows reports no viewport change, so the next
    /// page is checked here whenever the window actually grew.
    private func requestPageIfNeeded() {
        guard hasLanded, !model.isPaging else { return }
        let paging = workspace.selectedTimelinePaging
        let messageIDs = workspace.selectedMessageIDs
        guard
            let request = timelinePageRequest(
                visibleMessageIds: model.visibleMessageIds,
                messageIDs: messageIDs,
                hasMoreBefore: paging.hasMoreBefore,
                hasMoreAfter: paging.hasMoreAfter
            )
        else { return }
        TimelineSignpost.scroll.emitEvent(request.direction == .older ? "loadOlderTriggered" : "loadNewerTriggered")
        let groupIdHex = model.groupIdHex
        let edgesBefore = [messageIDs.first, messageIDs.last]
        Task {
            await model.page(request.direction, visibleAnchorMessageIdHex: request.visibleAnchorMessageId)
            let messageIDs = workspace.selectedMessageIDs
            guard workspace.selectedChat?.id == groupIdHex,
                [messageIDs.first, messageIDs.last] != edgesBefore
            else { return }
            requestPageIfNeeded()
        }
    }

    /// At the foot of the window: load the next page, or re-attach a retained window to the tail
    /// (`timelineFootAction`). Returns whether it re-attached.
    @discardableResult
    private func handleFoot() -> Bool {
        guard hasLanded, !model.isPaging else { return false }
        switch timelineFootAction(
            isAtBottom: isPinnedToBottom,
            hasMoreAfter: workspace.selectedTimelinePaging.hasMoreAfter,
            isFollowingTail: model.isFollowingTail
        ) {
        case .none:
            return false
        case .loadNewer:
            requestPageIfNeeded()
            return false
        case .returnToLatest:
            Task { await model.returnToLatest() }
            return true
        }
    }

    /// Marks the newest reached activity row read, while the conversation is actually on screen.
    private func markVisibleMessagesRead() {
        let visible = model.readableMessageIds
        guard hasLanded, !visible.isEmpty, workspace.selectedConversationIsVisible(),
            let client = workspace.client, let account = workspace.activeAccount
        else { return }
        let groupIdHex = chat.id
        Task {
            await workspace.markLatestVisibleMessageRead(
                groupIdHex: groupIdHex,
                account: account,
                client: client,
                within: visible
            )
        }
    }
}

private struct StartupView: View {
    var body: some View {
        VStack(spacing: 28) {
            // The window's splash. It showed a spinner over an empty pane before — the app's own
            // mark was on disk as a baked dark tile that could not be drawn on a light surface,
            // so the first thing a launch showed was nothing in particular. `WhiteNoiseMarkView`
            // is ink rather than a tile, so it can stand here.
            WhiteNoiseMarkView(width: OnboardingLayout.minimumMarkWidth)

            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.string("Starting Marmot"))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GroupDetailsPane: View {
    let chat: ChatItem
    let conversationModel: ConversationViewModel
    let attachmentModel: AttachmentViewModel
    let safetyModel: GroupSafetyViewModel

    var body: some View {
        GroupDetailsSheet(
            chat: chat,
            conversationModel: conversationModel,
            attachmentModel: attachmentModel,
            safetyModel: safetyModel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            MessagesTranscriptBackground()
        }
        .clipped()
        .contentShape(Rectangle())
        .accessibilityIdentifier("group.details.pane")
    }
}

private struct ContactDetailsPane: View {
    let contact: NewChatRecipient
    let blockedUsersModel: BlockedUsersViewModel

    var body: some View {
        ContactDetailsView(contact: contact, blockedUsersModel: blockedUsersModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                MessagesTranscriptBackground()
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityIdentifier("contact.details.pane")
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("Startup failed"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyDrawerState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(
            title: L10n.string("No chats", locale: locale),
            systemImage: "bubble.left.and.bubble.right"
        )
        .padding()
    }
}

private struct EmptyConversationView: View {
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(title: L10n.string("No messages", locale: locale), systemImage: "text.bubble")
            .frame(maxWidth: .infinity, minHeight: 360)
    }
}

/// The detail pane with no conversation in it.
///
/// Which of the three things it has to say is decided here rather than in the rail,
/// because the rail cannot say the useful one: an account with no chats at all has
/// nothing to select, so "Select a chat" would be pointing at an empty list. In that
/// case the invitation to start one takes this pane — the widest, most legible space
/// in the window — and `ChatListDrawerView` leaves its own copy of the notice off so
/// the window carries the message once instead of twice.
private struct EmptyDetailView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if workspace.accounts.isEmpty {
                WNEmptyStateView(
                    title: L10n.string("No accounts", locale: locale),
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            } else if workspace.hasNoChats {
                WNEmptyStateView(
                    title: L10n.string("No chats yet", locale: locale),
                    description: L10n.string("Start a conversation", locale: locale),
                    systemImage: "bubble.left.and.bubble.right"
                )
            } else {
                WNEmptyStateView(
                    title: L10n.string("Select a chat", locale: locale),
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
