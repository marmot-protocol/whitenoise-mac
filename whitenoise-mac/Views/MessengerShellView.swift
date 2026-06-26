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

nonisolated private enum ComposerAudioWaveformMode {
    case playback
    case liveRecording
}

nonisolated private struct ComposerAudioWaveformBar: Equatable {
    let amplitude: CGFloat?
}

nonisolated private enum ComposerAudioWaveformPresentation {
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

private struct ComposerAudioWaveformView: View {
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

private struct ProfileImageAvatarView: View {
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

private struct GroupDetailsSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showArchiveConfirmation = false
    @State private var showLeaveConfirmation = false
    @State private var showSelfDemoteConfirmation = false
    let chat: ChatItem

    private var hasProfileChanges: Bool {
        guard let snapshot = workspace.groupDetailsSnapshot else { return false }
        return workspace.groupProfileDraftName.trimmingCharacters(in: .whitespacesAndNewlines) != snapshot.name
            || workspace.groupProfileDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                != snapshot.description
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileImageAvatarView(
                    seed: chat.avatarSeed,
                    initials: chat.title,
                    pictureURL: workspace.groupDetailsSnapshot?.avatarURL ?? chat.pictureURL,
                    size: 48,
                    isSelected: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.groupDetailsSnapshot?.name ?? chat.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(workspace.groupDetailsSnapshot?.memberCountLabel ?? "Group details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if workspace.isLoadingGroupDetails {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    workspace.closeGroupDetails()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .nativeGlassCircleButtonStyle()
                .help("Close")
            }
            .padding(20)

            GlassSeparator(axis: .horizontal)

            if let snapshot = workspace.groupDetailsSnapshot {
                Form {
                    if snapshot.pendingConfirmation {
                        Section("Invitation") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    "Accept this invite to confirm membership, or decline it to remove the group from your chat list."
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 10) {
                                    Button {
                                        Task { await workspace.acceptSelectedGroupInvite() }
                                    } label: {
                                        Label(
                                            workspace.isAcceptingGroupInvite
                                                ? L10n.string("Accepting...") : L10n.string("Accept Invite"),
                                            systemImage: "checkmark.circle"
                                        )
                                    }
                                    .nativeGlassProminentButtonStyle()
                                    .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)

                                    Button(role: .destructive) {
                                        Task { await workspace.declineSelectedGroupInvite() }
                                    } label: {
                                        Label(
                                            workspace.isDecliningGroupInvite
                                                ? L10n.string("Declining...") : L10n.string("Decline"),
                                            systemImage: "xmark.circle"
                                        )
                                    }
                                    .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)

                                    Spacer()
                                }
                            }
                        }
                    }

                    Section("Profile") {
                        TextField("Group name", text: $workspace.groupProfileDraftName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Description", text: $workspace.groupProfileDraftDescription, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)

                        HStack(spacing: 10) {
                            Button {
                                workspace.closeGroupDetails()
                                workspace.showGroupImagePicker(for: chat)
                            } label: {
                                Label("Search Web Image", systemImage: "photo.badge.plus")
                            }
                            .disabled(workspace.isSavingGroupImage)

                            Spacer()

                            Button {
                                Task { await workspace.saveGroupProfile() }
                            } label: {
                                Label(
                                    workspace.isSavingGroupProfile ? L10n.string("Saving...") : L10n.string("Save"),
                                    systemImage: "checkmark.circle")
                            }
                            .nativeGlassProminentButtonStyle()
                            .disabled(!hasProfileChanges || workspace.isSavingGroupProfile)
                        }
                    }

                    Section("Members") {
                        if snapshot.members.isEmpty {
                            ContentUnavailableView("No members", systemImage: "person.2.slash")
                                .frame(minHeight: 120)
                        } else {
                            ForEach(snapshot.members) { member in
                                GroupMemberRow(member: member)
                            }
                        }
                    }

                    if snapshot.canInvite {
                        Section("Invite") {
                            HStack(spacing: 10) {
                                TextField(
                                    "npub, profile link, or hex public key", text: $workspace.groupInviteMemberQuery
                                )
                                .textFieldStyle(.roundedBorder)

                                Button {
                                    Task { await workspace.inviteMemberToSelectedGroup() }
                                } label: {
                                    Label(
                                        workspace.isInvitingGroupMember
                                            ? L10n.string("Inviting...") : L10n.string("Invite"),
                                        systemImage: "person.badge.plus")
                                }
                                .disabled(
                                    workspace.isInvitingGroupMember
                                        || workspace.groupInviteMemberQuery.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty
                                )
                            }
                        }
                    }

                    Section("Group Actions") {
                        HStack(spacing: 10) {
                            Button(role: snapshot.archived ? nil : .destructive) {
                                showArchiveConfirmation = true
                            } label: {
                                Label(
                                    archiveButtonTitle(snapshot: snapshot),
                                    systemImage: snapshot.archived ? "tray.and.arrow.up" : "archivebox"
                                )
                            }
                            .disabled(workspace.isArchivingGroup)

                            if snapshot.isSelfAdmin {
                                Button(role: .destructive) {
                                    showSelfDemoteConfirmation = true
                                } label: {
                                    Label("Step Down as Admin", systemImage: "star.slash")
                                }
                                .disabled(workspace.mutatingGroupMemberId != nil || snapshot.isLastAdmin)
                            }

                            Button(role: .destructive) {
                                showLeaveConfirmation = true
                            } label: {
                                Label(
                                    workspace.isLeavingGroup ? L10n.string("Leaving...") : L10n.string("Leave Group"),
                                    systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .disabled(
                                workspace.isLeavingGroup || !snapshot.canLeave || snapshot.requiresSelfDemoteBeforeLeave
                            )

                            Spacer()
                        }

                        if snapshot.requiresSelfDemoteBeforeLeave {
                            Text("Demote yourself from admin before leaving this group.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if snapshot.isLastAdmin {
                            Text("Make another member an admin before stepping down or leaving.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if workspace.developerMode {
                        Section("Developer") {
                            HStack(spacing: 10) {
                                Button {
                                    Task { await workspace.copySelectedGroupTranscriptJSON() }
                                } label: {
                                    Label(
                                        workspace.isExportingGroupTranscript
                                            ? L10n.string("Copying Transcript...")
                                            : L10n.string("Copy Transcript JSON"),
                                        systemImage: "doc.on.doc"
                                    )
                                }
                                .disabled(workspace.isExportingGroupTranscript)

                                if let status = workspace.groupTranscriptExportStatus {
                                    Label(status, systemImage: "checkmark.circle")
                                        .font(.callout)
                                        .foregroundStyle(.green)
                                }
                            }

                            GroupDiagnosticsValueRow(title: "Group ID", value: snapshot.groupIdHex)
                            GroupDiagnosticsValueRow(title: "Nostr group ID", value: snapshot.nostrGroupIdHex)
                            GroupDiagnosticsValueRow(title: "Endpoint", value: snapshot.endpoint)
                            GroupDiagnosticsValueRow(title: "Avatar URL", value: snapshot.avatarURL ?? "")
                            GroupDiagnosticsValueRow(title: "Avatar dimension", value: snapshot.avatarDimension ?? "")
                            GroupDiagnosticsValueRow(
                                title: "Relays", value: snapshot.relays.joined(separator: "\n"), lineLimit: 4)
                            GroupDiagnosticsValueRow(
                                title: "Admins", value: snapshot.adminIds.joined(separator: "\n"), lineLimit: 4)
                            GroupDiagnosticsValueRow(
                                title: "Self admin",
                                value: snapshot.isSelfAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Last admin",
                                value: snapshot.isLastAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Can invite", value: snapshot.canInvite ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Can leave", value: snapshot.canLeave ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Pending confirmation",
                                value: snapshot.pendingConfirmation ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                        }
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("Group details unavailable", systemImage: "person.2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        SettingsErrorView(error: workspace.lastError)
                            .padding()
                    }
            }
        }
        .frame(width: 620, height: 720)
        .background {
            LiquidGlassBackground()
        }
        .confirmationDialog(
            archiveConfirmationTitle,
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            if let snapshot = workspace.groupDetailsSnapshot {
                Button(
                    snapshot.archived ? "Unarchive Group" : "Archive Group",
                    role: snapshot.archived ? nil : .destructive
                ) {
                    Task { await workspace.setSelectedGroupArchived(!snapshot.archived) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived groups are hidden from the active chat list.")
        }
        .confirmationDialog(
            "Step down as admin?",
            isPresented: $showSelfDemoteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Step Down", role: .destructive) {
                Task { await workspace.selfDemoteSelectedGroupAdmin() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stay in the group, but another admin will need to restore your admin status.")
        }
        .confirmationDialog(
            "Leave this group?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                Task { await workspace.leaveSelectedGroup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer receive messages from this group on this account.")
        }
    }

    private var archiveConfirmationTitle: String {
        if workspace.groupDetailsSnapshot?.archived == true {
            return L10n.string("Unarchive this group?")
        }
        return L10n.string("Archive this group?")
    }

    private func archiveButtonTitle(snapshot: GroupDetailsSnapshot) -> String {
        if workspace.isArchivingGroup {
            return snapshot.archived ? L10n.string("Unarchiving...") : L10n.string("Archiving...")
        }
        return snapshot.archived ? L10n.string("Unarchive Group") : L10n.string("Archive Group")
    }
}

private struct GroupDiagnosticsValueRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let title: String
    let value: String
    var lineLimit = 2
    var copyable = true

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("None") : trimmed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))

                Text(displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if copyable && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    workspace.copyText(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 24, height: 24)
                }
                .nativeGlassButtonStyle()
                .help("\(L10n.string("Copy")) \(title)")
            }
        }
    }
}

private struct GroupMemberRow: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showRemoveConfirmation = false
    let member: GroupMemberItem

    private var isMutating: Bool {
        workspace.mutatingGroupMemberId == member.id
    }

    private var hasActions: Bool {
        member.canPromote || member.canDemote || member.canRemove
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(seed: member.id, initials: member.initials, size: 34, isSelected: false)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if member.isAdmin {
                        Text("Admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                    }

                    if member.isSelf {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(member.detailLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isMutating {
                ProgressView()
                    .controlSize(.small)
            }

            if hasActions {
                Menu {
                    if member.canPromote {
                        Button("Make Admin") {
                            Task { await workspace.promoteGroupMember(member) }
                        }
                    }

                    if member.canDemote {
                        Button(member.isSelf ? "Demote Myself" : "Remove Admin") {
                            Task { await workspace.demoteGroupMember(member) }
                        }
                    }

                    if member.canRemove {
                        Button("Remove Member", role: .destructive) {
                            showRemoveConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .disabled(workspace.mutatingGroupMemberId != nil)
            }
        }
        .confirmationDialog(
            "Remove this member?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Member", role: .destructive) {
                Task { await workspace.removeGroupMember(member) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(member.displayName) from the group.")
        }
    }
}

private struct GroupImagePickerSheet: View {
    @Environment(WorkspaceState.self) private var workspace

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 168), spacing: 12)
    ]

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            if let chat = workspace.selectedChat {
                HStack(spacing: 12) {
                    ProfileImageAvatarView(
                        seed: chat.avatarSeed,
                        initials: chat.title,
                        pictureURL: chat.pictureURL,
                        size: 46,
                        isSelected: false
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Group image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        workspace.closeGroupImagePicker()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .nativeGlassCircleButtonStyle()
                    .help("Close")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                Divider()

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Search images", text: $workspace.groupImageSearchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task { await workspace.searchGroupImages() }
                            }

                        if workspace.isSearchingGroupImages {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            Task { await workspace.searchGroupImages() }
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .nativeGlassProminentButtonStyle()
                        .disabled(
                            workspace.groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || workspace.isSearchingGroupImages
                        )
                        .help("Search")
                    }

                    Text("Search terms are sent to Openverse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        SettingsErrorView(error: workspace.lastError)
                        Spacer()

                        if chat.pictureURL != nil {
                            Button {
                                Task { await workspace.clearGroupImage() }
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .controlSize(.small)
                            .disabled(workspace.isSavingGroupImage)
                        }
                    }
                    .frame(minHeight: 24)

                    ScrollView {
                        if workspace.groupImageResults.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text(workspace.isSearchingGroupImages ? "Searching" : "No images")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(workspace.groupImageResults) { result in
                                    Button {
                                        Task { await workspace.setGroupImage(result) }
                                    } label: {
                                        GroupImageResultTile(result: result)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(workspace.isSavingGroupImage)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 560)
        .background {
            LiquidGlassBackground()
        }
    }
}

private struct GroupImageResultTile: View {
    let result: GroupImageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)

                if let imageURL = result.previewURL {
                    DownsampledAsyncImage(url: imageURL, maxPixelSize: 320) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Image(systemName: "photo")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1.18, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(result.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.creditLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ConversationMessageRow: View {
    let message: MessageItem
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    // Receives the resolved MessageItem by value (not via a shared @Observable lookup),
    // so SwiftUI diffs each row by value and only re-runs the rows that actually changed
    // instead of invalidating every visible row on each page load / streaming update.
    var body: some View {
        if message.presentation.isChatBubble {
            MessageBubble(message: message, onOpenImageGallery: onOpenImageGallery)
        } else {
            TimelineNoticeRow(message: message)
        }
    }
}

private struct TimelineNoticeRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

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

                if workspace.streamingDebugEnabled {
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

private extension GroupImageSearchResult {
    var previewURL: URL? {
        if let thumbnailURL, let url = URL(string: thumbnailURL) {
            return url
        }
        return URL(string: imageURL)
    }
}

private struct MessageBubble: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var isInlineActionPresentationActive = false
    let message: MessageItem
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 72) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
                if !message.isOutgoing {
                    Text(message.senderName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                if !visualMediaAttachments.isEmpty {
                    MessageVisualMediaGrid(
                        message: message,
                        attachments: visualMediaAttachments,
                        isOutgoing: message.isOutgoing,
                        onOpenImageGallery: onOpenImageGallery
                    )
                }

                ForEach(nonvisualMediaAttachments) { attachment in
                    MessageMediaAttachmentView(
                        downloadState: workspace.mediaDownloadStateStore(for: message, attachment: attachment),
                        message: message,
                        attachment: attachment,
                        isOutgoing: message.isOutgoing
                    )
                }

                if hasBubbleContent {
                    bubbleContent
                }

                Text(message.metadataLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)

                if message.supportsChatActions && !message.reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.reactions) { reaction in
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
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 660, alignment: message.isOutgoing ? .trailing : .leading)

            if !message.isOutgoing {
                Spacer(minLength: 72)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if message.canCopyText || message.canDelete {
                MessageOverflowMenuItems(message: message)
            }
        }
        .onHover { isHovering = $0 }
    }

    private var showsInlineActions: Bool {
        message.supportsChatActions && (isHovering || isInlineActionPresentationActive)
    }

    private var trimmedBody: String {
        message.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasBubbleContent: Bool {
        workspace.streamingDebugEnabled
            || message.replyContext != nil
            || !trimmedBody.isEmpty
    }

    private var visualMediaAttachments: [MessageMediaAttachment] {
        message.mediaAttachments.filter { attachment in
            attachment.kind == .image || attachment.kind == .video
        }
    }

    private var nonvisualMediaAttachments: [MessageMediaAttachment] {
        message.mediaAttachments.filter { attachment in
            attachment.kind == .audio || attachment.kind == .file
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.streamingDebugEnabled {
                MessageDebugMetadataView(message: message, isOutgoing: message.isOutgoing)
            }

            if let replyContext = message.replyContext {
                MessageReplyContextView(context: replyContext, isOutgoing: message.isOutgoing)
            }

            if !trimmedBody.isEmpty {
                Text(message.body)
                    .font(.system(size: 15.5))
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .lineSpacing(2)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background {
            bubbleBackground
        }
        .frame(maxWidth: 540, alignment: message.isOutgoing ? .trailing : .leading)
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            if showsInlineActions {
                MessageInlineActions(
                    isPresentationActive: $isInlineActionPresentationActive,
                    message: message
                )
                .offset(x: message.isOutgoing ? -100 : 100)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.12), value: showsInlineActions)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: message.isOutgoing ? 20 : 6,
            bottomTrailingRadius: message.isOutgoing ? 6 : 20,
            topTrailingRadius: 20,
            style: .continuous
        )

        if message.isOutgoing {
            shape
                .fill(MessagesPalette.sentBubble)
        } else {
            shape
                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                .overlay {
                    shape
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.24), lineWidth: 1)
                }
        }
    }
}

private struct MessageImageGalleryPresentation: Identifiable, Equatable {
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

private struct MessageVisualMediaGrid: View {
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

    private var rowCount: Int {
        MessageMediaGridPresentation.rowCount(totalCount: attachments.count)
    }

    private var tileSide: CGFloat {
        MessageMediaGridPresentation.tileSide(totalCount: attachments.count, maxWidth: maxWidth, spacing: spacing)
    }

    private var gridHeight: CGFloat {
        MessageMediaGridPresentation.gridHeight(totalCount: attachments.count, maxWidth: maxWidth, spacing: spacing)
    }

    private var rowStarts: [Int] {
        rowCount == 1 ? [0] : [0, columnCount]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                HStack(spacing: spacing) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tile(at: rowStart + column)
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

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        if index < visibleAttachments.count {
            MessageVisualMediaTile(
                downloadState: workspace.mediaDownloadStateStore(for: message, attachment: visibleAttachments[index]),
                message: message,
                attachment: visibleAttachments[index],
                isOutgoing: isOutgoing,
                sideLength: tileSide,
                hiddenCount: index == MessageMediaGridPresentation.maxVisibleItems - 1 ? hiddenCount : 0,
                onOpenImageGallery: onOpenImageGallery
            )
        } else {
            Color.clear
                .frame(width: tileSide, height: tileSide)
        }
    }
}

private struct MessageVisualMediaTile: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var downloadState: MediaDownloadStateStore
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
        .task(id: attachment.id) {
            await workspace.loadMediaAttachment(attachment, for: message)
        }
        .onTapGesture {
            if attachment.kind == .image,
                let gallery = MessageImageGalleryPresentation(message: message, initialAttachment: attachment)
            {
                onOpenImageGallery(gallery)
            }
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
                    data: download.data,
                    cacheKey: attachment.id,
                    maxPixelSize: sideLength * max(1, displayScale) * 2
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

private struct MessageMediaAttachmentView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var downloadState: MediaDownloadStateStore
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
        .task(id: attachment.id) {
            await workspace.loadMediaAttachment(attachment, for: message)
        }
    }

    @ViewBuilder
    private func loadedContent(_ download: MessageMediaDownload) -> some View {
        switch attachment.kind {
        case .image:
            DownsampledDataImage(
                data: download.data,
                cacheKey: attachment.id,
                maxPixelSize: 260 * max(1, displayScale) * 2
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
        let type = download.mediaType.nilIfBlank ?? attachment.mediaType
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: download.sizeBytes), countStyle: .file)
        return "\(type) - \(size)"
    }
}

private struct MessageDocumentAttachmentRow: View {
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
        let type = download.mediaType.nilIfBlank ?? attachment.mediaType
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: download.sizeBytes), countStyle: .file)
        return "\(type) - \(size)"
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

private struct MessageAttachmentStatusRow: View {
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
        .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        }
    }

    private var iconBackground: Color {
        isOutgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)
    }

    private var rowBackground: Color {
        isOutgoing ? Color.white.opacity(0.12) : Color.primary.opacity(0.06)
    }
}

private struct PreparedMessageAudioPlayer: @unchecked Sendable {
    let player: AVAudioPlayer
}

@MainActor
private final class MessageAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onDidFinishPlaying: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        player.currentTime = 0
        onDidFinishPlaying?()
    }
}

private struct MessageAudioAttachmentPlayer: View {
    let download: MessageMediaDownload
    let fallbackFileName: String
    let isOutgoing: Bool
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackPreparationID: UUID?
    @State private var playbackProgress: CGFloat = 0
    @State private var metadata: MediaWaveformAnalyzer.Metadata?
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
                        samples: metadata?.samples ?? MediaWaveformAnalyzer.fallback(),
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
        .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOutgoing ? Color.white.opacity(0.12) : Color.primary.opacity(0.06))
        }
        .onDisappear {
            stopPlayback()
        }
        .task(id: "\(download.fileName)-\(download.sizeBytes)-\(download.mediaType)") {
            let data = download.data
            let mediaType = download.mediaType
            metadata = await Task.detached(priority: .utility) {
                MediaWaveformAnalyzer.metadata(from: data, mediaType: mediaType)
            }.value
        }
    }

    private var durationLabel: String {
        if let durationSeconds = metadata?.durationSeconds {
            return MediaDurationLabel.string(for: durationSeconds)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: download.sizeBytes), countStyle: .file)
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
                let data = download.data
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

private struct MessageVideoAttachmentPlayer: View {
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
                playbackTask?.cancel()
                playbackTask = nil
                stopPlayback()
            } else {
                playbackTask?.cancel()
                playbackTask = Task { await togglePlayback() }
            }
        }
        .onDisappear {
            playbackTask?.cancel()
            playbackTask = nil
            stopPlayback()
        }
        .accessibilityLabel("Video attachment")
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
        guard playbackPreparationID == nextPreparationID, !Task.isCancelled else { return }
        guard let url = resolvedURL else {
            didFail = true
            return
        }
        playbackURL = url
        let next = AVPlayer(url: url)
        player = next
        next.play()
    }

    /// Cancels in-flight preparation, releases the player, and deletes the decrypted scratch
    /// file. Ordered so `AVPlayer` no longer references the file before it is removed.
    private func stopPlayback() {
        playbackPreparationID = nil
        isLoading = false
        player?.pause()
        player = nil
        if let url = playbackURL {
            MessageMediaPlaybackFileStore.remove(at: url)
            playbackURL = nil
        }
    }
}

