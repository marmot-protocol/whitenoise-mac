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

private struct AccountRailView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isSettingsSelected: Bool {
        if case .settings = workspace.selection { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                workspace.toggleChatList()
            } label: {
                Image(systemName: workspace.isChatListVisible ? "sidebar.leading" : "sidebar.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background {
                        MessagesCircleControlBackground(isSelected: workspace.isChatListVisible)
                    }
            }
            .buttonStyle(.plain)
            .help(workspace.isChatListVisible ? L10n.string("Hide chat list") : L10n.string("Show chat list"))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(workspace.accounts) { account in
                        Button {
                            workspace.selectAccount(account)
                        } label: {
                            ProfileImageAvatarView(
                                seed: account.accountIdHex,
                                initials: account.initials,
                                pictureURL: account.pictureURL,
                                size: 42,
                                isSelected: account.id == workspace.activeAccountId
                            )
                            .frame(width: 54, height: 54)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(account.displayName)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            Button {
                workspace.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background {
                        MessagesCircleControlBackground(isSelected: isSettingsSelected)
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSettingsSelected ? Color.primary : Color.secondary)
            .help("Settings")
        }
        .padding(.vertical, 14)
        .frame(width: 62)
        .background {
            MessagesSidebarBackground(level: .rail)
        }
    }
}

private struct ChatListDrawerView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isShowingSettings: Bool {
        if case .settings = workspace.selection { return true }
        return false
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            if isShowingSettings {
                SettingsListDrawerView()
            } else if workspace.isNewChatComposerVisible {
                NewChatColumnView()
            } else {
                let filteredChats = workspace.filteredChats
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Chats")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Button {
                            workspace.showNewChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background {
                                    MessagesCircleControlBackground()
                                }
                        }
                        .buttonStyle(.plain)
                        .help("New chat")
                    }

                    MessagesSearchField(text: $workspace.searchText)
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 12)

                GlassSeparator(axis: .horizontal)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredChats) { chat in
                            Button {
                                workspace.selectChat(chat)
                            } label: {
                                ChatRowContent(
                                    chat: chat,
                                    isSelected: workspace.selection == .chat(chat.id)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .overlay {
                    if filteredChats.isEmpty {
                        EmptyDrawerState()
                    }
                }
            }
        }
        .background {
            MessagesSidebarBackground(level: .drawer)
        }
    }
}

private struct SettingsListDrawerView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(.title2.weight(.semibold))

                activeAccountSummary
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 12)

            GlassSeparator(axis: .horizontal)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(SettingsPage.sidebarPages, id: \.self) { page in
                        Button {
                            workspace.showSettingsPage(page)
                        } label: {
                            SettingsSidebarRow(page: page)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

        }
        .background {
            MessagesSidebarBackground(level: .drawer)
        }
    }

    private var activeAccountSummary: some View {
        HStack(spacing: 10) {
            if let account = workspace.activeAccount {
                ProfileImageAvatarView(
                    seed: account.accountIdHex,
                    initials: account.initials,
                    pictureURL: account.pictureURL,
                    size: 34,
                    isSelected: false
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    CopyableKeyLabel(accountIdHex: account.accountIdHex, head: 8, tail: 6, showsCopyButton: false)
                }
            } else {
                Label("No account", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout.weight(.semibold))
            }

            Spacer(minLength: 0)

            if let account = workspace.activeAccount {
                PublicIdentityQRCodeButton(
                    accountIdHex: account.accountIdHex,
                    displayName: account.displayName
                )
            }
        }
        .padding(10)
        .glassCard()
    }
}

private struct SettingsSidebarRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let page: SettingsPage

    private var isSelected: Bool {
        workspace.selection == .settings(page)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(page.sidebarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            MessagesSidebarRowBackground(isSelected: isSelected)
        }
        .contentShape(Rectangle())
    }
}

