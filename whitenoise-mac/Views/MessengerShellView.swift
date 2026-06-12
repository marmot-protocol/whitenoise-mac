import AppKit
import SwiftUI

struct MessengerShellView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Group {
            if workspace.showsMessengerChrome {
                HStack(spacing: 0) {
                    AccountRailView()
                    GlassSeparator()

                    ChatListDrawerView()
                        .frame(width: 312, alignment: .leading)
                        .frame(width: workspace.isChatListVisible ? 312 : 0, alignment: .leading)
                        .opacity(workspace.isChatListVisible ? 1 : 0)
                        .clipped()
                        .allowsHitTesting(workspace.isChatListVisible)

                    GlassSeparator()
                        .opacity(workspace.isChatListVisible ? 1 : 0)
                    DetailPaneView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                DetailPaneView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            LiquidGlassBackground()
        }
        .animation(.smooth(duration: 0.18), value: workspace.isChatListVisible)
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

            Text("White Noise")
                .font(.system(size: 34, weight: .semibold))

            HStack(spacing: 12) {
                Button {
                    Task { await workspace.signUp() }
                } label: {
                    Text(workspace.isAuthenticating && workspace.authenticationMode == .landing
                        ? L10n.string("Creating...")
                        : L10n.string("Create New Identity"))
                        .frame(width: 176)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(workspace.isAuthenticating)

                Button {
                    workspace.showLogin()
                } label: {
                    Text("Log in with Key")
                        .frame(width: 176)
                }
                .controlSize(.large)
                .disabled(workspace.isAuthenticating)
            }

            if workspace.authenticationMode == .login {
                VStack(spacing: 12) {
                    SecureField("nsec", text: $workspace.loginIdentity)
                        .textFieldStyle(.plain)
                        .frame(width: 360)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                                }
                        }
                        .disabled(workspace.isAuthenticating)

                    HStack(spacing: 10) {
                        Button("Cancel") {
                            workspace.cancelLogin()
                        }
                        .disabled(workspace.isAuthenticating)

                        Button(workspace.isAuthenticating ? L10n.string("Logging in...") : L10n.string("Log in")) {
                            Task { await workspace.login() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isAuthenticating)
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
            LiquidGlassBackground()
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
                    .frame(width: 34, height: 34)
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
                        Circle()
                            .fill(isSettingsSelected ? Color.white.opacity(0.14) : Color.clear)
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSettingsSelected ? Color.primary : Color.secondary)
            .help("Settings")
        }
        .padding(.vertical, 14)
        .frame(width: 68)
        .background {
            GlassPaneBackground(opacity: 0.72)
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
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Chats")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Button {
                            workspace.showNewChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("New chat")
                    }

                    SearchField(text: $workspace.searchText)
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 12)

                GlassSeparator(axis: .horizontal)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(workspace.filteredChats) { chat in
                            ChatRowButton(chat: chat)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .overlay {
                    if workspace.filteredChats.isEmpty {
                        EmptyDrawerState()
                    }
                }
            }
        }
        .background {
            GlassPaneBackground(opacity: 0.64)
        }
    }
}

private struct SettingsListDrawerView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

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
                LazyVStack(spacing: 4) {
                    ForEach(SettingsPage.sidebarPages, id: \.self) { page in
                        SettingsSidebarRow(page: page)
                    }
                }
                .padding(10)
            }

        }
        .background {
            GlassPaneBackground(opacity: 0.64)
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
                    Text(DisplayText.short(account.accountIdHex, head: 8, tail: 6))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Label("No account", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout.weight(.semibold))
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
        }
    }
}

private struct SettingsSidebarRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let page: SettingsPage

    private var isSelected: Bool {
        workspace.selection == .settings(page)
    }

    var body: some View {
        Button {
            workspace.showSettingsPage(page)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ChatRowButton: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem

    private var isSelected: Bool {
        workspace.selection == .chat(chat.id)
    }

    var body: some View {
        Button {
            workspace.selectChat(chat)
        } label: {
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
                        .background(Circle().fill(Color.accentColor))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.13) : Color.clear)
            }
        }
        .buttonStyle(.plain)
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

