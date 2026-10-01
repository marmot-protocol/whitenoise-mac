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

/// Whether the transcript's viewport reaches the foot of its content. One boolean, so
/// `onScrollGeometryChange` only invokes its action when the reader crosses that edge — not on
/// every scrolled pixel.
private func timelineIsAtBottom(_ geometry: ScrollGeometry, bottomPadding: CGFloat) -> Bool {
    max(0, geometry.contentSize.height - geometry.visibleRect.maxY) <= bottomPadding + 48
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

/// Whether content changes pin the bottom. While an open is still landing, only an open at the
/// newest message (its target is the bottom spacer) does: a divider or navigation open pins the
/// top, or rows resolving their heights would pull it to the tail before it lands. After that, the
/// reader follows the live edge when at the foot of a window that ends at the newest message.
func timelineFollowsLiveEdge(
    isPinnedToBottom: Bool,
    hasMoreAfter: Bool,
    isOpening: Bool,
    isOpeningAtBottom: Bool
) -> Bool {
    if isOpening { return isOpeningAtBottom }
    return isPinnedToBottom && !hasMoreAfter
}

nonisolated enum TimelineNewestMessageScrollAction: Equatable {
    case none
    case scrollToBottom
}

func timelineNewestMessageScrollAction(
    newMessageIsOutgoing: Bool,
    paging: TimelinePagingState,
    newMessageId: String?,
    isPinnedToBottom: Bool
) -> TimelineNewestMessageScrollAction {
    guard newMessageId != nil else { return .none }

    // `hasMoreBefore` only means older history is loadable. It must not suppress
    // live-edge appends. `hasMoreAfter` means the rendered window is detached from
    // the live edge, so incoming updates should not yank the user out of history.
    if paging.hasMoreAfter && !newMessageIsOutgoing {
        return .none
    }

    guard isPinnedToBottom || newMessageIsOutgoing else { return .none }
    return .scrollToBottom
}

/// Where an open is in landing on its starting row. Paging and read marking act only once it has
/// landed. It starts `pending`: the first layout of a presented window is wherever the initial
/// offset put it (the tail of an unread window), not where the open is going, so nothing it
/// reports may count until the open has chosen a target and seen it on screen.
nonisolated enum TranscriptOpeningPhase: Equatable {
    case pending
    case targeting(String)
    case landed

    var hasLanded: Bool { self == .landed }

    var target: String? {
        if case .targeting(let id) = self { return id }
        return nil
    }

    /// A visibility report lands the open once it shows the target.
    mutating func observe(visibleTargets: Set<String>) {
        if let target, visibleTargets.contains(target) { self = .landed }
    }

    /// The user scrolled: their position counts from now, whatever the open was doing.
    mutating func userTookOver() {
        self = .landed
    }

    /// A navigation finished. It lands when its target is already on screen, where no new
    /// visibility report will arrive, or when the jump could not bring it into the window, where
    /// none ever will.
    mutating func navigationFinished(target: String, isInWindow: Bool, visibleTargets: Set<String>) {
        guard self == .targeting(target) else { return }
        if !isInWindow || visibleTargets.contains(target) { self = .landed }
    }
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

/// One transcript element as a single view: the unread divider and day header it may carry, then
/// the message. A lazy stack places a list of these far more cheaply than a `ForEach` whose
/// elements expand to a varying number of sibling views.
private struct TranscriptItemRow: View {
    let item: TimelineMessageDisplayItem
    let showsUnreadDivider: Bool
    let safetyModel: GroupSafetyViewModel
    let conversationModel: ConversationViewModel
    let canVoteInPolls: Bool
    let showsDebugMetadata: Bool
    let timestampReferenceDate: Date
    let timestampLocale: Locale
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void
    let onNavigateToMessage: (String) -> Void

    var body: some View {
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
                canVoteInPolls: canVoteInPolls,
                showsDebugMetadata: showsDebugMetadata,
                timestampReferenceDate: timestampReferenceDate,
                timestampLocale: timestampLocale,
                onOpenImageGallery: onOpenImageGallery,
                onNavigateToMessage: onNavigateToMessage
            )
        }
    }
}