private struct ChatRowContent: View {
    let chat: ChatItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProfileImageAvatarView(
                seed: chat.avatarSeed,
                initials: chat.title,
                pictureURL: chat.pictureURL,
                size: 42,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if chat.pendingConfirmation {
                        PendingInviteBadge()
                    }
                    Spacer(minLength: 8)
                    Text(chat.timestampLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(chat.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(chat.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if chat.unreadCount > 0 {
                Text("\(chat.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(MessagesPalette.sentBubble))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            MessagesSidebarRowBackground(isSelected: isSelected)
        }
        .contentShape(Rectangle())
    }
}

private struct PendingInviteBadge: View {
    var body: some View {
        Label("Invite", systemImage: "envelope.badge")
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(.quaternary, in: Capsule())
            .help(L10n.string("Group invite pending"))
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

enum TimelineNewestMessageScrollAction: Equatable {
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
    @State private var pendingPrependAnchorId: String?
    @State private var pendingAppendAnchorId: String?
    @State private var isPinnedToBottom = true
    @State private var didRequestOlderForVisibleTopSentinel = false
    @State private var lastOlderLoadTriggerAnchorId: String?
    @State private var topSentinelResetTask: Task<Void, Never>?
    @State private var didRequestNewerForVisibleBottomSentinel = false
    @State private var lastNewerLoadTriggerAnchorId: String?
    @State private var bottomSentinelResetTask: Task<Void, Never>?
    @State private var isFileImporterPresented = false
    @State private var isFileDropTargeted = false
    @State private var imageGallery: MessageImageGalleryPresentation?
    let chat: ChatItem
    private let bottomTranscriptPadding: CGFloat = 34

    var body: some View {
        @Bindable var workspace = workspace
        let messages = workspace.selectedMessages
        let messageIDs = messages.map(\.id)
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
                            if paging.hasMoreBefore {
                                TimelinePageLoadingRow(isLoading: paging.isLoadingBefore)
                                    .onAppear {
                                        topSentinelResetTask?.cancel()
                                        guard let anchorId = messageIDs.first,
                                            pendingPrependAnchorId == nil,
                                            !paging.isLoadingBefore,
                                            !didRequestOlderForVisibleTopSentinel,
                                            lastOlderLoadTriggerAnchorId != anchorId
                                        else { return }
                                        didRequestOlderForVisibleTopSentinel = true
                                        lastOlderLoadTriggerAnchorId = anchorId
                                        pendingPrependAnchorId = anchorId
                                        Task {
                                            await workspace.loadOlderMessages(groupIdHex: chat.id)
                                            if pendingPrependAnchorId == anchorId,
                                                workspace.selectedMessageIDs.first == anchorId
                                            {
                                                pendingPrependAnchorId = nil
                                            }
                                        }
                                    }
                                    .onDisappear {
                                        guard pendingPrependAnchorId == nil else { return }
                                        topSentinelResetTask?.cancel()
                                        topSentinelResetTask = Task {
                                            try? await Task.sleep(nanoseconds: 300_000_000)
                                            guard !Task.isCancelled else { return }
                                            await MainActor.run {
                                                guard pendingPrependAnchorId == nil else { return }
                                                didRequestOlderForVisibleTopSentinel = false
                                            }
                                        }
                                    }
                            }

                            ForEach(messages) { message in
                                ConversationMessageRow(message: message) { gallery in
                                    imageGallery = gallery
                                }
                            }

                            if paging.hasMoreAfter {
                                TimelinePageLoadingRow(isLoading: paging.isLoadingAfter)
                                    .onAppear {
                                        bottomSentinelResetTask?.cancel()
                                        guard let anchorId = messageIDs.last,
                                            pendingAppendAnchorId == nil,
                                            !paging.isLoadingAfter,
                                            !didRequestNewerForVisibleBottomSentinel,
                                            lastNewerLoadTriggerAnchorId != anchorId
                                        else { return }
                                        didRequestNewerForVisibleBottomSentinel = true
                                        lastNewerLoadTriggerAnchorId = anchorId
                                        pendingAppendAnchorId = anchorId
                                        Task {
                                            await workspace.loadNewerMessages(groupIdHex: chat.id)
                                            if pendingAppendAnchorId == anchorId,
                                                workspace.selectedMessageIDs.last == anchorId
                                            {
                                                pendingAppendAnchorId = nil
                                            }
                                        }
                                    }
                                    .onDisappear {
                                        guard pendingAppendAnchorId == nil else { return }
                                        bottomSentinelResetTask?.cancel()
                                        bottomSentinelResetTask = Task {
                                            try? await Task.sleep(nanoseconds: 300_000_000)
                                            guard !Task.isCancelled else { return }
                                            await MainActor.run {
                                                guard pendingAppendAnchorId == nil else { return }
                                                didRequestNewerForVisibleBottomSentinel = false
                                            }
                                        }
                                    }
                            }
                        }

                        Color.clear
                            .frame(height: bottomTranscriptPadding)
                            .id(bottomAnchorId)
                            .onAppear { isPinnedToBottom = true }
                            .onDisappear { isPinnedToBottom = false }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                }
                .id(chat.id)
                .defaultScrollAnchor(.bottom)
                .onChange(of: chat.id) { _, _ in
                    topSentinelResetTask?.cancel()
                    bottomSentinelResetTask?.cancel()
                    pendingPrependAnchorId = nil
                    pendingAppendAnchorId = nil
                    isPinnedToBottom = true
                    didRequestOlderForVisibleTopSentinel = false
                    lastOlderLoadTriggerAnchorId = nil
                    topSentinelResetTask = nil
                    didRequestNewerForVisibleBottomSentinel = false
                    lastNewerLoadTriggerAnchorId = nil
                    bottomSentinelResetTask = nil
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
                                workspace.selectedMessageIDs.contains(anchorId)
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
                        messageIDs.contains(anchorId)
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
                            workspace.selectedMessageIDs.contains(anchorId)
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
                }

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
                    .disabled(workspace.isSending || workspace.isRecordingVoiceMessage)
                    .help("Attach files")

                    TextField("Message", text: $workspace.draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            MessagesComposerFieldBackground()
                        }
                        .disabled(workspace.isRecordingVoiceMessage)

                    Button {
                        Task { await workspace.toggleVoiceRecording() }
                    } label: {
                        Image(systemName: workspace.isRecordingVoiceMessage ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background {
                                MessagesCircleControlBackground(isActive: workspace.isRecordingVoiceMessage)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending)
                    .help(workspace.isRecordingVoiceMessage ? "Finish recording" : "Voice message")

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

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }
}

private struct PendingMediaDraftStrip: View {
    let attachments: [PendingMediaAttachment]
    let onRemove: (PendingMediaAttachment.ID) -> Void

    private let tileSize = CGSize(width: 74, height: 74)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        PendingMediaDraftTile(attachment: attachment, tileSize: tileSize)

                        Button {
                            onRemove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor), Color.primary.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                        .offset(x: 7, y: -7)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }
}

private struct PendingMediaDraftTile: View {
    let attachment: PendingMediaAttachment
    let tileSize: CGSize

    @State private var decodedImagePreview: NSImage?
    @State private var decodedImageCacheKey: String?

    // The composer only shows a handful of draft tiles. Keep thumbnails bounded while allowing
    // enough headroom for several ~148px previews and matching failed-decode entries.
    private static let imagePreviewCacheCountLimit = 64
    private static let failedImagePreviewCacheCountLimit = imagePreviewCacheCountLimit
    private static let imagePreviewCacheTotalCostLimit =
        PendingMediaDraftThumbnailDecoder.defaultDecodedCacheTotalCostLimit

    private static let imagePreviewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = imagePreviewCacheCountLimit
        cache.totalCostLimit = imagePreviewCacheTotalCostLimit
        return cache
    }()

    private static let failedImagePreviewCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = failedImagePreviewCacheCountLimit
        return cache
    }()

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
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
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
        Self.cacheKey(for: attachment, maxPixelSize: imagePreviewMaxPixelSize)
    }

    private var imagePreviewMaxPixelSize: CGFloat {
        ceil(max(tileSize.width, tileSize.height) * 2)
    }

    @MainActor
    private func loadImagePreview() async {
        let cacheKey = imagePreviewTaskID
        let nsCacheKey = cacheKey as NSString
        if decodedImageCacheKey == cacheKey {
            return
        }
        if let cached = Self.imagePreviewCache.object(forKey: nsCacheKey) {
            decodedImageCacheKey = cacheKey
            decodedImagePreview = cached
            return
        }
        if Self.failedImagePreviewCache.object(forKey: nsCacheKey) != nil {
            decodedImageCacheKey = cacheKey
            decodedImagePreview = nil
            return
        }

        decodedImageCacheKey = cacheKey
        decodedImagePreview = nil

        let data = attachment.data
        let maxPixelSize = imagePreviewMaxPixelSize
        let decoded = await Task.detached(priority: .utility) {
            PendingMediaDraftThumbnailDecoder.image(from: data, maxPixelSize: maxPixelSize)
        }.value

        guard decodedImageCacheKey == cacheKey else { return }
        if let decoded {
            Self.failedImagePreviewCache.removeObject(forKey: nsCacheKey)
            Self.imagePreviewCache.setObject(
                decoded,
                forKey: nsCacheKey,
                cost: PendingMediaDraftThumbnailDecoder.decodedCost(for: decoded)
            )
        } else {
            Self.failedImagePreviewCache.setObject(NSNumber(value: true), forKey: nsCacheKey)
        }
        decodedImagePreview = decoded
    }

    private static func cacheKey(for attachment: PendingMediaAttachment, maxPixelSize: CGFloat) -> String {
        "\(attachment.id.uuidString)|\(attachment.data.count)|\(Int(maxPixelSize))"
    }

    private var audioPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                ComposerAudioWaveformView(
                    samples: attachment.waveformSamples,
                    progress: 0,
                    barColor: Color.accentColor.opacity(0.82),
                    playedColor: Color.accentColor
                )
                .frame(height: 24)

                Text(attachment.durationLabel ?? attachment.sizeLabel)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
    }

    private var filePreview: some View {
        VStack(spacing: 5) {
            Image(systemName: attachment.kind.systemImageName)
                .font(.system(size: 18, weight: .semibold))
            Text(attachment.fileName)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private func iconPreview(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

enum PendingMediaDraftThumbnailDecoder {
    static let defaultDecodedCacheTotalCostLimit = 8 * 1024 * 1024

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
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func decodedCost(for image: NSImage) -> Int {
        let representation = image.representations.first
        let width = max(1, representation?.pixelsWide ?? Int(ceil(image.size.width)))
        let height = max(1, representation?.pixelsHigh ?? Int(ceil(image.size.height)))
        guard width <= Int.max / max(height, 1) / 4 else {
            return defaultDecodedCacheTotalCostLimit
        }
        return width * height * 4
    }
}

private struct VoiceRecordingComposerView: View {
    let samples: [CGFloat]
    let durationSeconds: Double
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Cancel recording")

            ComposerAudioWaveformView(
                samples: samples,
                progress: 0,
                barColor: Color.accentColor.opacity(0.70),
                playedColor: Color.accentColor,
                mode: .liveRecording
            )
            .frame(height: 30)

            Text(Self.durationLabel(durationSeconds))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Finish recording")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private static func durationLabel(_ duration: Double) -> String {
        MediaDurationLabel.string(for: duration)
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
    let samples: [CGFloat]
    let progress: CGFloat
    let barColor: Color
    let playedColor: Color
    var mode: ComposerAudioWaveformMode = .playback

    var body: some View {
        GeometryReader { geometry in
            let bars = ComposerAudioWaveformPresentation.bars(for: samples, mode: mode)
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

private struct TimelineInitialLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading messages...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading messages")
    }
}

private struct TimelinePageLoadingRow: View {
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

private struct ReplyComposerContextView: View {
    let context: MessageReplyContext
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MessagesPalette.sentBubble)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.senderName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(context.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .nativeGlassCircleButtonStyle()
            .help("Cancel reply")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard()
    }
}

private struct NewChatColumnView: View {
    @Environment(WorkspaceState.self) private var workspace
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Create New Chat")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    workspace.closeNewChatComposer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .nativeGlassCircleButtonStyle()
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Public key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextField("npub or hex public key", text: $workspace.newChatQuery)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onSubmit {
                                Task { await workspace.resolveNewChatQuery() }
                            }
                            .task(id: workspace.newChatQuery) {
                                // Debounce keystrokes and let `.task(id:)` cancel the
                                // pending lookup when the query changes again, so a
                                // flurry of edits no longer spawns overlapping,
                                // untracked tasks that race to write composer state.
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                guard !Task.isCancelled else { return }
                                await workspace.resolveNewChatQueryIfReady()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .glassCard()
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSearchFocused ? MessagesPalette.sentBubble : Color.clear, lineWidth: 1)
                            }
                    }

                    if workspace.isResolvingNewChat {
                        Label("Looking up profile...", systemImage: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let recipient = workspace.resolvedNewChatRecipient {
                        NewChatRecipientCard(recipient: recipient)
                    }

                    NewChatDetailsForm()

                    if let lastError = workspace.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
        }
        .background {
            GlassPaneBackground(opacity: 0.5)
        }
        .task {
            isSearchFocused = true
        }
    }
}

private struct NewChatDetailsForm: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Optional group name", text: $workspace.newChatName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .glassCard()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Optional description", text: $workspace.newChatDescription, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .glassCard()
            }

            Button {
                Task { await workspace.createNewChat() }
            } label: {
                Label(
                    workspace.isCreatingChat ? L10n.string("Creating...") : L10n.string("Create Chat"),
                    systemImage: "message"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .nativeGlassProminentButtonStyle()
            .disabled(workspace.resolvedNewChatRecipient == nil || workspace.isCreatingChat)
        }
    }
}

private struct NewChatRecipientCard: View {
    @Environment(WorkspaceState.self) private var workspace
    let recipient: NewChatRecipient

    var body: some View {
        let publicKey = recipient.npub.isEmpty ? recipient.accountIdHex : recipient.npub

        HStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: recipient.accountIdHex,
                initials: recipient.title,
                pictureURL: recipient.pictureURL,
                size: 44,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(recipient.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(DisplayText.short(publicKey, head: 12, tail: 10))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Button {
                        workspace.copyText(publicKey)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L10n.string("Copy npub"))
                }
            }

            Spacer()
        }
        .padding(12)
        .glassCard()
    }
}

