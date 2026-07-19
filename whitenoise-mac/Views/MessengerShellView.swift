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

    var body: some View {
        let ignoredEdges: Edge.Set = workspace.showsMessengerChrome ? .top : []

        Group {
            if workspace.showsMessengerChrome {
                HStack(spacing: 0) {
                    AccountRailView()
                    GlassSeparator()

                    Group {
                        if workspace.isChatListVisible {
                            ChatListDrawerView()
                                .frame(width: 300, alignment: .leading)
                                .transition(.move(edge: .leading).combined(with: .opacity))

                            GlassSeparator()
                                .transition(.opacity)
                        }
                    }
                    // Scope the sidebar transition to the drawer. The detail pane
                    // width should jump once, not animate through every intermediate
                    // width and force the non-lazy transcript to re-wrap each frame.
                    .animation(.smooth(duration: 0.18), value: workspace.isChatListVisible)

                    DetailPaneView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Background-task failures (subscription listeners, observability
                // refresh, read-marking) surface here as a non-modal banner rather
                // than on the per-screen error view, so they are never misattributed
                // to a user action on the login/settings/new-chat forms.
                .overlay(alignment: .top) {
                    BackgroundStatusBanner()
                }
            } else {
                DetailPaneView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            MessagesWindowBackground()
        }
        .ignoresSafeArea(.container, edges: ignoredEdges)
    }
}

private struct BackgroundStatusBanner: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        if let status = workspace.backgroundStatus {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    workspace.clearBackgroundStatus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(L10n.string("Dismiss"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .glassCard(cornerRadius: 10)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.smooth(duration: 0.2), value: workspace.backgroundStatus)
        }
    }
}

private struct WelcomeAuthView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 22) {
            Spacer(minLength: 32)

            Image("WhiteNoiseLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 104, height: 104)
                .shadow(color: Color.black.opacity(0.12), radius: 18, y: 10)

            // Standard primary/secondary pattern: hierarchy comes from the button style,
            // and the system owns the label/fill colors (adapts to accent, contrast, and
            // light/dark) — we don't hard-code them.
            VStack(spacing: 12) {
                Button {
                    Task { await workspace.signUp() }
                } label: {
                    Text(
                        workspace.isAuthenticating && workspace.authenticationMode == .landing
                            ? L10n.string("Creating...")
                            : L10n.string("Create New Identity")
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.extraLarge)
                .buttonBorderShape(.capsule)
                .nativeGlassProminentButtonStyle()
                .disabled(workspace.isAuthenticating)

                Button {
                    workspace.showLogin()
                } label: {
                    Text("Log in with Key")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.extraLarge)
                .buttonStyle(.plain)
                .disabled(workspace.isAuthenticating)
            }
            .frame(width: 280)

            if workspace.authenticationMode == .login {
                VStack(spacing: 12) {
                    SecureField("nsec1...", text: $workspace.loginIdentity)
                        .textFieldStyle(.plain)
                        .frame(width: 360)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .glassCard()
                        .disabled(workspace.isAuthenticating)

                    HStack(spacing: 10) {
                        Button("Cancel") {
                            workspace.cancelLogin()
                        }
                        .disabled(workspace.isAuthenticating)

                        Button(workspace.isAuthenticating ? L10n.string("Logging in...") : L10n.string("Log in")) {
                            Task { await workspace.login() }
                        }
                        .nativeGlassProminentButtonStyle()
                        .disabled(
                            workspace.loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || workspace.isAuthenticating)
                    }
                }
                .padding(.top, 4)
            }

            if let lastError = workspace.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.top, 2)
            }

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Matches the app-logo tile grey (#202020) so the mark sits on a seamless field.
            Color(red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 32.0 / 255.0)
                .ignoresSafeArea()
        }
    }
}

private struct DetailPaneView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Group {
            switch workspace.phase {
            case .bootstrapping:
                StartupView()
            case .onboarding:
                WelcomeAuthView()
            case .failed(let message):
                FailureView(message: message)
            case .ready:
                if workspace.activeAccount == nil {
                    SignedOutAccountsView()
                } else {
                    switch workspace.selection {
                    case .chat:
                        if let chat = workspace.selectedChat {
                            ConversationView(chat: chat)
                        } else {
                            EmptyDetailView()
                        }
                    case .settings:
                        SettingsPanelView()
                    case nil:
                        EmptyDetailView()
                    }
                }
            }
        }
    }
}