private struct TranscriptOpeningKey: Equatable {
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
    /// Whether the transcript is scrolled to the foot of its content. Derived from scroll
    /// geometry — never from a view's `.onAppear`/`.onDisappear`, which would write state
    /// during layout and feed back into it.
    @State private var isPinnedToBottom = false
    /// The scroll position by identity: the row at the top of the viewport. SwiftUI updates it as
    /// the reader scrolls and keeps that row in place when rows are added, removed or resized
    /// around it, which is what keeps the reader's place across history pages and image loads.
    @State private var scrollPositionID: String?
    /// The open landing on its starting row (the unread divider, the bottom spacer, or a
    /// navigation target). Until it lands, neither paging nor read marking acts.
    @State private var openingPhase = TranscriptOpeningPhase.pending
    /// The model whose opening position has been applied; a new open gets its own.
    @State private var openedModel: ObjectIdentifier?
    @State private var isFileImporterPresented = false
    @State private var isPollComposerPresented = false
    @State private var isFileDropTargeted = false
    @State private var isComposerEmojiPickerPresented = false
    @State private var composerEmojiInsertion: ComposerEmojiInsertion?
    @State private var composerMentionContext: ComposerMentionContext?
    @State private var composerMentionInsertion: ComposerMentionInsertion?
    @State private var imageGallery: MessageImageGalleryPresentation?
    /// Hover-scoped text-selection gate for chat bubbles. Not read by `body` — bubbles
    /// register local `isSelectable` state so hover only updates the previous and active row
    /// (whitenoise-mac#397).
    @State private var hoverSelectionCoordinator = ConversationHoverSelectionCoordinator()
    /// True while the ScrollView is in any non-idle phase. Drives `.allowsHitTesting` on the
    /// transcript so per-frame hover/hit-test/tracking work is skipped during a fling and
    /// restored the moment scrolling settles.
    @State private var isActivelyScrolling = false
    let chat: ChatItem
    let model: ConversationViewModel
    let chatListModel: ChatListViewModel
    let attachmentModel: AttachmentViewModel
    let safetyModel: GroupSafetyViewModel
    let blockedUsersModel: BlockedUsersViewModel
    private let bottomTranscriptPadding: CGFloat = 34

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
        let unreadDividerMessageId = model.unreadDivider?.messageIdHex
        // Following the live edge, content changes pin the bottom, so arrivals and a streaming
        // reply stay in view; otherwise they pin the top, and the identity position keeps the
        // reader's rows still.
        let isFollowingLiveEdge = timelineFollowsLiveEdge(
            isPinnedToBottom: isPinnedToBottom,
            hasMoreAfter: paging.hasMoreAfter,
            isOpening: !openingPhase.hasLanded,
            isOpeningAtBottom: openingPhase.target == bottomAnchorId
        )