struct ProfileImageAvatarView: View {
    @Environment(WorkspaceState.self) private var workspace
    let seed: String
    let initials: String
    let pictureURL: String?
    let size: CGFloat
    let isSelected: Bool

    /// Only returns a fetchable URL when the user has opted into loading remote images AND the
    /// URL passes the safety policy (https + valid host). Otherwise nil, so a generated avatar
    /// is shown and no outbound request is made to a sender-chosen server.
    private var imageURL: URL? {
        guard workspace.loadRemoteImages else { return nil }
        return RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
    }

    var body: some View {
        Group {
            if let imageURL {
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
        .modifier(AvatarChromeModifier(isSelected: isSelected))
    }
}

private struct ConversationHeader: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem

    var body: some View {
        @Bindable var workspace = workspace

        ZStack {
            VStack(spacing: 4) {
                ProfileImageAvatarView(
                    seed: chat.avatarSeed,
                    initials: chat.title,
                    pictureURL: chat.pictureURL,
                    size: 38,
                    isSelected: false
                )

                Text(chat.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
            .frame(maxWidth: 220)

            HStack {
                Spacer()

                if !chat.isDirect {
                    if chat.pendingConfirmation {
                        Button {
                            Task { await workspace.acceptGroupInvite(for: chat) }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background {
                                    MessagesCircleControlBackground()
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                        .help("Accept invite")

                        Button(role: .destructive) {
                            Task { await workspace.declineGroupInvite(for: chat) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background {
                                    MessagesCircleControlBackground()
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                        .help("Decline invite")
                    }

                    Button {
                        Task { await workspace.showGroupDetails(for: chat) }
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Group details")

                    Button {
                        workspace.showGroupImagePicker(for: chat)
                    } label: {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Set group image")
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
        .sheet(isPresented: $workspace.isGroupDetailsPresented) {
            GroupDetailsSheet(chat: chat)
        }
        .sheet(isPresented: $workspace.isGroupImagePickerPresented) {
            GroupImagePickerSheet()
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

private struct EmptyDrawerState: View {
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