private enum MessageMediaPlaybackFileStore {
    /// Materializes decrypted attachment plaintext into the sandboxed playback scratch
    /// directory. Callers own the returned URL and must delete it via `remove(at:)` once
    /// the consuming action (open/playback) finishes.
    @MainActor
    static func fileURL(attachment: MessageMediaAttachment, download: MessageMediaDownload) async -> URL? {
        let resolvedFileName = download.fileName.nilIfBlank ?? attachment.fileName
        let resolvedMediaType = download.mediaType.nilIfBlank ?? attachment.mediaType
        let attachmentID = attachment.id
        let data = download.data

        return await Task.detached(priority: .utility) {
            do {
                let directory = try MediaPlaybackTempStore.directoryURL()
                return try MediaPlaybackTempStore.materialize(
                    data: data,
                    id: attachmentID,
                    fileName: resolvedFileName,
                    fallbackExtension: OutgoingMediaAttachmentPolicy.fileExtension(
                        for: resolvedMediaType,
                        fileName: resolvedFileName
                    ),
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

private struct MessageImageGalleryOverlay: View {
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
            .task(id: selectedAttachment.id) {
                await workspace.loadMediaAttachment(selectedAttachment, for: presentation.message)
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

private struct MessageImageGalleryContent: View {
    @Environment(WorkspaceState.self) private var workspace
    @ObservedObject var downloadState: MediaDownloadStateStore
    let message: MessageItem
    let attachment: MessageMediaAttachment

    var body: some View {
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
}

private struct DownsampledMessageGalleryImage: View {
    @Environment(\.displayScale) private var displayScale
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment

    var body: some View {
        GeometryReader { proxy in
            DownsampledDataImage(
                data: download.data,
                cacheKey: attachment.id,
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

private struct MessageDebugMetadataView: View {
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

private struct MessageInlineActions: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isEmojiPickerPresented = false
    @State private var isOverflowPresented = false
    @Binding var isPresentationActive: Bool
    let message: MessageItem

    var body: some View {
        HStack(spacing: 6) {
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

            if message.canCopyText || message.canDelete {
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
        .frame(width: 92, height: 32)
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

private struct MessageInlineActionIcon: View {
    let systemName: String
    let label: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}

private struct MessageEmojiPickerPopover: View {
    let onPick: (String) -> Void

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 8)
    private let emojis = [
        "👍", "👎", "❤️", "🔥", "🎉", "😂", "🤣", "😅",
        "😊", "😍", "😎", "🤔", "🙏", "👏", "🙌", "💪",
        "🤝", "👀", "😮", "😯", "😢", "😭", "😡", "🤯",
        "🥳", "😴", "🥲", "💯", "✅", "❌", "⭐️", "✨",
        "🚀", "👋", "🤙", "🫡", "🫶", "😬", "😇", "🤩",
        "🥹", "😆", "😁", "😄", "😋", "😌", "😐", "🙃",
        "😉", "😏", "😤", "😮‍💨", "🤗", "🤪", "🤨", "🧐",
        "💙", "💚", "💛", "🧡", "💜", "🤍", "🖤", "💔",
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 24))
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 360, height: 304)
        .presentationBackground(.regularMaterial)
        .glassCard(material: .regularMaterial)
    }
}

private struct MessageOverflowPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if message.canCopyText {
                overflowButton("Copy Text", systemImage: "doc.on.doc") {
                    workspace.copyText(of: message)
                    dismiss()
                }
            }

            if message.canCopyText && message.canDelete {
                Divider()
            }

            if message.canDelete {
                overflowButton("Delete", systemImage: "trash", role: .destructive) {
                    dismiss()
                    Task { await workspace.deleteMessage(message) }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 190)
        .presentationBackground(.regularMaterial)
        .glassCard(material: .regularMaterial)
    }

    private func overflowButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}

private struct MessageOverflowMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

    var body: some View {
        if message.canCopyText {
            Button {
                workspace.copyText(of: message)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
        }

        if message.canCopyText && message.canDelete {
            Divider()
        }

        if message.canDelete {
            Button(role: .destructive) {
                Task { await workspace.deleteMessage(message) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct MessageReplyContextView: View {
    let context: MessageReplyContext
    let isOutgoing: Bool

    var body: some View {
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
            }
        }
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

private struct SettingsPanelView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var page: SettingsPage {
        if case .settings(let page) = workspace.selection { return page }
        return .overview
    }

    var body: some View {
        Group {
            switch page {
            case .overview:
                ProfileSettingsView()
            case .accounts:
                AccountsSettingsView()
            case .profile:
                ProfileSettingsView()
            case .identityKeys:
                IdentityKeysSettingsView()
            case .relays:
                RelaySettingsView()
            case .keyPackages:
                KeyPackageSettingsView()
            case .appearance:
                AppearanceSettingsView()
            case .privacySecurity:
                PrivacySecuritySettingsView()
            case .notifications:
                NotificationsSettingsView()
            case .developerMode:
                DeveloperModeSettingsView()
            }
        }
        .background {
            LiquidGlassBackground()
        }
        .task(id: workspace.activeAccountId) {
            await workspace.loadSettingsData()
        }
    }
}

private struct SettingsHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var backAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let backAction {
                    Button(action: backAction) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .nativeGlassButtonStyle()
                    .help("Back to settings")
                }

                Text(title)
                    .font(.title2.weight(.semibold))

                Spacer()
            }

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background {
            GlassToolbarBackground()
        }
    }
}

private struct SettingsNativeForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsScaffold<Content: View>: View {
    @Environment(WorkspaceState.self) private var workspace
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var errorSectionTitle: LocalizedStringKey?
    let content: Content

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        errorSectionTitle: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.errorSectionTitle = errorSectionTitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: title, subtitle: subtitle)
            Divider()

            SettingsNativeForm {
                content
                errorSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = workspace.lastError {
            if let errorSectionTitle {
                Section(errorSectionTitle) {
                    SettingsErrorView(error: error)
                }
            } else {
                Section {
                    SettingsErrorView(error: error)
                }
            }
        }
    }
}

private struct AccountsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var accountPendingRemoval: AccountItem?

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Accounts",
            subtitle: "Manage the identities available on this Mac.",
            errorSectionTitle: "Status"
        ) {
            Section {
                ForEach(workspace.accounts) { account in
                    AccountSettingsRow(
                        account: account,
                        isActive: account.id == workspace.activeAccountId,
                        isRemoving: workspace.isRemovingAccount,
                        onSelect: {
                            workspace.selectAccountFromSettings(account)
                        },
                        onRemove: {
                            accountPendingRemoval = account
                        }
                    )
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text(
                    "Removing an account deletes its private key and local message history from this Mac. The identity itself is not deleted from the network."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Add Account") {
                SecureField("", text: $workspace.loginIdentity, prompt: Text("nsec1..."))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(workspace.isAuthenticating)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await workspace.login()
                            workspace.showSettingsPage(.accounts)
                        }
                    } label: {
                        Label(
                            workspace.isAuthenticating ? L10n.string("Logging in...") : L10n.string("Log in with key"),
                            systemImage: "key")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(
                        workspace.loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || workspace.isAuthenticating)

                    Button {
                        workspace.loginIdentity = ""
                        Task {
                            await workspace.signUp()
                            workspace.showSettingsPage(.accounts)
                        }
                    } label: {
                        Label(
                            workspace.isAuthenticating ? L10n.string("Creating...") : L10n.string("Create identity"),
                            systemImage: "plus.circle")
                    }
                    .nativeGlassButtonStyle()
                    .disabled(workspace.isAuthenticating)

                    Spacer()
                }
            }

        }
        .confirmationDialog(
            removeAccountTitle,
            isPresented: removeConfirmationBinding,
            titleVisibility: .visible,
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove Account", role: .destructive) {
                accountPendingRemoval = nil
                Task { await workspace.removeAccount(account) }
            }
            Button("Cancel", role: .cancel) {
                accountPendingRemoval = nil
            }
        } message: { _ in
            Text(
                "This deletes the private key and local message history for this identity from this Mac. This cannot be undone."
            )
        }
    }

    private var removeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { accountPendingRemoval != nil },
            set: { isPresented in
                if !isPresented { accountPendingRemoval = nil }
            }
        )
    }

    private var removeAccountTitle: String {
        if let account = accountPendingRemoval {
            return String(format: L10n.string("Remove %@?"), account.displayName)
        }
        return L10n.string("Remove account?")
    }
}

private struct AccountSettingsRow: View {
    let account: AccountItem
    let isActive: Bool
    let isRemoving: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.initials,
                        pictureURL: account.pictureURL,
                        size: 44,
                        isSelected: false
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            CopyableKeyLabel(accountIdHex: account.accountIdHex, showsCopyButton: false)

                            Text(account.localSigning ? L10n.string("Local signing") : L10n.string("Watch-only"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRemoving)

            PublicIdentityQRCodeButton(
                accountIdHex: account.accountIdHex,
                displayName: account.displayName
            )
            .disabled(isRemoving)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "person.crop.circle.badge.minus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(isRemoving)
            .help(L10n.string("Remove this account from this Mac"))
            .accessibilityLabel(Text(String(format: L10n.string("Remove %@"), account.displayName)))
        }
    }
}

private struct PublicIdentityQRCodeButton: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isPresented = false
    let accountIdHex: String
    let displayName: String

    private var npub: String {
        workspace.npub(forAccountIdHex: accountIdHex)
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "qrcode")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help("Show npub QR code")
        .accessibilityLabel(Text("Show npub QR code"))
        .sheet(isPresented: $isPresented) {
            PublicIdentityQRCodeSheet(displayName: displayName, npub: npub)
        }
    }
}

private struct PublicIdentityQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceState.self) private var workspace
    let displayName: String
    let npub: String

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("Public identity")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .nativeGlassCircleButtonStyle()
                .help("Close")
            }

            ZStack {
                Color.white
                QRCodeImageView(payload: npub)
                    .padding(22)
            }
            .frame(width: 320, height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }

            Text(DisplayText.short(npub, head: 24, tail: 24))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                Button {
                    workspace.copyText(npub)
                } label: {
                    Label("Copy npub", systemImage: "doc.on.doc")
                }
                .nativeGlassButtonStyle()

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .nativeGlassProminentButtonStyle()
            }
        }
        .padding(22)
        .frame(width: 420)
        .background {
            LiquidGlassBackground()
        }
    }
}