        ZStack {
            VStack(spacing: 0) {
                ConversationHeader(chat: chat)
                    .messageDeletionConfirmation()
                    .messageEditHistory(model: model)
                GlassSeparator(axis: .horizontal)

                ScrollViewReader { proxy in
                    ScrollView {
                        // A `LazyVStack` with an identity scroll position. Only a lazy stack lets
                        // SwiftUI keep the row the reader is on in place when the window changes
                        // around it (an older page, a capped page, images resolving above); an
                        // eager `VStack` holds the offset instead and the reader's rows jump. The
                        // eager stack was adopted in #205, when a lazy one re-estimated row sizes
                        // continuously to resolve a bottom anchor on every size change and pinned
                        // the main thread. The bottom anchor now applies only while following the
                        // live edge; if that storm returns, measure here first.
                        LazyVStack(spacing: 12) {
                            if messageIDs.isEmpty && pendingOutgoingRows.isEmpty {
                                if isLoadingInitialPage {
                                    TimelineInitialLoadingView()
                                } else {
                                    EmptyConversationView()
                                }
                            } else {
                                // Pure visual indicators — no `.onAppear` pagination triggers.
                                // Loading older/newer history is driven by scroll geometry below.
                                if paging.hasMoreBefore {
                                    TimelinePageLoadingRow(isLoading: paging.isLoadingBefore)
                                }

                                // Exactly one view per element. A lazy stack walks this list on
                                // every placement pass; elements that expand to a variable number
                                // of views (an optional divider, an optional day header, the row)
                                // make each walk flatten nested dynamic view lists, which is where
                                // the scroll-up hang spent its time.
                                ForEach(displayItems) { item in
                                    TranscriptItemRow(
                                        item: item,
                                        showsUnreadDivider: item.message.id == unreadDividerMessageId,
                                        safetyModel: safetyModel,
                                        conversationModel: model,
                                        canVoteInPolls: canUseComposer,
                                        showsDebugMetadata: workspace.streamingDebugEnabled,
                                        timestampReferenceDate: timestampReferenceDate,
                                        timestampLocale: locale
                                    ) { gallery in
                                        imageGallery = gallery
                                    } onNavigateToMessage: { targetMessageId in
                                        Task {
                                            await revealMessage(targetMessageId, using: proxy)
                                        }
                                    }
                                    .id(item.message.id)
                                }
                                .environment(\.conversationHoverSelectionCoordinator, hoverSelectionCoordinator)

                                if paging.hasMoreAfter {
                                    TimelinePageLoadingRow(isLoading: paging.isLoadingAfter)
                                }
                            }

                            // Messages the user has already sent that the core has no row for yet
                            // — media whose blobs are still going up, and text still queued behind
                            // an earlier send or rolled back by a failed publish. Rendered after
                            // the real window rather than inside it: these rows exist only on this
                            // client, and the published message that replaces one arrives through
                            // the timeline store like any other. One `ForEach` over both kinds so
                            // they stay in the order they were sent.
                            ForEach(pendingOutgoingRows) { pending in
                                switch pending {
                                case .text(let message):
                                    PendingOutgoingTextBubble(
                                        message: message,
                                        timestampReferenceDate: timestampReferenceDate,
                                        timestampLocale: locale
                                    )
                                case .media(let message):
                                    PendingOutgoingMessageBubble(
                                        message: message,
                                        timestampReferenceDate: timestampReferenceDate,
                                        timestampLocale: locale
                                    )
                                }
                            }

                            // Scroll-to-bottom target. Pure layout: pin/pagination state is
                            // derived from scroll geometry (`onScrollGeometryChange`), so no
                            // `.onAppear`/`.onDisappear` here writes state back into layout — the
                            // feedback that let the old sentinel/anchor callbacks spin the main
                            // thread (whitenoise-mac#205).
                            Color.clear
                                .frame(height: bottomTranscriptPadding)
                                .id(bottomAnchorId)
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                        // The app enables text selection globally (ContentView); the transcript
                        // is the one place that must not inherit it. Backing every Text in the
                        // scrolling window with a selection NSView destabilises scroll-anchor
                        // resolution into a multi-second main-thread layout loop
                        // (whitenoise-mac#205). Bubbles re-enable selection individually on hover
                        // via `.textSelectable(isSelectable)`, which — being closer to the leaf —
                        // overrides this for the single active bubble.
                        .textSelection(.disabled)
                        // While actively scrolling, make the transcript content transparent to
                        // hit-testing so SwiftUI skips per-frame hover/responder/tracking-area work
                        // for the moving rows (Instruments: HoverEventDispatcher /
                        // updateTrackingAreasWithInvalidCursorRects / containsGlobalPoints). The
                        // ScrollView still scrolls; full interactivity returns once it settles.
                        .allowsHitTesting(!isActivelyScrolling)
                    }
                    .accessibilityIdentifier("conversation.transcript")
                    .id(chat.id)
                    .scrollPosition(id: $scrollPositionID, anchor: .top)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .alignment)
                    .defaultScrollAnchor(isFollowingLiveEdge ? .bottom : .top, for: .sizeChanges)
                    .onScrollPhaseChange { _, phase in
                        isActivelyScrolling = phase != .idle
                        // The user took over before the opening target was reported: their
                        // position, as last reported, is the one that counts from here.
                        if phase == .interacting, !openingPhase.hasLanded {
                            openingPhase.userTookOver()
                            readingPositionChanged()
                        }
                        if phase == .idle { markVisibleMessagesRead() }
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        timelineIsAtBottom(geometry, bottomPadding: bottomTranscriptPadding)
                    } action: { _, atBottom in
                        // Fires only when the reader crosses the foot, and only writes
                        // `isPinnedToBottom`, which no row's layout depends on.
                        isPinnedToBottom = atBottom
                        updateReadableMessages()
                        handleFoot()
                    }
                    // An arrival into a window the reader is at the foot of can change only
                    // `hasMoreAfter`, with no row or visibility change to react to.
                    .onChange(of: paging.hasMoreAfter) { _, _ in
                        handleFoot()
                    }
                    // Any part of a row on screen counts as visible, so a message taller than
                    // the viewport registers while it is being read; `timelineReadableMessageIds`
                    // decides which visible rows have been reached.
                    .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.001) { ids in
                        transcriptVisibilityChanged(Set(ids))
                    }
                    .onChange(
                        of: TranscriptOpeningKey(
                            model: ObjectIdentifier(model),
                            hasPresentedWindow: model.hasPresentedWindow
                        ),
                        initial: true
                    ) { _, key in
                        applyOpeningPosition(key, using: proxy)
                    }
                    .onChange(of: chat.id) { _, _ in
                        isPinnedToBottom = false
                        scrollPositionID = nil
                        openingPhase = .pending
                        openedModel = nil
                        // The fresh ScrollView starts idle without emitting a phase transition, so
                        // clear the gate here or the new transcript stays non-interactive until a scroll.
                        isActivelyScrolling = false
                        hoverSelectionCoordinator.reset()
                        composerMentionContext = nil
                        composerMentionInsertion = nil
                    }
                    .onChange(of: messageIDs.last) { _, newMessageId in
                        switch timelineNewestMessageScrollAction(
                            newMessageIsOutgoing: displayItems.last?.message.isOutgoing == true,
                            paging: paging,
                            newMessageId: newMessageId,
                            isPinnedToBottom: isPinnedToBottom && openingPhase.hasLanded
                        ) {
                        case .scrollToBottom:
                            scrollToBottom(with: proxy)
                        case .none:
                            return
                        }
                    }
                    // Pressing Send scrolls to the live edge, off the send itself rather than off
                    // the message it produces. Neither rule above covers a send made while reading
                    // history: a media send (a recording included) appends its pending bubble
                    // *below* the timeline window, so it never moves `messageIDs.last`, and a text
                    // send that lands while an older-history prepend is in flight is not eligible
                    // for the newest-message scroll at all. Both left the new message off the
                    // bottom edge. Unconditional in `isPinnedToBottom`, because sending is an
                    // explicit local action — the same reason the outgoing branch above ignores it.
                    .onChange(of: workspace.outgoingSendScrollGeneration) { _, _ in
                        guard workspace.selectedChat?.id == chat.id else { return }
                        // A window detached from the live edge (the user jumped to a search result
                        // or a reply target) has to be re-attached, not merely scrolled: its bottom
                        // is the foot of a history page, and stopping there would let the
                        // newer-history paging that the bottom edge triggers walk the user back up
                        // off the message they just sent. Same path the jump-to-latest button takes.
                        // Live paging state, not the value captured at body evaluation — an
                        // `onChange` action runs after it, exactly as the geometry ones do.
                        if workspace.selectedTimelinePaging.hasMoreAfter {
                            Task { await jumpToNewest(using: proxy) }
                        } else {
                            scrollToBottom(with: proxy)
                        }
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
                        openingPhase = .targeting(target.messageId)
                        await revealMessage(target.messageId, using: proxy)
                        let wasLanding = !openingPhase.hasLanded
                        openingPhase.navigationFinished(
                            target: target.messageId,
                            isInWindow: workspace.selectedTimelineContainsMessage(target.messageId),
                            visibleTargets: model.visibleTargetIds
                        )
                        if wasLanding, openingPhase.hasLanded { readingPositionChanged() }
                        workspace.completePendingMessageNavigation(target)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if openingPhase.hasLanded && !isPinnedToBottom {
                            Button {
                                Task { await jumpToNewest(using: proxy) }
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
            let candidates = workspace.mentionCandidates(
                matching: context.query,
                projectedIdentities: model.snapshot?.identities ?? []
            )
            if !candidates.isEmpty {
                ComposerMentionPicker(candidates: candidates) { candidate in
                    guard let draftKey = workspace.selectedComposerDraftKey else { return }
                    composerMentionInsertion = ComposerMentionInsertion(
                        scope: draftKey,
                        context: context,
                        candidate: candidate
                    )
                    composerMentionContext = nil
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
                        sendGIF: { [model] media in
                            try await model.sendText(media.wireText)
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
                        composerMentionContext = context
                        if context != nil {
                            workspace.ensureMentionRosterLoaded()
                        }
                    },
                    onPasteMedia: { attachments in
                        guard workspace.editingMessageContext == nil else { return }
                        Task { await workspace.addPastedMediaAttachments(attachments) }
                    },
                    onSend: {
                        Task { await workspace.sendDraft() }
                    }
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

    private var bottomAnchorId: String {
        "conversation-bottom-\(chat.id)"
    }

    private func revealMessage(_ messageId: String, using proxy: ScrollViewProxy) async {
        if !workspace.selectedTimelineContainsMessage(messageId) {
            await model.jump(to: messageId)
        }
        guard workspace.selectedChat?.id == chat.id,
            workspace.selectedTimelineContainsMessage(messageId)
        else { return }
        withAnimation(.smooth(duration: 0.2)) {
            proxy.scrollTo(messageId, anchor: .center)
        }
    }

    private func jumpToNewest(using proxy: ScrollViewProxy) async {
        if workspace.selectedTimelinePaging.hasMoreAfter {
            await model.returnToLatest()
        }
        guard workspace.selectedChat?.id == chat.id else { return }
        scrollToBottom(with: proxy)
    }

    /// Puts a newly presented window where this open should start, once per model: at the unread
    /// divider, at a pending navigation target
    /// (which `revealMessage` scrolls to), or at the newest message.
    private func applyOpeningPosition(_ key: TranscriptOpeningKey, using proxy: ScrollViewProxy) {
        guard key.hasPresentedWindow, openedModel != key.model else { return }
        openedModel = key.model
        if let navigation = workspace.pendingMessageNavigation, navigation.groupId == chat.id {
            openingPhase = .targeting(navigation.messageId)
        } else if let divider = model.unreadDivider,
            workspace.selectedTimelineContainsMessage(divider.messageIdHex)
        {
            // Land on the first unread message's row, which draws the divider at its top.
            openingPhase = .targeting(divider.messageIdHex)
            scrollPositionID = divider.messageIdHex
        } else {
            openingPhase = .targeting(bottomAnchorId)
            scrollToBottom(with: proxy)
            // Already at the foot, the scroll changes nothing on screen and no new report
            // arrives, so check what the transcript last reported.
            openingPhase.observe(visibleTargets: model.visibleTargetIds)
            if openingPhase.hasLanded { readingPositionChanged() }
        }
    }

    /// The transcript's on-screen rows changed. They are always recorded, so a user who takes
    /// over before the opening target is reported continues from what was last on screen; they
    /// drive paging and read marking once the open has landed.
    private func transcriptVisibilityChanged(_ ids: Set<String>) {
        model.setVisibleIds(targets: ids, messages: ids.filter(workspace.selectedTimelineContainsMessage))
        if !openingPhase.hasLanded {
            openingPhase.observe(visibleTargets: ids)
            guard openingPhase.hasLanded else { return }
        }
        readingPositionChanged()
    }

    /// The reader's position counts from here: page toward the edge they are near and mark what
    /// they have reached.
    private func readingPositionChanged() {
        updateReadableMessages()
        requestPageIfNeeded()
        if !isActivelyScrolling { markVisibleMessagesRead() }
    }

    private func updateReadableMessages() {
        guard openingPhase.hasLanded else {
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
    /// reader's place is kept by the identity scroll position, so nothing is restored afterwards.
    /// A page that lands without moving the visible rows reports no visibility change, so the next
    /// page is checked here whenever the window actually grew.
    private func requestPageIfNeeded() {
        guard openingPhase.hasLanded, !model.isPaging else { return }
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
    /// (`timelineFootAction`). The identity position keeps the reader's rows still either way.
    private func handleFoot() {
        guard openingPhase.hasLanded, !model.isPaging else { return }
        switch timelineFootAction(
            isAtBottom: isPinnedToBottom,
            hasMoreAfter: workspace.selectedTimelinePaging.hasMoreAfter,
            isFollowingTail: model.isFollowingTail
        ) {
        case .none:
            return
        case .loadNewer:
            requestPageIfNeeded()
        case .returnToLatest:
            Task { await model.returnToLatest() }
        }
    }

    /// Marks the newest reached activity row read, while the conversation is actually on screen.
    private func markVisibleMessagesRead() {
        let visible = model.readableMessageIds
        guard openingPhase.hasLanded, !visible.isEmpty, workspace.selectedConversationIsVisible(),
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

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            // Intentionally NOT animated. An animated `scrollTo` to the bottom anchor chases
            // a moving target while content keeps growing underneath it — a reply's
            // delivery-state burst, or an agent streaming its response — so SwiftUI
            // re-resolves the scroll position (`Array.motionVectors`, O(visible rows)) and
            // re-sizes the Markdown bubbles on every display frame, pinning the main thread
            // at 100% for the whole stream (confirmed via Instruments: continuous
            // AnimatableAttributeHelper / ScrollViewAdjustedState.adjustOffsetIfNeeded /
            // motionVectors). A plain jump positions in one pass; once the reader is at the
            // foot, subsequent growth is handled instantly by the `.bottom` size-change anchor
            // that following the live edge applies. See whitenoise-mac#205.
            TimelineSignpost.scroll.interval("scrollToBottom") {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
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