private struct ConversationView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var pendingPrependAnchorId: String?
    let chat: ChatItem
    private let bottomTranscriptPadding: CGFloat = 34

    var body: some View {
        @Bindable var workspace = workspace
        let messages = workspace.selectedMessages
        let paging = workspace.selectedTimelinePaging

        VStack(spacing: 0) {
            ConversationHeader(chat: chat)
            GlassSeparator(axis: .horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty {
                            EmptyConversationView()
                        } else {
                            if paging.hasMoreBefore {
                                TimelinePageLoadingRow(isLoading: paging.isLoadingBefore)
                                    .onAppear {
                                        guard pendingPrependAnchorId == nil else { return }
                                        let anchorId = messages.first?.id
                                        pendingPrependAnchorId = anchorId
                                        Task {
                                            await workspace.loadOlderMessages(groupIdHex: chat.id)
                                            if pendingPrependAnchorId == anchorId,
                                               workspace.selectedMessages.first?.id == anchorId {
                                                pendingPrependAnchorId = nil
                                            }
                                        }
                                    }
                            }

                            ForEach(messages) { message in
                                ConversationMessageRow(message: message)
                                    .equatable()
                            }
                        }

                        Color.clear
                            .frame(height: bottomTranscriptPadding)
                            .id(bottomAnchorId)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                }
                .id(chat.id)
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { previousMessageId, _ in
                    guard previousMessageId != nil,
                          !messages.isEmpty,
                          !paging.hasMoreBefore,
                          pendingPrependAnchorId == nil
                    else { return }
                    scrollToBottom(with: proxy)
                }
                .onChange(of: messages.first?.id) { _, _ in
                    guard let anchorId = pendingPrependAnchorId,
                          messages.contains(where: { $0.id == anchorId })
                    else { return }
                    DispatchQueue.main.async {
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

                HStack(spacing: 10) {
                    TextField("Message", text: $workspace.draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                                }
                        }

                    Button {
                        Task { await workspace.sendDraft() }
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!workspace.canSend)
                    .help("Send")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background {
                GlassToolbarBackground()
            }
        }
        .background {
            LiquidGlassBackground()
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
                .foregroundStyle(Color.accentColor)

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
            .buttonStyle(.plain)
            .help("Cancel reply")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                }
        }
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
                .buttonStyle(.plain)
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
                            .onChange(of: workspace.newChatQuery) { _, _ in
                                Task { await workspace.resolveNewChatQueryIfReady() }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSearchFocused ? Color.accentColor : Color.white.opacity(0.28), lineWidth: 1)
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
        .background(.thinMaterial)
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
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    }
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
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    }
            }

            Button {
                Task { await workspace.createNewChat() }
            } label: {
                Label(workspace.isCreatingChat ? L10n.string("Creating...") : L10n.string("Create Chat"), systemImage: "message")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(workspace.resolvedNewChatRecipient == nil || workspace.isCreatingChat)
        }
    }
}

private struct NewChatRecipientCard: View {
    let recipient: NewChatRecipient

    var body: some View {
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
                Text(recipient.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                }
        }
    }
}

private struct ProfileImageAvatarView: View {
    let seed: String
    let initials: String
    let pictureURL: String?
    let size: CGFloat
    let isSelected: Bool

    private var imageURL: URL? {
        guard let pictureURL = pictureURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pictureURL.isEmpty
        else { return nil }

        return URL(string: pictureURL)
    }

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        AvatarView(seed: seed, initials: initials, size: size, isSelected: isSelected)
                    }
                }
            } else {
                AvatarView(seed: seed, initials: initials, size: size, isSelected: isSelected)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.2), lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

private struct ConversationHeader: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem

    var body: some View {
        @Bindable var workspace = workspace

        HStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: chat.avatarSeed,
                initials: chat.title,
                pictureURL: chat.pictureURL,
                size: 42,
                isSelected: false
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(chat.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            if !chat.isDirect {
                Button {
                    workspace.showGroupImagePicker(for: chat)
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Set group image")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background {
            GlassToolbarBackground()
        }
        .sheet(isPresented: $workspace.isGroupImagePickerPresented) {
            GroupImagePickerSheet()
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
                    .buttonStyle(.plain)
                    .help("Close")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                Divider()

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)

                        TextField("Search Openverse", text: $workspace.groupImageSearchQuery)
                            .textFieldStyle(.plain)
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
                            Image(systemName: "arrow.forward.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isSearchingGroupImages)
                        .help("Search")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            }
                    }

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
            Rectangle()
                .fill(.regularMaterial)
        }
    }
}