private struct QRCodeImageView: View {
    let payload: String

    var body: some View {
        if let image = Self.image(for: payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            ContentUnavailableView("QR code unavailable", systemImage: "qrcode")
                .foregroundStyle(.black)
        }
    }

    private static func image(for payload: String) -> NSImage? {
        guard !payload.isEmpty,
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }

        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct SettingsErrorView: View {
    let error: String?

    var body: some View {
        if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

private struct ProfileSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Profile",
            subtitle: "Publish the profile other people see for this identity."
        ) {
            if let account = workspace.activeAccount {
                Section("Preview") {
                    HStack(spacing: 12) {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: profilePreviewName(fallback: account),
                            pictureURL: workspace.profileDraft.picture,
                            size: 56,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profilePreviewName(fallback: account))
                                .font(.headline)
                                .lineLimit(1)
                            CopyableKeyLabel(accountIdHex: account.accountIdHex)
                        }

                        Spacer()

                        PublicIdentityQRCodeButton(
                            accountIdHex: account.accountIdHex,
                            displayName: profilePreviewName(fallback: account)
                        )
                    }
                }
            }

            Section("Profile") {
                TextField("Display name", text: $workspace.profileDraft.displayName)
                TextField("Name", text: $workspace.profileDraft.name)
                TextField("About", text: $workspace.profileDraft.about, axis: .vertical)
                    .lineLimit(3...5)
                TextField("Picture URL", text: $workspace.profileDraft.picture)
                TextField("NIP-05", text: $workspace.profileDraft.nip05)
                TextField("Lightning address", text: $workspace.profileDraft.lud16)
            }

