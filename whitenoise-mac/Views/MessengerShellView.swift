import AVFoundation
import AVKit
import AppKit
import CoreImage
import ImageIO
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

struct MessengerShellView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Group {
            if workspace.showsMessengerChrome {
                HStack(spacing: 0) {
                    AccountRailView()
                    GlassSeparator()

                    ChatListDrawerView()
                        .frame(width: 300, alignment: .leading)
                        .frame(width: workspace.isChatListVisible ? 300 : 0, alignment: .leading)
                        .opacity(workspace.isChatListVisible ? 1 : 0)
                        .clipped()
                        .allowsHitTesting(workspace.isChatListVisible)

                    GlassSeparator()
                        .opacity(workspace.isChatListVisible ? 1 : 0)
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
        .animation(.smooth(duration: 0.18), value: workspace.isChatListVisible)
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

/// Coarse, `Equatable` scroll-position signal derived from `ScrollGeometry`. Returning
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
    @State private var imageGallery: MessageImageGalleryPresentation?
    /// The single message bubble that is currently text-selectable. Set on hover and kept
    /// until another bubble is hovered or the chat changes, so at most one bubble is ever
    /// backed by a selection NSView — avoiding the mass-platform-view layout hang that
    /// blanket `.textSelection(.enabled)` caused (whitenoise-mac#205).
    @State private var activeSelectionMessageID: String?
    let chat: ChatItem
    private let bottomTranscriptPadding: CGFloat = 34

    var body: some View {
        @Bindable var workspace = workspace
        let messages = workspace.selectedMessages
        let messageIDs = workspace.selectedMessageIDs
        let paging = workspace.selectedTimelinePaging
        let isLoadingInitialPage = workspace.selectedTimelineIsLoadingInitialPage

        VStack(spacing: 0) {
            ConversationHeader(chat: chat)
            GlassSeparator(axis: .horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
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

                            ForEach(messages) { message in
                                ConversationMessageRow(
                                    message: message,
                                    isSelectable: activeSelectionMessageID == message.id,
                                    showsDebugMetadata: workspace.streamingDebugEnabled,
                                    onActivateSelection: { messageId in
                                        activeSelectionMessageID = messageId
                                    }
                                ) { gallery in
                                    imageGallery = gallery
                                }
                                .equatable()
                            }

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
                }
                .accessibilityIdentifier("conversation.transcript")
                .id(chat.id)
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: TimelineScrollMetrics.self) { geometry in
                    TimelineScrollMetrics(geometry: geometry, bottomPadding: bottomTranscriptPadding)
                } action: { _, metrics in
                    // Threshold-crossing signal only (booleans), so this runs when the user
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
                    activeSelectionMessageID = nil
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
                            proxy.scrollTo(anchorId, anchor: .bottom)
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
                    guard let anchorId = pendingPrependAnchorId,
                        workspace.selectedTimelineContainsMessage(anchorId)
                    else { return }
                    DispatchQueue.main.async {
                        // Re-validate against live state: the user may have switched
                        // chats (which clears pendingPrependAnchorId) or another prepend
                        // may have landed between scheduling and execution of this block.
                        // Without re-checking, proxy.scrollTo would run against the new
                        // conversation using a stale anchor, and the unconditional clear
                        // would drop restoration for a subsequent legitimate prepend.
                        guard workspace.selectedChat?.id == chat.id,
                            pendingPrependAnchorId == anchorId,
                            workspace.selectedTimelineContainsMessage(anchorId)
                        else { return }
                        proxy.scrollTo(anchorId, anchor: .top)
                        pendingPrependAnchorId = nil
                    }
                }
            }

            GlassSeparator(axis: .horizontal)

            VStack(spacing: 8) {
                if let replyDraftContext = workspace.replyDraftContext {
                    ReplyComposerContextView(context: replyDraftContext) {
                        workspace.cancelReply()
                    }
                }

                if !workspace.pendingMediaAttachments.isEmpty {
                    PendingMediaDraftStrip(
                        attachments: workspace.pendingMediaAttachments,
                        onRemove: workspace.removePendingMediaAttachment
                    )
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

                        TextField("Message", text: $workspace.draftText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                MessagesComposerFieldBackground()
                            }
                            .accessibilityIdentifier("composer.message")

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

                        Button {
                            Task { await workspace.sendDraft() }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .background {
                                    MessagesSendButtonBackground(isEnabled: workspace.canSend)
                                }
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!workspace.canSend)
                        .help("Send")
                    }
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
            Task { await workspace.addMediaAttachments(from: urls) }
            return !urls.isEmpty
        } isTargeted: { isTargeted in
            isFileDropTargeted = isTargeted
        }
        .overlay {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var bottomAnchorId: String {
        "conversation-bottom-\(chat.id)"
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
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
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