private struct GroupImageResultTile: View {
    let result: GroupImageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.07))

                if let imageURL = result.previewURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .controlSize(.small)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(.secondary)
                        @unknown default:
                            EmptyView()
                        }
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
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ConversationMessageRow: View, Equatable {
    let message: MessageItem

    static func == (lhs: ConversationMessageRow, rhs: ConversationMessageRow) -> Bool {
        lhs.message == rhs.message
    }

    var body: some View {
        if message.presentation.isChatBubble {
            MessageBubble(message: message)
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
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
    @State private var isHovering = false
    @State private var isInlineActionPresentationActive = false
    let message: MessageItem

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 72) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if !message.isOutgoing {
                    Text(message.senderName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                HStack(alignment: .center, spacing: 8) {
                    bubbleContent
                }

                Text(message.statusLabel.map { "\(message.timeLabel)  \($0)" } ?? message.timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)

                if !message.reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.reactions) { reaction in
                            Text(reaction.label)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background {
                                    Capsule()
                                        .fill(.ultraThinMaterial)
                                        .overlay {
                                            Capsule()
                                                .stroke(reaction.isOwn ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.28), lineWidth: 1)
                                        }
                                }
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
            if message.supportsChatActions {
                MessageOverflowMenuItems(message: message)
            } else {
                Button {
                    workspace.copyText(of: message)
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private var showsInlineActions: Bool {
        message.supportsChatActions && (isHovering || isInlineActionPresentationActive)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let replyContext = message.replyContext {
                MessageReplyContextView(context: replyContext, isOutgoing: message.isOutgoing)
            }

            Text(message.body)
                .font(.system(size: 15))
                .foregroundStyle(message.isOutgoing ? .white : .primary)
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            bubbleBackground
        }
        .frame(maxWidth: 560, alignment: message.isOutgoing ? .trailing : .leading)
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
                .fill(Color.accentColor)
                .shadow(color: Color.accentColor.opacity(0.14), radius: 5, y: 2)
        } else {
            shape
                .fill(Color.primary.opacity(0.075))
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
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

            Button {
                workspace.startReply(to: message)
            } label: {
                MessageInlineActionIcon(systemName: "arrowshape.turn.up.left", label: "Reply")
            }
            .buttonStyle(.plain)
            .help("Reply")

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
        "💙", "💚", "💛", "🧡", "💜", "🤍", "🖤", "💔"
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
        .background(.regularMaterial)
    }
}

private struct MessageOverflowPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            overflowButton("Copy Text", systemImage: "doc.on.doc") {
                workspace.copyText(of: message)
                dismiss()
            }

            Divider()

            overflowButton("Delete", systemImage: "trash", role: .destructive) {
                dismiss()
                Task { await workspace.deleteMessage(message) }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 190)
        .background(.regularMaterial)
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
        Button {
            workspace.copyText(of: message)
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            Task { await workspace.deleteMessage(message) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct MessageReplyContextView: View {
    let context: MessageReplyContext
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isOutgoing ? Color.white.opacity(0.72) : Color.accentColor.opacity(0.68))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : Color.accentColor)
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOutgoing ? Color.white.opacity(0.13) : Color.black.opacity(0.045))
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
                    .buttonStyle(.plain)
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
        .background(.ultraThinMaterial)
    }
}

private struct AccountsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            SettingsHeader(
                title: "Accounts",
                subtitle: "Manage the identities available on this Mac."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 10) {
                        ForEach(workspace.accounts) { account in
                            AccountSettingsRow(
                                account: account,
                                isActive: account.id == workspace.activeAccountId
                            ) {
                                workspace.selectAccountFromSettings(account)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Add Account")
                            .font(.callout.weight(.semibold))

                        SecureField("nsec", text: $workspace.loginIdentity)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                                    }
                            }
                            .disabled(workspace.isAuthenticating)

                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    await workspace.login()
                                    workspace.showSettingsPage(.accounts)
                                }
                            } label: {
                                Label(workspace.isAuthenticating ? L10n.string("Logging in...") : L10n.string("Log in with key"), systemImage: "key")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(workspace.loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isAuthenticating)

                            Button {
                                workspace.loginIdentity = ""
                                Task {
                                    await workspace.signUp()
                                    workspace.showSettingsPage(.accounts)
                                }
                            } label: {
                                Label(workspace.isAuthenticating ? L10n.string("Creating...") : L10n.string("Create identity"), systemImage: "plus.circle")
                            }
                            .disabled(workspace.isAuthenticating)

                            Spacer()
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            }
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AccountSettingsRow: View {
    let account: AccountItem
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
                        Text(DisplayText.short(account.accountIdHex, head: 12, tail: 10))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(account.localSigning ? L10n.string("Local signing") : L10n.string("Watch-only"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct CopyableSettingsValueRow: View {
    let title: String
    let value: String
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: copy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .help("\(L10n.string("Copy")) \(title)")
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
        }
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

        VStack(spacing: 0) {
            SettingsHeader(
                title: "Profile",
                subtitle: "Publish the profile other people see for this identity."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let account = workspace.activeAccount {
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
                                Text(DisplayText.short(account.accountIdHex, head: 12, tail: 10))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.bottom, 4)
                    }

                    SettingsTextField(title: "Display name", text: $workspace.profileDraft.displayName)
                    SettingsTextField(title: "Name", text: $workspace.profileDraft.name)
                    SettingsTextField(title: "About", text: $workspace.profileDraft.about, lineLimit: 3...5)
                    SettingsTextField(title: "Picture URL", text: $workspace.profileDraft.picture)
                    SettingsTextField(title: "NIP-05", text: $workspace.profileDraft.nip05)
                    SettingsTextField(title: "Lightning address", text: $workspace.profileDraft.lud16)

                    HStack {
                        Button {
                            Task { await workspace.saveProfile() }
                        } label: {
                            Label(workspace.isSavingProfile ? L10n.string("Saving...") : L10n.string("Save profile"), systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.isSavingProfile || workspace.activeAccount == nil)

                        if workspace.isLoadingSettings {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer()
                    }
                    .padding(.top, 4)

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func profilePreviewName(fallback account: AccountItem) -> String {
        for value in [workspace.profileDraft.displayName, workspace.profileDraft.name, account.displayName] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return account.displayName
    }
}

private struct IdentityKeysSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "Identity & Keys",
                subtitle: "Public identity details and local signing state."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let account = workspace.activeAccount {
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
                                Text(account.localSigning ? L10n.string("Local signing account") : L10n.string("Watch-only account"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, 2)

                        if let npub = account.npub?.trimmingCharacters(in: .whitespacesAndNewlines), !npub.isEmpty {
                            CopyableSettingsValueRow(
                                title: L10n.string("npub"),
                                value: npub
                            ) {
                                workspace.copyText(npub)
                            }
                        }

                        CopyableSettingsValueRow(
                            title: L10n.string("Public key"),
                            value: account.accountIdHex
                        ) {
                            workspace.copyText(account.accountIdHex)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            SettingsValueRow(
                                title: "Private key",
                                value: account.localSigning ? L10n.string("Stored in Keychain") : L10n.string("Not stored on this Mac")
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                            } label: {
                                Label("Copy Private Key", systemImage: "key")
                            }
                            .controlSize(.small)
                            .disabled(true)
                            .help("Private-key export is not exposed by MarmotKit in this build")
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                                }
                        }
                    } else {
                        ContentUnavailableView("No active account", systemImage: "person.crop.circle.badge.exclamationmark")
                            .frame(minHeight: 220)
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsTextField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var lineLimit: ClosedRange<Int> = 1...1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            TextField(title, text: $text, axis: lineLimit.upperBound > 1 ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(lineLimit)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        }
                }
        }
    }
}

private struct AppearanceSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            SettingsHeader(
                title: "Appearance",
                subtitle: "Choose how White Noise follows macOS appearance."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("Theme"))
                            .font(.callout.weight(.semibold))
                        Picker(L10n.string("Theme"), selection: $workspace.appearancePreference) {
                            ForEach(AppearancePreference.allCases) { preference in
                                Text(preference.label).tag(preference)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 240, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("Language"))
                            .font(.callout.weight(.semibold))
                        Picker(L10n.string("Language"), selection: $workspace.languagePreference) {
                            ForEach(AppLanguage.pickerChoices) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 240, alignment: .leading)
                    }

                    Text(L10n.string("System follows your Mac language. Other choices update White Noise immediately."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PrivacySecuritySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "Privacy & Security",
                subtitle: "Diagnostics exports are off until you enable them."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PrivacySecurityToggleRow(
                        systemImage: "waveform.path.ecg",
                        title: "Relay telemetry",
                        subtitle: workspace.privacySecuritySettings.relayTelemetryEnabled ? L10n.string("On") : L10n.string("Off"),
                        isSaving: workspace.isSavingPrivacySecurity,
                        isOn: Binding(
                            get: { workspace.privacySecuritySettings.relayTelemetryEnabled },
                            set: { enabled in
                                Task { await workspace.setRelayTelemetryEnabled(enabled) }
                            }
                        )
                    )

                    PrivacySecurityToggleRow(
                        systemImage: "doc.text.magnifyingglass",
                        title: "Audit log uploads",
                        subtitle: workspace.privacySecuritySettings.auditLogUploadsEnabled ? L10n.string("On") : L10n.string("Off"),
                        isSaving: workspace.isSavingPrivacySecurity,
                        isOn: Binding(
                            get: { workspace.privacySecuritySettings.auditLogUploadsEnabled },
                            set: { enabled in
                                Task { await workspace.setAuditLogUploadsEnabled(enabled) }
                            }
                        )
                    )

                    SettingsValueRow(
                        title: "Upload token",
                        value: workspace.privacySecuritySettings.hasObservabilityToken
                            ? L10n.string("Configured")
                            : L10n.string("Missing")
                    )

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PrivacySecurityToggleRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: String
    let isSaving: Bool
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isSaving)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
        }
    }
}