            Section {
                HStack {
                    Button {
                        Task { await workspace.saveProfile() }
                    } label: {
                        Label(
                            workspace.isSavingProfile ? L10n.string("Saving...") : L10n.string("Save profile"),
                            systemImage: "checkmark.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isSavingProfile || workspace.activeAccount == nil)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

        }
    }

    private func profilePreviewName(fallback account: AccountItem) -> String {
        firstNonBlank([
            workspace.profileDraft.displayName,
            workspace.profileDraft.name,
            account.displayName,
        ]) ?? account.displayName
    }
}

private struct IdentityKeysSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showRemoveAccountConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: "Identity & Keys",
            subtitle: "Public identity details and local signing state."
        ) {
            if let account = workspace.activeAccount {
                Section("Account") {
                    HStack(spacing: 12) {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: account.initials,
                            pictureURL: account.pictureURL,
                            size: 52,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(
                                account.localSigning
                                    ? L10n.string("Local signing account") : L10n.string("Watch-only account")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Public Identity") {
                    let npub = workspace.npub(forAccountIdHex: account.accountIdHex)
                    LabeledContent("npub") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(npub)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)

                            Button {
                                workspace.copyText(npub)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("\(L10n.string("Copy")) npub")

                            PublicIdentityQRCodeButton(
                                accountIdHex: account.accountIdHex,
                                displayName: account.displayName
                            )
                        }
                    }
                }

                Section("Private Key") {
                    LabeledContent("Private key") {
                        Text(
                            account.localSigning
                                ? L10n.string("Stored in Keychain") : L10n.string("Not stored on this Mac")
                        )
                        .foregroundStyle(.secondary)
                    }

                    Button {
                    } label: {
                        Label("Copy Private Key", systemImage: "key")
                    }
                    .disabled(true)
                    .help("Private-key export is not exposed by MarmotKit in this build")
                }

                Section("Account Removal") {
                    Text(
                        "Remove this identity from this Mac. Messages and keys managed by Marmot for this account will no longer be available locally."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        showRemoveAccountConfirmation = true
                    } label: {
                        Label(
                            workspace.isRemovingAccount ? L10n.string("Removing...") : L10n.string("Remove Account"),
                            systemImage: "person.crop.circle.badge.minus")
                    }
                    .disabled(workspace.isRemovingAccount)
                }
            } else {
                Section {
                    ContentUnavailableView("No active account", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(minHeight: 220)
                }
            }

        }
        .confirmationDialog(
            removeAccountTitle,
            isPresented: $showRemoveAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                Task { await workspace.removeActiveAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected account from this Mac.")
        }
    }

    private var removeAccountTitle: String {
        if let account = workspace.activeAccount {
            return String(format: L10n.string("Remove %@?"), account.displayName)
        }
        return L10n.string("Remove account?")
    }
}

// Shows a user's public key as a truncated `npub` (derived from the hex), with an optional
// one-click copy-to-clipboard icon. Use everywhere a pubkey is surfaced so users always see
// — and can copy — the canonical npub form rather than raw hex.
private struct CopyableKeyLabel: View {
    @Environment(WorkspaceState.self) private var workspace
    let accountIdHex: String
    var head: Int = 12
    var tail: Int = 10
    var showsCopyButton: Bool = true