private struct SignedOutAccountsView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var signedOutAccounts: [AccountItem] {
        workspace.accounts.filter(\.signedOut)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image("WhiteNoiseLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)

            VStack(spacing: 5) {
                Text("Choose an account")
                    .font(.title2.weight(.semibold))
                Text("Sign in to continue with an account stored on this Mac.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(signedOutAccounts) { account in
                    Button {
                        Task { await workspace.signInAccount(account) }
                    } label: {
                        HStack(spacing: 12) {
                            ProfileImageAvatarView(
                                seed: account.accountIdHex,
                                initials: account.initials,
                                sanitizedPictureURL: account.sanitizedPictureURL,
                                size: 40,
                                isSelected: false
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.headline)
                                Text(DisplayText.short(account.npub ?? account.accountIdHex))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 20)
                            Text("Sign In")
                                .font(.callout.weight(.semibold))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .glassCard(cornerRadius: 12)
                    .disabled(workspace.isSigningOutAccount)
                }
            }
            .frame(maxWidth: 440)

            Button("Use another account") {
                workspace.showAccountOnboarding()
            }
            .nativeGlassButtonStyle()
            .disabled(workspace.isSigningOutAccount)

            if let lastError = workspace.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Coarse, `Equatable` scroll-position state derived from `ScrollGeometry`. Returning
/// threshold booleans (rather than raw offsets) means `onScrollGeometryChange` only invokes
/// its action when the transcript actually crosses an edge — not on every scrolled pixel —
/// keeping pagination/pin updates off the per-frame path.
private struct TimelineScrollMetrics: Equatable {
    let atBottom: Bool
    let nearTop: Bool
    let nearBottom: Bool

    init(geometry: ScrollGeometry, bottomPadding: CGFloat) {
        let fromTop = max(0, geometry.visibleRect.minY)
        let fromBottom = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
        // Prefetch roughly one viewport ahead of either edge so paging completes before the
        // user reaches the spinner.
        let prefetch = max(geometry.containerSize.height, 600)
        atBottom = fromBottom <= bottomPadding + 48
        nearTop = fromTop <= prefetch
        nearBottom = fromBottom <= prefetch
    }
}

nonisolated enum TimelineNewestMessageScrollAction: Equatable {
    case none
    case clearPendingAppendAnchor
    case restorePendingAppendAnchor(String)
    case scrollToBottom
}

func timelineNewestMessageScrollAction(
    messageIDs: [String],
    newMessageIsOutgoing: Bool,
    paging: TimelinePagingState,
    pendingPrependAnchorId: String?,
    pendingAppendAnchorId: String?,
    newMessageId: String?,
    isPinnedToBottom: Bool
) -> TimelineNewestMessageScrollAction {
    if let pendingAppendAnchorId {
        return messageIDs.contains(pendingAppendAnchorId)
            ? .restorePendingAppendAnchor(pendingAppendAnchorId)
            : .clearPendingAppendAnchor
    }

    guard newMessageId != nil,
        pendingPrependAnchorId == nil
    else { return .none }

    // `hasMoreBefore` only means older history is loadable. It must not suppress
    // live-edge appends. `hasMoreAfter` means the rendered window is detached from
    // the live edge, so incoming updates should not yank the user out of history.
    if paging.hasMoreAfter && !newMessageIsOutgoing {
        return .none
    }

    guard isPinnedToBottom || newMessageIsOutgoing else { return .none }
    return .scrollToBottom
}

private struct ConversationView: View {
    @Environment(WorkspaceState.self) private var workspace
    /// The top message captured before an older-history prepend, so its on-screen position
    /// can be restored afterward; also gates re-triggering `loadOlder` until the prepend lands.
    @State private var pendingPrependAnchorId: String?
    /// The bottom message captured before a newer-history append, mirroring the above.
    @State private var pendingAppendAnchorId: String?
    /// Whether the transcript is scrolled to (or near) the live edge. Derived from scroll
    /// geometry — never from a view's `.onAppear`/`.onDisappear`, which would write state
    /// during layout and feed back into it.
    @State private var isPinnedToBottom = true
    @State private var isFileImporterPresented = false
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
    private let bottomTranscriptPadding: CGFloat = 34

    var body: some View {
        @Bindable var workspace = workspace
        let messages = workspace.selectedMessages
        let displayItems = TimelineMessageDisplayItem.make(from: messages)
        let messageIDs = workspace.selectedMessageIDs
        let paging = workspace.selectedTimelinePaging
        let isLoadingInitialPage = workspace.selectedTimelineIsLoadingInitialPage

        ZStack {
            VStack(spacing: 0) {
                ConversationHeader(chat: chat)
                    .messageDeletionConfirmation()
                    .messageEditHistory()
                GlassSeparator(axis: .horizontal)

                ScrollViewReader { proxy in
                    ScrollView {
                        // A NON-lazy `VStack`: the timeline window is capped (`timelineWindowLimit`
                        // = 200), so eagerly realizing every row measures each exactly once and lets
                        // scrolling be pure translation. `LazyVStack` instead re-estimated row sizes
                        // continuously to resolve `.defaultScrollAnchor(.bottom)` — ~80 `sizeThatFits`
                        // calls per row — which pinned the main thread for seconds while scrolling a
                        // small group (the #205 scroll-layout storm). Measure-once removes that whole
                        // class of hang; if a large window's eager build ever costs too much, the fix
                        // is cheaper rows, not a return to lazy estimation.
                        VStack(spacing: 12) {
                            if messageIDs.isEmpty {
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

                                ForEach(displayItems) { item in
                                    if let dayLabel = item.dayLabel {
                                        TimelineDayHeaderView(title: dayLabel)
                                    }

                                    ConversationMessageRow(
                                        message: item.message,
                                        showsDebugMetadata: workspace.streamingDebugEnabled
                                    ) { gallery in
                                        imageGallery = gallery
                                    } onNavigateToMessage: { targetMessageId in
                                        Task {
                                            await revealMessage(targetMessageId, using: proxy)
                                        }
                                    }
                                }
                                .environment(\.conversationHoverSelectionCoordinator, hoverSelectionCoordinator)

                                if paging.hasMoreAfter {
                                    TimelinePageLoadingRow(isLoading: paging.isLoadingAfter)
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
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                        // While actively scrolling, make the transcript content transparent to
                        // hit-testing so SwiftUI skips per-frame hover/responder/tracking-area work
                        // for the moving rows (Instruments: HoverEventDispatcher /
                        // updateTrackingAreasWithInvalidCursorRects / containsGlobalPoints). The
                        // ScrollView still scrolls; full interactivity returns once it settles.
                        .allowsHitTesting(!isActivelyScrolling)
                    }
                    .accessibilityIdentifier("conversation.transcript")
                    .id(chat.id)
                    .defaultScrollAnchor(.bottom)
                    .onScrollPhaseChange { _, phase in
                        isActivelyScrolling = phase != .idle
                    }
                    .onScrollGeometryChange(for: TimelineScrollMetrics.self) { geometry in
                        TimelineScrollMetrics(geometry: geometry, bottomPadding: bottomTranscriptPadding)
                    } action: { _, metrics in
                        // Threshold-crossing state only (booleans), so this runs when the user
                        // crosses an edge — not on every scrolled pixel — and only ever writes
                        // `isPinnedToBottom`, which no view's layout depends on.
                        isPinnedToBottom = metrics.atBottom
                        if metrics.nearTop { loadOlderIfNeeded() }
                        if metrics.nearBottom { loadNewerIfNeeded() }
                    }
                    .onChange(of: chat.id) { _, _ in
                        pendingPrependAnchorId = nil
                        pendingAppendAnchorId = nil
                        isPinnedToBottom = true
                        // The fresh ScrollView starts idle without emitting a phase transition, so
                        // clear the gate here or the new transcript stays non-interactive until a scroll.
                        isActivelyScrolling = false
                        hoverSelectionCoordinator.reset()
                        composerMentionContext = nil
                        composerMentionInsertion = nil
                    }
                    .onChange(of: messageIDs.last) { _, newMessageId in
                        switch timelineNewestMessageScrollAction(
                            messageIDs: messageIDs,
                            newMessageIsOutgoing: messages.last?.isOutgoing == true,
                            paging: paging,
                            pendingPrependAnchorId: pendingPrependAnchorId,
                            pendingAppendAnchorId: pendingAppendAnchorId,
                            newMessageId: newMessageId,
                            isPinnedToBottom: isPinnedToBottom
                        ) {
                        case .restorePendingAppendAnchor(let anchorId):
                            DispatchQueue.main.async {
                                // Re-validate against live state: the user may have switched
                                // chats or a newer paging request may have landed since this
                                // scroll restoration was scheduled.
                                guard workspace.selectedChat?.id == chat.id,
                                    pendingAppendAnchorId == anchorId,
                                    workspace.selectedTimelineContainsMessage(anchorId)
                                else { return }
                                TimelineSignpost.scroll.interval("restoreAppendAnchor") {
                                    proxy.scrollTo(anchorId, anchor: .bottom)
                                }
                                pendingAppendAnchorId = nil
                            }
                            return
                        case .clearPendingAppendAnchor:
                            pendingAppendAnchorId = nil
                            return
                        case .scrollToBottom:
                            scrollToBottom(with: proxy)
                        case .none:
                            return
                        }
                    }
                    .onChange(of: messageIDs.first) { _, _ in
                        guard let anchorId = pendingPrependAnchorId else { return }
                        guard workspace.selectedChat?.id == chat.id,
                            workspace.selectedTimelineContainsMessage(anchorId)
                        else {
                            // Anchor evicted or chat changed — release the gate, or every
                            // later older-history load stays silently blocked.
                            pendingPrependAnchorId = nil
                            return
                        }
                        DispatchQueue.main.async {
                            // Re-validate against live state: the user may have switched
                            // chats (which clears pendingPrependAnchorId) or another prepend
                            // may have landed between scheduling and execution of this block.
                            // Without re-checking, proxy.scrollTo would run against the new
                            // conversation using a stale anchor, and the unconditional clear
                            // would drop restoration for a subsequent legitimate prepend.
                            guard pendingPrependAnchorId == anchorId else { return }
                            guard workspace.selectedChat?.id == chat.id,
                                workspace.selectedTimelineContainsMessage(anchorId)
                            else {
                                pendingPrependAnchorId = nil
                                return
                            }
                            TimelineSignpost.scroll.interval("restorePrependAnchor") {
                                proxy.scrollTo(anchorId, anchor: .top)
                            }
                            pendingPrependAnchorId = nil
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !isPinnedToBottom {
                            Button {
                                Task { await jumpToNewest(using: proxy) }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 40, height: 40)
                                    .background(.regularMaterial, in: Circle())
                                    .overlay {
                                        Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                                    }
                                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
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
                guard chat.canUseComposer else { return false }
                Task { await workspace.addMediaAttachments(from: urls) }
                return !urls.isEmpty
            } isTargeted: { isTargeted in
                isFileDropTargeted = isTargeted && chat.canUseComposer
            }
            .overlay {
                if isFileDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }

            // Chat info / settings slides in from the right as a full-size pane
            // over the mounted conversation. Keeping the transcript mounted preserves
            // scroll position, while the details pane supplies its own opaque base so
            // chat content and media never visually bleed through during the slide.
            if workspace.isGroupDetailsPresented {
                GroupDetailsPane(chat: chat)
                    .transition(.move(edge: .trailing))
                    .zIndex(3)
            }
        }
        .animation(.smooth(duration: 0.24), value: workspace.isGroupDetailsPresented)
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
            MessageForwardSheet()
        }
        // Switching conversations must not leave the previous chat's body-level
        // overlays open over a different transcript.
        .onChange(of: chat.id) { _, _ in
            imageGallery = nil
            composerMentionContext = nil
            composerMentionInsertion = nil
            workspace.cancelMessageSelection()
            workspace.cancelForwarding()
            workspace.messageInfoTarget = nil
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

        if !workspace.pendingMediaAttachments.isEmpty {
            PendingMediaDraftStrip(
                attachments: workspace.pendingMediaAttachments,
                uploadStates: workspace.pendingMediaUploadStates,
                isSending: workspace.isSending,
                onRemove: workspace.removePendingMediaAttachment
            )
        }

        if let context = composerMentionContext {
            let candidates = workspace.mentionCandidates(matching: context.query)
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
                onCancel: workspace.cancelVoiceRecording,
                onStop: {
                    Task { await workspace.finishVoiceRecording() }
                }
            )
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if workspace.editingMessageContext == nil {
                    Button {
                        isComposerEmojiPickerPresented.toggle()
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending)
                    .help("Emoji")
                    .popover(isPresented: $isComposerEmojiPickerPresented, arrowEdge: .bottom) {
                        ChatEmojiPicker { emoji in
                            composerEmojiInsertion = ComposerEmojiInsertion(emoji: emoji)
                            isComposerEmojiPickerPresented = false
                        }
                    }

                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending)
                    .help("Attach files")
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
                            .font(.system(size: 13, weight: .bold))
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
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending)
                    .help("Voice message")
                }

                Button {
                    Task { await workspace.sendDraft() }
                } label: {
                    Group {
                        if workspace.isSending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: workspace.editingMessageContext == nil ? "paperplane.fill" : "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background {
                        MessagesSendButtonBackground(isEnabled: workspace.canSend || workspace.isSending)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!workspace.canSend)
                .help(workspace.editingMessageContext == nil ? "Send" : "Save edit")
            }
        }
    }

    private var bottomAnchorId: String {
        "conversation-bottom-\(chat.id)"
    }

    private func revealMessage(_ messageId: String, using proxy: ScrollViewProxy) async {
        var attempts = 0
        while !workspace.selectedTimelineContainsMessage(messageId),
            workspace.selectedTimelinePaging.hasMoreBefore,
            attempts < 12
        {
            let previousFirstId = workspace.selectedMessageIDs.first
            await workspace.loadOlderMessages(groupIdHex: chat.id)
            attempts += 1
            guard workspace.selectedChat?.id == chat.id,
                workspace.selectedMessageIDs.first != previousFirstId
            else { break }
        }
        guard workspace.selectedChat?.id == chat.id,
            workspace.selectedTimelineContainsMessage(messageId)
        else { return }
        withAnimation(.smooth(duration: 0.2)) {
            proxy.scrollTo(messageId, anchor: .center)
        }
    }

    private func jumpToNewest(using proxy: ScrollViewProxy) async {
        var attempts = 0
        while workspace.selectedTimelinePaging.hasMoreAfter, attempts < 12 {
            let previousLastID = workspace.selectedMessageIDs.last
            await workspace.loadNewerMessages(groupIdHex: chat.id)
            attempts += 1
            guard workspace.selectedChat?.id == chat.id,
                workspace.selectedMessageIDs.last != previousLastID
            else { break }
        }
        guard workspace.selectedChat?.id == chat.id else { return }
        scrollToBottom(with: proxy)
    }

    /// Prefetch older history when the user scrolls near the top. `pendingPrependAnchorId`
    /// (set here, cleared once the prepend lands and its position is restored) gates
    /// re-triggering, and `loadOlderMessages` itself is a no-op when there is nothing more to
    /// load or a load is already in flight — so this stays idempotent under repeated geometry
    /// callbacks. Reads live workspace state rather than captured values, since the geometry
    /// action fires asynchronously after body evaluation.
    private func loadOlderIfNeeded() {
        let paging = workspace.selectedTimelinePaging
        guard paging.hasMoreBefore, !paging.isLoadingBefore,
            pendingPrependAnchorId == nil,
            let anchorId = workspace.selectedMessageIDs.first
        else { return }
        pendingPrependAnchorId = anchorId
        // Marks the instant the user crossed the top threshold and older-history paging
        // began — the head of the scroll-back cycle that ends at `restorePrependAnchor`.
        TimelineSignpost.scroll.emitEvent("loadOlderTriggered")
        Task {
            await workspace.loadOlderMessages(groupIdHex: chat.id)
            // Fallback clear when no restoration occurs (e.g. already at the oldest message,
            // so `messageIDs.first` never changes and the `.first` onChange won't fire).
            if pendingPrependAnchorId == anchorId, workspace.selectedMessageIDs.first == anchorId {
                pendingPrependAnchorId = nil
            }
        }
    }

    /// Symmetric to `loadOlderIfNeeded` for newer history when the rendered window is detached
    /// from the live edge (`hasMoreAfter`) and the user scrolls near the bottom.
    private func loadNewerIfNeeded() {
        let paging = workspace.selectedTimelinePaging
        guard paging.hasMoreAfter, !paging.isLoadingAfter,
            pendingAppendAnchorId == nil,
            let anchorId = workspace.selectedMessageIDs.last
        else { return }
        pendingAppendAnchorId = anchorId
        TimelineSignpost.scroll.emitEvent("loadNewerTriggered")
        Task {
            await workspace.loadNewerMessages(groupIdHex: chat.id)
            if pendingAppendAnchorId == anchorId, workspace.selectedMessageIDs.last == anchorId {
                pendingAppendAnchorId = nil
            }
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
            // motionVectors). A plain jump positions in one pass; subsequent growth is
            // handled instantly by `.defaultScrollAnchor(.bottom)`. See whitenoise-mac#205.
            TimelineSignpost.scroll.interval("scrollToBottom") {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }
}

private struct StartupView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting Marmot")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GroupDetailsPane: View {
    let chat: ChatItem

    var body: some View {
        GroupDetailsSheet(chat: chat)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                MessagesTranscriptBackground()
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityIdentifier("group.details.pane")
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Startup failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyDrawerState: View {
    var body: some View {
        ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right")
            .padding()
    }
}

private struct EmptyConversationView: View {
    var body: some View {
        ContentUnavailableView("No messages", systemImage: "text.bubble")
            .frame(maxWidth: .infinity, minHeight: 360)
    }
}

private struct EmptyDetailView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        ContentUnavailableView {
            Label(
                workspace.accounts.isEmpty ? L10n.string("No accounts") : L10n.string("Select a chat"),
                systemImage: "bubble.left.and.bubble.right")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