private struct NotificationsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            SettingsHeader(
                title: "Notifications",
                subtitle: "Local alerts for this Mac."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "bell.badge")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background {
                                    Circle().fill(Color.accentColor)
                                }

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Local notifications")
                                    .font(.callout.weight(.semibold))
                                Text(workspace.notificationAuthorizationStatus.label)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if workspace.isSavingNotifications {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Toggle("", isOn: Binding(
                                get: { workspace.notificationSettings.localNotificationsEnabled },
                                set: { enabled in
                                    Task { await workspace.setLocalNotificationsEnabled(enabled) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(workspace.activeAccount == nil || workspace.isSavingNotifications)
                        }

                        if workspace.notificationAuthorizationStatus == .notDetermined {
                            Button {
                                Task { await workspace.requestLocalNotificationPermission() }
                            } label: {
                                Label("Allow Notifications", systemImage: "checkmark.circle")
                            }
                            .controlSize(.small)
                        } else if workspace.notificationAuthorizationStatus == .denied {
                            Button {
                                workspace.openSystemNotificationSettings()
                            } label: {
                                Label("Open System Settings", systemImage: "gear")
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            }
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DeveloperModeSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            SettingsHeader(
                title: "Developer mode",
                subtitle: "Storage and diagnostics."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background {
                                Circle().fill(Color.accentColor)
                            }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Developer mode")
                                .font(.callout.weight(.semibold))
                            Text(workspace.developerMode ? L10n.string("On") : L10n.string("Off"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $workspace.developerMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)

                            Text("Storage")
                                .font(.callout.weight(.semibold))
                        }

                        SettingsValueRow(
                            title: "Location",
                            value: workspace.storageRootPath
                        )

                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: workspace.storageRootPath, isDirectory: true))
                        } label: {
                            Label("Open Storage Folder", systemImage: "folder")
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            }
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RelaySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            SettingsHeader(
                title: "Relays",
                subtitle: "Manage the relay lists published for this account."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Relay list")
                            .font(.callout.weight(.semibold))

                        Picker("Relay list", selection: $workspace.selectedRelaySection) {
                            ForEach(RelaySettingsSection.allCases) { section in
                                Text(section.label).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: workspace.selectedRelaySection) { _, section in
                            workspace.selectRelaySection(section)
                        }
                    }

                    Text(workspace.selectedRelaySection.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 0) {
                        if workspace.relayDraft.isEmpty {
                            ContentUnavailableView("No relays", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(minHeight: 160)
                        } else {
                            ForEach(workspace.relayDraft, id: \.self) { relay in
                                RelayRow(url: relay) {
                                    workspace.removeRelayDraftURL(relay)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("wss://relay.example", text: $workspace.newRelayURL)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                workspace.addRelayDraftURL()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                                    }
                            }

                        Button {
                            workspace.addRelayDraftURL()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add relay")
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await workspace.saveRelaySettings() }
                        } label: {
                            Label(workspace.isSavingRelays ? L10n.string("Saving...") : L10n.string("Save relays"), systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
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

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct KeyPackageSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "Key Packages",
                subtitle: "Manage the KeyPackages this identity has published for invites."
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await workspace.publishNewKeyPackage() }
                        } label: {
                            Label(workspace.isPublishingKeyPackage ? L10n.string("Publishing...") : L10n.string("Publish new"), systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.isPublishingKeyPackage || workspace.activeAccount == nil)

                        Button {
                            Task { await workspace.republishKeyPackage() }
                        } label: {
                            Label(workspace.isRepublishingKeyPackage ? L10n.string("Republishing...") : L10n.string("Republish latest"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(workspace.isRepublishingKeyPackage || workspace.activeAccount == nil)

                        if workspace.isLoadingSettings {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer()
                    }

                    if workspace.keyPackages.isEmpty {
                        ContentUnavailableView("No key packages", systemImage: "key.slash")
                            .frame(minHeight: 220)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(workspace.keyPackages) { package in
                                KeyPackageRow(package: package) {
                                    Task { await workspace.deleteKeyPackage(package) }
                                }
                                .disabled(workspace.deletingKeyPackageId == package.id)
                            }
                        }
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .padding(28)
                .frame(width: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        Circle().fill(Color.accentColor)
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
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
        }
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
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(url)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)

            Spacer()

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove relay")
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
    }
}

private struct AvatarView: View {
    let seed: String
    let initials: String
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        Text(DisplayText.initials(for: initials, fallback: seed))
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(AvatarPalette.gradient(for: seed))
            }
            .overlay {
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.2), lineWidth: isSelected ? 3 : 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

private enum AvatarPalette {
    private static let palettes: [[Color]] = [
        [Color(white: 0.24), Color(white: 0.46)],
        [Color(white: 0.30), Color(white: 0.58)],
        [Color(white: 0.18), Color(white: 0.42)],
        [Color(white: 0.36), Color(white: 0.64)],
        [Color(white: 0.22), Color(white: 0.54)]
    ]

    static func gradient(for seed: String) -> LinearGradient {
        let index = abs(seed.hashValue) % palettes.count
        return LinearGradient(colors: palettes[index], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct GlassSeparator: View {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .vertical

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.095))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .overlay {
                Rectangle()
                    .fill(Color.black.opacity(0.18))
            }
    }
}

private struct GlassPaneBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let opacity: Double

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(
                white: colorScheme == .dark ? 0.035 : 0.92
            )
            .opacity(opacity)
        }
        .ignoresSafeArea()
    }
}

private struct GlassToolbarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(
                white: colorScheme == .dark ? 0.045 : 0.98
            )
            .opacity(colorScheme == .dark ? 0.58 : 0.72)
        }
    }
}

private struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(
                white: colorScheme == .dark ? 0.045 : 0.95
            )
            Rectangle()
                .fill(.thickMaterial)
                .opacity(colorScheme == .dark ? 0.38 : 0.62)
            Color(
                white: colorScheme == .dark ? 0.055 : 1.0
            )
            .opacity(colorScheme == .dark ? 0.44 : 0.24)
        }
        .ignoresSafeArea()
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
            Label(workspace.accounts.isEmpty ? L10n.string("No accounts") : L10n.string("Select a chat"), systemImage: "bubble.left.and.bubble.right")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