    var body: some View {
        let npub = workspace.npub(forAccountIdHex: accountIdHex)
        HStack(spacing: 6) {
            Text(DisplayText.short(npub, head: head, tail: tail))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if showsCopyButton {
                Button {
                    workspace.copyText(npub)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.string("Copy npub"))
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Appearance",
            subtitle: "Choose how White Noise follows macOS appearance."
        ) {
            Section("Appearance") {
                Picker(L10n.string("Theme"), selection: $workspace.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }

                Picker(L10n.string("Language"), selection: $workspace.languagePreference) {
                    ForEach(AppLanguage.pickerChoices) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Text(L10n.string("System follows your Mac language. Other choices update White Noise immediately."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }
}

private struct PrivacySecuritySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showDeleteAuditLogsConfirmation = false
    @State private var showDeleteAllDataConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: "Privacy & Security",
            subtitle: "Telemetry and audit logs stay off until you enable them."
        ) {
            Section("Remote Content") {
                Toggle(
                    isOn: Binding(
                        get: { workspace.loadRemoteImages },
                        set: { workspace.loadRemoteImages = $0 }
                    )
                ) {
                    Label("Load Remote Profile Images", systemImage: "person.crop.circle.badge.exclamationmark")
                }

                Text(
                    "Off by default. Profile pictures come from URLs other people control, so loading them reveals your IP address and when you're online to whoever sent them. Leave this off unless you trust the senders. Only secure (https) images are ever loaded."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Data Sharing") {
                Toggle(
                    isOn: Binding(
                        get: { workspace.privacySecuritySettings.relayTelemetryEnabled },
                        set: { enabled in
                            Task { await workspace.setRelayTelemetryEnabled(enabled) }
                        }
                    )
                ) {
                    Label("Anonymous Telemetry", systemImage: "waveform.path.ecg")
                }
                .disabled(workspace.isSavingPrivacySecurity)

                Toggle(
                    isOn: Binding(
                        get: { workspace.privacySecuritySettings.auditLoggingEnabled },
                        set: { enabled in
                            Task { await workspace.setAuditLoggingEnabled(enabled) }
                        }
                    )
                ) {
                    Label("Audit Logging", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(workspace.isSavingPrivacySecurity)

                if workspace.isSavingPrivacySecurity {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Audit Log Files") {
                HStack {
                    if workspace.isLoadingAuditLogFiles {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await workspace.loadAuditLogFiles() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(workspace.isLoadingAuditLogFiles)
                }

                if workspace.auditLogFiles.isEmpty {
                    HStack {
                        Spacer()

                        ContentUnavailableView("No audit logs", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: 320)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(workspace.auditLogFiles, id: \.path) { file in
                        AuditLogFileRow(file: file)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.uploadAuditLogFiles() }
                    } label: {
                        Label(
                            workspace.isUploadingAuditLogFiles
                                ? L10n.string("Uploading...") : L10n.string("Upload Now"), systemImage: "arrow.up.doc")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(
                        workspace.isUploadingAuditLogFiles
                            || !workspace.privacySecuritySettings.auditLogCredentialsAvailable
                    )

                    Button(role: .destructive) {
                        showDeleteAuditLogsConfirmation = true
                    } label: {
                        Label(
                            workspace.isDeletingAuditLogFiles ? L10n.string("Deleting...") : L10n.string("Delete All"),
                            systemImage: "trash")
                    }
                    .disabled(workspace.auditLogFiles.isEmpty || workspace.isDeletingAuditLogFiles)
                }

                if let auditLogUploadStatus = workspace.auditLogUploadStatus {
                    Label(auditLogUploadStatus, systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            }

            Section("Reset") {
                Button(role: .destructive) {
                    showDeleteAllDataConfirmation = true
                } label: {
                    Label(
                        workspace.isDeletingAllData ? L10n.string("Deleting...") : L10n.string("Delete All Data"),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(workspace.isDeletingAllData)

                Text("Reset White Noise to a newly installed state on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .task {
            await workspace.loadAuditLogFiles()
        }
        .confirmationDialog(
            "Delete all audit logs?",
            isPresented: $showDeleteAuditLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Audit Logs", role: .destructive) {
                Task { await workspace.deleteAllAuditLogFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every local audit JSONL file on this Mac.")
        }
        .alert("Delete all data?", isPresented: $showDeleteAllDataConfirmation) {
            Button("Delete All Data", role: .destructive) {
                Task { await workspace.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This clears all accounts, chats, and messages from this Mac and resets White Noise to a newly installed state. This cannot be undone."
            )
        }
    }
}

private struct AuditLogFileRow: View {
    let file: AuditLogFileFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(file.fileName)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(byteCount(file.sizeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(details)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(file.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        var parts = [shortAccountRef(file.accountRef)]
        if let modifiedAtMs = file.modifiedAtMs {
            let date = Date(timeIntervalSince1970: TimeInterval(modifiedAtMs) / 1_000)
            parts.append(DisplayText.dateTimeTimestamp(for: date))
        }
        return parts.joined(separator: " - ")
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func shortAccountRef(_ ref: String) -> String {
        let capped = String(ref.prefix(64))
        guard capped.count > 14 else { return capped }
        return "\(capped.prefix(8))...\(capped.suffix(6))"
    }
}

private struct NotificationsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Notifications",
            subtitle: "Local alerts for this Mac."
        ) {
            Section("Local Alerts") {
                Toggle(
                    isOn: Binding(
                        get: { workspace.notificationSettings.localNotificationsEnabled },
                        set: { enabled in
                            Task { await workspace.setLocalNotificationsEnabled(enabled) }
                        }
                    )
                ) {
                    Label("Local notifications", systemImage: "bell.badge")
                }
                .disabled(workspace.activeAccount == nil || workspace.isSavingNotifications)

                LabeledContent("Permission") {
                    HStack(spacing: 8) {
                        Text(workspace.notificationAuthorizationStatus.label)
                            .foregroundStyle(.secondary)
                        if workspace.isSavingNotifications {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if workspace.notificationAuthorizationStatus == .notDetermined {
                    Button {
                        Task { await workspace.requestLocalNotificationPermission() }
                    } label: {
                        Label("Allow Notifications", systemImage: "checkmark.circle")
                    }
                } else if workspace.notificationAuthorizationStatus == .denied {
                    Button {
                        workspace.openSystemNotificationSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gear")
                    }
                }
            }

            Section("Privacy") {
                Picker(L10n.string("Message preview"), selection: $workspace.notificationPreviewMode) {
                    ForEach(NotificationPreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!workspace.notificationSettings.localNotificationsEnabled)

                Text(workspace.notificationPreviewMode.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }
}

private struct DeveloperModeSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Developer mode",
            subtitle: "Storage and diagnostics."
        ) {
            Section("Developer") {
                Toggle(isOn: $workspace.developerMode) {
                    Label("Developer mode", systemImage: "stethoscope")
                }

                Toggle(isOn: $workspace.streamingDebugMode) {
                    Label("Streaming debug", systemImage: "waveform.path.ecg")
                }
                .disabled(!workspace.developerMode)
            }

            Section("Storage") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location")

                    Text(workspace.storageRootPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.storageRootPath, isDirectory: true))
                } label: {
                    Label("Open Storage Folder", systemImage: "folder")
                }
            }

            Section("Diagnostics") {
                ForEach(workspace.diagnosticsInfo) { item in
                    LabeledContent(item.title) {
                        Text(item.value)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

        }
    }
}

private struct RelaySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Relays",
            subtitle: "Manage the relay lists published for this account."
        ) {
            Section("Relay List") {
                Picker("Relay list", selection: $workspace.selectedRelaySection) {
                    ForEach(RelaySettingsSection.allCases) { section in
                        Text(section.label).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: workspace.selectedRelaySection) { _, section in
                    workspace.selectRelaySection(section)
                }

                Text(workspace.selectedRelaySection.description)
                    .foregroundStyle(.secondary)
            }

            Section {
                RelayDiagnosticsView(settings: workspace.relaySettings)
            }

            Section("Relays") {
                if workspace.relayDraft.isEmpty {
                    ContentUnavailableView("No relays", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(minHeight: 160)
                } else {
                    ForEach(workspace.relayDraft, id: \.self) { relay in
                        RelayRow(url: relay, isInsecure: workspace.isInsecureRelay(relay)) {
                            workspace.removeRelayDraftURL(relay)
                        }
                    }
                }
            }

            Section("Add Relay") {
                HStack(spacing: 8) {
                    TextField("", text: $workspace.newRelayURL, prompt: Text("wss://relay.example"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            workspace.addRelayDraftURL()
                        }
                        .frame(maxWidth: .infinity)

                    Button {
                        workspace.addRelayDraftURL()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add relay")
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.saveRelaySettings() }
                    } label: {
                        Label(
                            workspace.isSavingRelays ? L10n.string("Saving...") : L10n.string("Save relays"),
                            systemImage: "checkmark.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isSavingRelays || workspace.activeAccount == nil)

                    Button {
                        workspace.restoreRelayDraftDefaults()
                    } label: {
                        Label("Restore defaults", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(workspace.isSavingRelays)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

        }
    }
}

private struct RelayDiagnosticsView: View {
    let settings: RelaySettingsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: settings.isComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.isComplete ? .green : .orange)
                Text("Published Relay Lists")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(settings.isComplete ? L10n.string("Complete") : L10n.string("Missing"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            RelayDiagnosticsRow(title: "Default", systemImage: "network", relays: settings.defaultRelays)
            RelayDiagnosticsRow(
                title: "Bootstrap", systemImage: "antenna.radiowaves.left.and.right", relays: settings.bootstrapRelays)
            RelayDiagnosticsRow(title: "NIP-65", systemImage: "list.bullet", relays: settings.publishedNip65)
            RelayDiagnosticsRow(title: "Inbox", systemImage: "tray.and.arrow.down", relays: settings.publishedInbox)

            if !settings.missing.isEmpty {
                Text("Missing: \(settings.missing.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RelayDiagnosticsRow: View {
    let title: String
    let systemImage: String
    let relays: [String]

    var body: some View {
        DisclosureGroup {
            if relays.isEmpty {
                Text("Not published")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(relays, id: \.self) { relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Text("\(relays.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .font(.callout)
        }
    }
}

private struct KeyPackageSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        SettingsScaffold(
            title: "Key Packages",
            subtitle: "Manage the KeyPackages this identity has published for invites."
        ) {
            Section {
                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.publishNewKeyPackage() }
                    } label: {
                        Label(
                            workspace.isPublishingKeyPackage
                                ? L10n.string("Publishing...") : L10n.string("Publish new"), systemImage: "plus.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isPublishingKeyPackage || workspace.activeAccount == nil)

                    Button {
                        Task { await workspace.republishKeyPackage() }
                    } label: {
                        Label(
                            workspace.isRepublishingKeyPackage
                                ? L10n.string("Republishing...") : L10n.string("Republish latest"),
                            systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(workspace.isRepublishingKeyPackage || workspace.activeAccount == nil)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

            Section("Published Key Packages") {
                if workspace.keyPackages.isEmpty {
                    ContentUnavailableView("No key packages", systemImage: "key.slash")
                        .frame(minHeight: 220)
                } else {
                    ForEach(workspace.keyPackages) { package in
                        KeyPackageRow(package: package) {
                            Task { await workspace.deleteKeyPackage(package) }
                        }
                        .disabled(workspace.deletingKeyPackageId == package.id)
                    }
                }
            }

        }
        .task(id: workspace.activeAccountId) {
            await workspace.loadKeyPackages()
        }
    }
}

private struct KeyPackageRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let package: KeyPackageItem
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(MessagesPalette.sentBubble)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(package.sourceLabel)
                            .font(.callout.weight(.semibold))
                        Text(package.publishedLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    keyValue("Event", package.eventIdHex)

                    if workspace.developerMode {
                        keyValue("KeyPackageRef", package.keyPackageRefHex)
                        keyValue("Slot", package.keyPackageId)
                        Text("\(package.keyPackageBytes) bytes")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Delete key package")
                .disabled(package.eventIdHex.isEmpty || workspace.deletingKeyPackageId != nil)
            }

            if workspace.developerMode && !package.sourceRelays.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source relays")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(package.sourceRelays, id: \.self) { relay in
                        Text(relay)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 42)
            }
        }
        .padding(.vertical, 4)
    }

    private func keyValue(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? L10n.string("Unknown") : DisplayText.short(value, head: 12, tail: 10))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct RelayRow: View {
    let url: String
    var isInsecure: Bool = false
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isInsecure ? "lock.open.trianglebadge.exclamationmark" : "network")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isInsecure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .help(
                    isInsecure
                        ? L10n.string("Insecure cleartext relay (ws://). Relay metadata is not encrypted in transit.")
                        : "")

            VStack(alignment: .leading, spacing: 2) {
                Text(url)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)

                if isInsecure {
                    Text(
                        RelayURLValidator.classify(url) == .insecureLoopback
                            ? "Insecure — cleartext ws:// (loopback only)"
                            : "Insecure — cleartext ws:// (public host)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove relay")
        }
        .padding(.vertical, 4)
    }
}

private struct AvatarView: View {
    let seed: String
    let initials: String
    let size: CGFloat
    let isSelected: Bool
    /// Whether this view draws its own ring + drop shadow. Set to `false` when a wrapper
    /// (e.g. `ProfileImageAvatarView`) already owns the chrome, to avoid double-drawing it.
    var drawsChrome = true

    var body: some View {
        Text(DisplayText.initials(for: initials, fallback: seed))
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(AvatarPalette.gradient(for: seed))
            }
            .modifier(AvatarChromeModifier(isSelected: isSelected, isEnabled: drawsChrome))
    }
}

/// Applies the shared avatar ring + drop shadow. Centralized so `AvatarView` and
/// `ProfileImageAvatarView` stay visually identical and only one of them draws it.
private struct AvatarChromeModifier: ViewModifier {
    let isSelected: Bool
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? MessagesPalette.sentBubble : Color.white.opacity(0.2),
                            lineWidth: isSelected ? 3 : 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        } else {
            content
        }
    }
}

private enum AvatarPalette {
    private static let palettes: [[Color]] = [
        [Color(white: 0.24), Color(white: 0.46)],
        [Color(white: 0.30), Color(white: 0.58)],
        [Color(white: 0.18), Color(white: 0.42)],
        [Color(white: 0.36), Color(white: 0.64)],
        [Color(white: 0.22), Color(white: 0.54)],
    ]

    static func gradient(for seed: String) -> LinearGradient {
        // Use a deterministic hash so a given seed always maps to the same
        // palette across launches. `String.hashValue` is seeded with
        // per-process randomness (unstable colors) and `abs(_:)` traps on
        // `Int.min`; an unsigned FNV-1a over the UTF-8 bytes avoids both.
        let index = Int(stableHash(seed) % UInt64(palettes.count))
        return LinearGradient(colors: palettes[index], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// FNV-1a (64-bit) over the seed's UTF-8 bytes. Deterministic across
    /// launches and overflow-safe via wrapping arithmetic.
    private static func stableHash(_ seed: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV offset basis
        let prime: UInt64 = 0x0000_0100_0000_01b3  // FNV prime
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

private enum MessagesPalette {
    static let sentBubble = Color(nsColor: .systemBlue)
}

private struct MessagesSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            MessagesSearchFieldBackground()
        }
    }
}

private struct MessagesCircleControlBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var isSelected = false
    var isActive = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .overlay {
                Circle()
                    .stroke(strokeColor, lineWidth: 1)
            }
            .nativeBackgroundExtensionEffect()
    }

    private var fillColor: Color {
        if isActive {
            return Color.red.opacity(colorScheme == .dark ? 0.28 : 0.18)
        }
        if isSelected {
            return Color.white.opacity(colorScheme == .dark ? 0.16 : 0.34)
        }
        return Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18)
    }

    private var strokeColor: Color {
        if isActive {
            return Color.red.opacity(colorScheme == .dark ? 0.42 : 0.30)
        }
        return Color.white.opacity(colorScheme == .dark ? 0.08 : 0.32)
    }
}

private struct MessagesSidebarRowBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                isSelected
                    ? Color.white.opacity(colorScheme == .dark ? 0.13 : 0.28)
                    : Color.clear
            )
    }
}

private struct MessagesSearchFieldBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.28))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.28), lineWidth: 1)
            }
    }
}

private struct MessagesSendButtonBackground: View {
    let isEnabled: Bool

    var body: some View {
        Circle()
            .fill(isEnabled ? MessagesPalette.sentBubble : Color.white.opacity(0.08))
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1)
            }
    }
}

private struct MessagesComposerFieldBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.22))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.32), lineWidth: 1)
            }
    }
}

private struct MessagesWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.52 : 0.2)
        }
        .nativeBackgroundExtensionEffect()
        .ignoresSafeArea()
    }
}

private struct MessagesTranscriptBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .textBackgroundColor)
                .opacity(colorScheme == .dark ? 0.72 : 0.52)
        }
        .nativeBackgroundExtensionEffect()
        .ignoresSafeArea()
    }
}

private struct MessagesSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Level {
        case rail
        case drawer
    }

    let level: Level

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(backgroundOpacity)
        }
        .nativeBackgroundExtensionEffect()
        .ignoresSafeArea()
    }

    private var backgroundOpacity: Double {
        if colorScheme == .dark {
            switch level {
            case .rail: 0.5
            case .drawer: 0.44
            }
        } else {
            switch level {
            case .rail: 0.16
            case .drawer: 0.1
            }
        }
    }
}

private struct MessagesHeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.34 : 0.18)
        }
        .nativeBackgroundExtensionEffect()
    }
}

private struct MessagesComposerBarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.42 : 0.2)
        }
        .nativeBackgroundExtensionEffect()
    }
}

private struct GlassSeparator: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .vertical

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.08))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.18))
            }
    }
}

private struct GlassPaneBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let opacity: Double

    var body: some View {
        if #available(macOS 26.0, *) {
            background
                .backgroundExtensionEffect()
        } else {
            background
        }
    }

    private var background: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? opacity * 0.42 : opacity * 0.32)
        }
        .ignoresSafeArea()
    }
}

private struct GlassToolbarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            background
                .backgroundExtensionEffect()
        } else {
            background
        }
    }

    private var background: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.24 : 0.34)
        }
    }
}

private struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            background
                .backgroundExtensionEffect()
        } else {
            background
        }
    }

    private var background: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.18 : 0.28)
        }
        .ignoresSafeArea()
    }
}

private struct GlassRoundedBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 8
    var material: Material = .ultraThinMaterial
    var borderColor: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(material)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor ?? Color.white.opacity(colorScheme == .dark ? 0.16 : 0.34), lineWidth: 1)
            }
            .nativeBackgroundExtensionEffect()
    }
}

private struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var material: Material = .ultraThinMaterial
    var borderColor: Color?

    func body(content: Content) -> some View {
        content
            .background {
                GlassRoundedBackground(
                    cornerRadius: cornerRadius,
                    material: material,
                    borderColor: borderColor
                )
            }
    }
}

private struct GlassCapsuleBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var material: Material = .ultraThinMaterial
    var borderColor: Color?

    var body: some View {
        Capsule(style: .continuous)
            .fill(material)
            .overlay {
                Capsule(style: .continuous)
                    .stroke(borderColor ?? Color.white.opacity(colorScheme == .dark ? 0.14 : 0.3), lineWidth: 1)
            }
            .nativeBackgroundExtensionEffect()
    }
}

extension View {
    func glassCard(
        cornerRadius: CGFloat = 8,
        material: Material = .ultraThinMaterial,
        borderColor: Color? = nil
    ) -> some View {
        modifier(
            GlassCardModifier(
                cornerRadius: cornerRadius,
                material: material,
                borderColor: borderColor
            ))
    }

    @ViewBuilder
    func nativeGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// A circular glass icon button (e.g. close / cancel "✕" controls).
    @ViewBuilder
    func nativeGlassCircleButtonStyle() -> some View {
        self
            .buttonBorderShape(.circle)
            .nativeGlassButtonStyle()
    }

    @ViewBuilder
    func nativeGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func nativeBackgroundExtensionEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }

    @ViewBuilder
    func nativeWindowGlassBackground() -> some View {
        if #available(macOS 26.0, *) {
            self
                .containerBackground(.windowBackground, for: .window)
                .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        } else {
            self.background(.regularMaterial)
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
