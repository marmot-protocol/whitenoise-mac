//
//  SidebarViews.swift
//  whitenoise-mac
//
//  Left-hand navigation: the account rail, chat-list and settings-list
//  drawers, their rows, and the pending-invite badge. The settings drawer
//  opens with the account switcher card (SettingsAccountSwitcherViews.swift)
//  above the page list.
//

import AppKit
import SwiftUI

struct UnreadCountBadge: View {
    let count: Int
    var textStyle: WNTextStyle = .bold10

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .wnFont(textStyle)
            // `fillInfo` + `fillContentInfo`: a white count on a blue pill in both appearances.
            // Deliberately *not* `fillPrimary`, which this used to take — that token is already the
            // sent bubble, the send button and the selected row, so an unread count drawn in it read
            // as chrome instead of as something waiting for you.
            .foregroundStyle(WNColor.fillContentInfo)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(WNColor.fillInfo))
    }
}

struct AccountRailView: View {
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
                    .wnFont(.semiBold16)
                    .frame(width: MessagesLayout.accountRailControlSize, height: MessagesLayout.accountRailControlSize)
                    .background {
                        MessagesCircleControlBackground(isSelected: workspace.isChatListVisible)
                    }
            }
            .buttonStyle(.plain)
            .help(workspace.isChatListVisible ? L10n.string("Hide chat list") : L10n.string("Show chat list"))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(workspace.accounts) { account in
                        AccountRailAvatar(account: account)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            Button {
                workspace.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .wnFont(.semiBold18)
                    .frame(width: MessagesLayout.accountRailControlSize, height: MessagesLayout.accountRailControlSize)
                    .background {
                        MessagesCircleControlBackground(isSelected: isSettingsSelected)
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                isSettingsSelected ? WNColor.fillContentSecondary : WNColor.fillContentTertiary
            )
            .help(L10n.string("Settings"))
        }
        .padding(.top, MessagesLayout.sidebarTitlebarTopPadding)
        .padding(.bottom, 14)
        .frame(width: MessagesLayout.accountRailWidth)
        .background {
            MessagesSidebarBackground(level: .rail)
        }
    }
}

/// A single account avatar in the rail: selects on tap (or signs back in when the
/// account is signed out), dims signed-out accounts, overlays an unread badge, and
/// offers Sign In / Sign Out via context menu.
private struct AccountRailAvatar: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem

    private var unread: Int { workspace.unreadCount(forAccountIdHex: account.accountIdHex) }
    private var isActive: Bool { account.id == workspace.activeAccountId }

    var body: some View {
        Button {
            if account.signedOut {
                Task { await workspace.signInAccount(account) }
            } else {
                workspace.selectAccount(account)
            }
        } label: {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: account.initials,
                sanitizedPictureURL: account.sanitizedPictureURL,
                size: MessagesLayout.accountRailAvatarSize,
                isSelected: isActive
            )
            .frame(width: MessagesLayout.accountRailAvatarFrameSize, height: MessagesLayout.accountRailAvatarFrameSize)
            .contentShape(Circle())
            .opacity(account.signedOut ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                badge
            }
        }
        .buttonStyle(.plain)
        .disabled(account.signedOut && workspace.isAccountMutationInProgress)
        .help(account.signedOut ? "\(account.displayName) — \(L10n.string("Signed out"))" : account.displayName)
        .contextMenu {
            Group {
                if account.signedOut {
                    Button {
                        Task { await workspace.signInAccount(account) }
                    } label: {
                        Label(L10n.string("Sign In"), systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(workspace.isAccountMutationInProgress)
                } else {
                    Button {
                        Task { await workspace.signOutAccount(account) }
                    } label: {
                        Label(L10n.string("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(workspace.isAccountMutationInProgress)
                }
            }
            .menuLabelIcons()
        }
    }

    @ViewBuilder
    private var badge: some View {
        if account.signedOut {
            Image(systemName: "pause.circle.fill")
                .wnFont(.medium16)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                // Punched out of the rail behind it, so it takes the rail's own surface rather
                // than the system window color.
                .background(Circle().fill(WNColor.backgroundTertiary))
        } else if unread > 0 {
            UnreadCountBadge(count: unread)
                .overlay(Capsule().strokeBorder(WNColor.backgroundTertiary, lineWidth: 1.5))
        }
    }
}

struct ChatListDrawerView: View {
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
                switch workspace.composePane {
                case .newChat:
                    NewChatPanelView()
                case .chooseMembers:
                    ChooseMembersPanelView()
                case .nameGroup:
                    NameGroupPanelView()
                }
            } else {
                let filter = workspace.chatListFilter
                let isShowingArchived = filter == .archived
                let visibleChats = visibleChats(for: filter)
                let isCollapsed = workspace.isChatListCollapsed

                if isCollapsed {
                    CollapsedChatListHeader(isShowingArchived: isShowingArchived)
                } else {
                    ChatListHeader(filter: filter, isShowingArchived: isShowingArchived)
                }

                GlassSeparator(axis: .horizontal)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(visibleChats) { chat in
                            ChatSidebarRow(
                                chat: chat,
                                isArchived: isShowingArchived,
                                isCollapsed: isCollapsed,
                                searchResult: workspace.sidebarMessageSearchResult(for: chat)
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier(isShowingArchived ? "chat.archived.list" : "chat.list")
                .overlay {
                    // `ContentUnavailableView` needs room for an icon over two lines of prose;
                    // in the collapsed rail it would render as a column of hyphenated fragments.
                    // An empty rail is legible on its own, and widening it brings the wording back.
                    if visibleChats.isEmpty, !isCollapsed {
                        if workspace.isSearchingSidebarMessages {
                            ProgressView()
                                .controlSize(.small)
                        } else if !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView(
                                L10n.string("No matching chats"),
                                systemImage: "magnifyingglass"
                            )
                            .padding()
                        } else {
                            switch filter {
                            case .archived:
                                ArchivedEmptyDrawerState()
                            case .unread:
                                UnreadEmptyDrawerState()
                            case .active:
                                EmptyDrawerState()
                            }
                        }
                    }
                }
            }
        }
        .background {
            MessagesSidebarBackground(level: .drawer)
        }
    }
}

extension ChatListDrawerView {
    fileprivate func visibleChats(for filter: ChatListFilter) -> [ChatItem] {
        let chats: [ChatItem]
        switch filter {
        case .active:
            chats = workspace.activeChats
        case .unread:
            chats = workspace.activeChats.filter(\.hasUnread)
        case .archived:
            chats = workspace.archivedChats
        }
        return workspace.sidebarSearchFilteredChats(chats)
    }
}

private struct ChatListHeader: View {
    @Environment(WorkspaceState.self) private var workspace
    let filter: ChatListFilter
    let isShowingArchived: Bool

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(filter.title)
                    .wnFont(MessagesType.paneTitle)
                Spacer()
                Button {
                    workspace.presentGlobalMessageSearch()
                } label: {
                    Image(systemName: "text.magnifyingglass")
                        .wnFont(.semiBold14)
                        .frame(width: 34, height: 34)
                        .background {
                            MessagesCircleControlBackground()
                        }
                }
                .buttonStyle(.plain)
                .help(L10n.string("Search all messages"))
                if !isShowingArchived {
                    Button {
                        workspace.showNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .wnFont(.semiBold14)
                            .frame(width: 34, height: 34)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)
                    .help(L10n.string("New chat"))
                }
            }

            HStack(spacing: 8) {
                MessagesSearchField(
                    text: $workspace.searchText,
                    accessibilityIdentifier: "chat.search",
                    placeholder: L10n.string("Search all messages")
                )
                .frame(maxWidth: .infinity)
                .onChange(of: workspace.searchText) { _, _ in
                    workspace.scheduleSidebarMessageSearch()
                }

                if workspace.isSearchingSidebarMessages {
                    ProgressView()
                        .controlSize(.small)
                }

                ChatListFilterMenu()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, MessagesLayout.sidebarTitlebarTopPadding)
        .padding(.bottom, 12)
    }
}

/// Header for the avatar-only rail: the pane title and the row-filtering search field have no
/// room, so what is left is the three controls that still make sense at 84pt, stacked. Global
/// search stays reachable (it opens its own sheet), which is why dropping the inline field is
/// survivable — and `resizeChatListDrawer` clears any query on the way in, so the rail can
/// never show a silently filtered list.
private struct CollapsedChatListHeader: View {
    @Environment(WorkspaceState.self) private var workspace
    let isShowingArchived: Bool

    var body: some View {
        VStack(spacing: 8) {
            Button {
                workspace.presentGlobalMessageSearch()
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .wnFont(.semiBold14)
                    .frame(width: 34, height: 34)
                    .background {
                        MessagesCircleControlBackground()
                    }
            }
            .buttonStyle(.plain)
            .help(L10n.string("Search all messages"))

            if !isShowingArchived {
                Button {
                    workspace.showNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .wnFont(.semiBold14)
                        .frame(width: 34, height: 34)
                        .background {
                            MessagesCircleControlBackground()
                        }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .help(L10n.string("New chat"))
            }

            ChatListFilterMenu()
        }
        .padding(.horizontal, 8)
        .padding(.top, MessagesLayout.sidebarTitlebarTopPadding)
        .padding(.bottom, 12)
    }
}

private struct ChatListFilterMenu: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isFilterPickerPresented = false

    var body: some View {
        Button {
            isFilterPickerPresented = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .wnFont(.semiBold16)
                .frame(width: 34, height: 34)
                .background {
                    MessagesCircleControlBackground(isSelected: workspace.chatListFilter != .active)
                }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isFilterPickerPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ChatListFilter.allCases, id: \.self) { filter in
                    filterButton(filter)
                }
            }
            .padding(8)
        }
        .help(L10n.string("Filter chats"))
        .accessibilityIdentifier("chat.list.filter")
    }

    private func filterButton(_ filter: ChatListFilter) -> some View {
        Button {
            workspace.chatListFilter = filter
            isFilterPickerPresented = false
        } label: {
            HStack(spacing: 8) {
                if workspace.chatListFilter == filter {
                    Image(systemName: "checkmark")
                        .frame(width: 14)
                } else {
                    Color.clear
                        .frame(width: 14, height: 1)
                }

                // Fixed width keeps the titles aligned across icons of differing widths.
                Image(systemName: filter.systemImage)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(filter.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if workspace.chatListFilter == filter {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(WNColor.fillTertiaryHover)
            }
        }
    }
}

private struct ArchivedEmptyDrawerState: View {
    var body: some View {
        ContentUnavailableView(L10n.string("No archived chats"), systemImage: "archivebox")
            .padding()
    }
}

private struct UnreadEmptyDrawerState: View {
    var body: some View {
        ContentUnavailableView(L10n.string("No unread chats"), systemImage: "bubble.left")
            .padding()
    }
}

private struct ChatSidebarRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem
    let isArchived: Bool
    let isCollapsed: Bool
    let searchResult: GlobalMessageSearchResult?

    var body: some View {
        Button {
            workspace.selectChat(chat)
        } label: {
            if isCollapsed {
                CollapsedChatRowContent(
                    chat: chat,
                    isSelected: workspace.selection == .chat(chat.id)
                )
            } else {
                ChatRowContent(
                    chat: chat,
                    isSelected: workspace.selection == .chat(chat.id),
                    isPinned: !isArchived && workspace.isChatPinned(chat),
                    searchResult: searchResult
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isArchived ? "chat.archived.row.\(chat.id)" : "chat.row.\(chat.id)")
        .contextMenu {
            ChatSidebarRowMenuItems(chat: chat, isArchived: isArchived)
        }
    }
}

private struct ChatSidebarRowMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem
    let isArchived: Bool

    private var isArchiving: Bool {
        workspace.archivingChatId == chat.id
    }

    var body: some View {
        Group {
            Button {
                Task {
                    await workspace.setChatManuallyUnread(
                        chat,
                        manuallyUnread: !chat.manuallyMarkedUnread
                    )
                }
            } label: {
                Label(
                    chat.manuallyMarkedUnread
                        ? L10n.string("Clear Unread Reminder")
                        : L10n.string("Mark as Unread"),
                    systemImage: chat.manuallyMarkedUnread ? "envelope.open" : "envelope.badge"
                )
            }
            .disabled(workspace.isMutatingChatPreferences(chat))

            if chat.muted {
                Button {
                    Task { await workspace.clearChatMuted(chat) }
                } label: {
                    Label(L10n.string("Unmute"), systemImage: "bell")
                }
                .disabled(workspace.isMutatingChatPreferences(chat))
            } else {
                Menu {
                    Button {
                        Task { await workspace.setChatMuted(chat, duration: 60 * 60) }
                    } label: {
                        Label(L10n.string("For 1 Hour"), systemImage: "clock")
                    }
                    Button {
                        Task { await workspace.setChatMuted(chat, duration: 8 * 60 * 60) }
                    } label: {
                        Label(L10n.string("For 8 Hours"), systemImage: "clock")
                    }
                    Button {
                        Task { await workspace.setChatMuted(chat, duration: 7 * 24 * 60 * 60) }
                    } label: {
                        Label(L10n.string("For 1 Week"), systemImage: "calendar")
                    }
                    Button {
                        Task { await workspace.setChatMuted(chat, duration: nil) }
                    } label: {
                        Label(L10n.string("Until I Turn It Back On"), systemImage: "infinity")
                    }
                } label: {
                    Label(L10n.string("Mute"), systemImage: "bell.slash")
                }
                .disabled(workspace.isMutatingChatPreferences(chat))
            }

            Divider()

            if isArchived {
                Button {
                    Task { await workspace.setChatArchived(chat, archived: false) }
                } label: {
                    Label(L10n.string("Unarchive"), systemImage: "tray.and.arrow.up")
                }
                .disabled(isArchiving)
            } else {
                let isPinned = workspace.isChatPinned(chat)
                Button {
                    workspace.setChatPinned(chat, pinned: !isPinned)
                } label: {
                    Label(
                        isPinned ? L10n.string("Unpin") : L10n.string("Pin to Top"),
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }

                Divider()

                Button {
                    Task { await workspace.setChatArchived(chat, archived: true) }
                } label: {
                    Label(L10n.string("Archive"), systemImage: "archivebox")
                }
                .disabled(isArchiving)
            }

            destructiveItems
        }
        .menuLabelIcons()
    }

    /// Leave / Delete, from the same policy the group-details inspector uses. A row knows only its
    /// membership, so `.leave` here is optimistic: `prepareChatLeave` resolves eligibility and
    /// reports a blocker if leaving turns out to be impossible.
    @ViewBuilder
    private var destructiveItems: some View {
        if let action = ChatDestructiveActions.action(for: chat) {
            Divider()

            switch action {
            case .leave:
                Button(role: .destructive) {
                    Task { await workspace.prepareChatLeave(for: chat) }
                } label: {
                    Label(
                        L10n.string("Leave Chat"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .disabled(workspace.leavingChatId != nil || workspace.preparingChatLeaveId != nil)

            case .deleteLocally:
                Button(role: .destructive) {
                    workspace.requestChatLocalDelete(for: chat)
                } label: {
                    Label(L10n.string("Delete From This Device"), systemImage: "trash.slash")
                }
                .disabled(workspace.isDeletingGroupLocally)
            }
        }
    }
}

struct SettingsListDrawerView: View {
    @Environment(WorkspaceState.self) private var workspace
    // Localizing through `\.locale` (not the stored preference) is what re-renders this
    // drawer when the language changes while settings are open — see `L10n.string(_:locale:)`.
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.string("Settings", locale: locale))
                    .wnFont(.semiBold18)

                SettingsAccountSwitcherCard()
            }
            .padding(.horizontal, 14)
            .padding(.top, MessagesLayout.sidebarTitlebarTopPadding)
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

}

struct SettingsSidebarRow: View {
    @Environment(WorkspaceState.self) private var workspace
    // The row's labels are the only language-dependent thing in its body, so reading the
    // locale here is what makes SwiftUI re-render it on a language switch.
    @Environment(\.locale) private var locale
    let page: SettingsPage

    private var isSelected: Bool {
        workspace.selection == .settings(page)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.systemImage)
                .wnFont(.semiBold16)
                .foregroundStyle(
                    isSelected
                        ? WNColor.backgroundContentPrimary : WNColor.backgroundContentSecondary
                )
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(page.title(in: locale))
                    .wnFont(.semiBold12)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                Text(page.sidebarSubtitle(in: locale))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
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

struct ChatRowContent: View {
    @Environment(\.locale) private var locale
    @Environment(\.timestampReferenceDate) private var timestampReferenceDate
    let chat: ChatItem
    let isSelected: Bool
    var isPinned = false
    var searchResult: GlobalMessageSearchResult?

    private var rowStatus: ChatRowStatus? { ChatRowStatus.status(for: chat) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProfileImageAvatarView(
                seed: chat.avatarSeed,
                initials: chat.title,
                sanitizedPictureURL: chat.sanitizedPictureURL,
                localImagePayload: chat.groupImagePayload,
                size: MessagesLayout.chatRowAvatarSize,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .wnFont(MessagesType.rowTitle)
                        .lineLimit(1)
                    // Precedence lives in `ChatRowStatus` so the badge and the row's
                    // destructive menu item are decided by one rule.
                    switch rowStatus {
                    case .leaving:
                        LeavingGroupBadge()
                    case .membershipEnded(let membership):
                        MembershipEndedBadge(membership: membership)
                    // A pending invite reports itself on the line below instead — the invite text
                    // where the last message would be, the `+` badge where the unread count would
                    // be. The two capsules above stay here because they report a settled state
                    // about the chat rather than something waiting on the reader.
                    case .pendingInvite, nil:
                        EmptyView()
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .accessibilityLabel(L10n.string("Pinned"))
                    }
                    if chat.muted {
                        Image(systemName: "bell.slash.fill")
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .accessibilityLabel(L10n.string("Muted"))
                    }
                    Spacer(minLength: 8)
                    ChatTimestampText(
                        chat: chat,
                        timelineAt: searchResult?.timelineAt,
                        referenceDate: timestampReferenceDate,
                        locale: locale
                    )
                    .equatable()
                    .wnFont(MessagesType.meta)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                HStack(alignment: .top, spacing: 4) {
                    previewText
                        .wnFont(MessagesType.preview)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if searchResult == nil {
                        ChatDeliveryStateIcon(state: chat.latestMessageDelivery)
                    }
                    // An unanswered invite takes this slot outright, the way the other clients
                    // read it: it is the one thing in the chat that is actually waiting on you,
                    // and a count beside it would offer messages the invite has not let you open.
                    if rowStatus == .pendingInvite {
                        PendingInviteBadge()
                    } else if chat.hasUnread {
                        // The three unread signals share `fillInfo` with `UnreadCountBadge`: a row
                        // can show the mention pill next to the count, and one of them in the
                        // neutral fill would read as a different kind of thing than the other.
                        if chat.hasMention {
                            Image(systemName: "at")
                                .wnFont(.bold10)
                                .foregroundStyle(WNColor.fillContentInfo)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(WNColor.fillInfo))
                                .help(L10n.string("You were mentioned"))
                        }
                        if chat.unreadCount > 0 {
                            UnreadCountBadge(count: chat.unreadCount, textStyle: MessagesType.badge)
                        } else {
                            Circle()
                                .fill(WNColor.fillInfo)
                                .frame(width: 9, height: 9)
                                .accessibilityLabel(L10n.string("Marked unread"))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            MessagesSidebarRowBackground(isSelected: isSelected)
        }
        .contentShape(Rectangle())
    }

    private var previewText: Text {
        // A search hit shows the matched message rather than the chat's last one, so the
        // last-message glyph would describe the wrong message.
        guard let searchResult else {
            // What an empty chat says here depends on why it is empty, and an unanswered invite
            // says so in words rather than in a badge beside the title.
            if let placeholder = chat.previewPlaceholder(locale: locale) {
                return Text(placeholder)
            }
            guard let kind = chat.previewAttachmentKind else { return Text(chat.preview) }
            // Inline in the same `Text` so the glyph wraps, truncates and picks up the row's
            // preview font and secondary style along with the words.
            return Text(Image(systemName: kind.systemImageName)) + Text(verbatim: " ") + Text(chat.preview)
        }
        // The emphasised runs name the Bold rung outright instead of taking `.bold()`: Manrope
        // ships as three separate faces, so asking for a bolder version of the row's Medium
        // would synthesize one rather than reach for the Bold already in the bundle.
        return Text(verbatim: "\(searchResult.senderName): ").wnFont(.bold12)
            + Text(searchResult.snippet.leading)
            + Text(searchResult.snippet.match).wnFont(.bold12)
            .foregroundColor(WNColor.intentionInfoContent)
            + Text(searchResult.snippet.trailing)
    }
}

/// The chat row at the drawer's narrowest width: the avatar, and the one badge that says
/// something is waiting on the reader.
///
/// This exists so the drawer never has to render a *truncated* row. Title, timestamp and
/// preview are dropped wholesale rather than clipped — a group name cut mid-word tells the
/// reader less than the avatar already does, and `ChatListWidthPolicy` snaps past the widths
/// where that would be the only option.
///
/// Everything the row stops showing in words it still says on hover: the title, and "Muted"
/// when the chat is, in the same `title — state` form the account rail uses.
struct CollapsedChatRowContent: View {
    let chat: ChatItem
    let isSelected: Bool

    private var rowStatus: ChatRowStatus? { ChatRowStatus.status(for: chat) }

    private var hoverDescription: String {
        chat.muted ? "\(chat.title) — \(L10n.string("Muted"))" : chat.title
    }

    var body: some View {
        ProfileImageAvatarView(
            seed: chat.avatarSeed,
            initials: chat.title,
            sanitizedPictureURL: chat.sanitizedPictureURL,
            localImagePayload: chat.groupImagePayload,
            size: MessagesLayout.chatRowAvatarSize,
            isSelected: false
        )
        .overlay(alignment: .topTrailing) {
            // Nudged onto the avatar's corner rather than centred over its face, the way the
            // account rail places its own badge. The row's padding leaves room for it, so
            // nothing is clipped.
            badge
                .offset(x: 3, y: -3)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background {
            MessagesSidebarRowBackground(isSelected: isSelected)
        }
        .contentShape(.rect)
        .help(hoverDescription)
        .accessibilityLabel(hoverDescription)
    }

    /// One badge, in the rail's single badge slot, so it has to be the most urgent claim on the
    /// reader rather than all of them: an unanswered invite, then a mention (which the bare count
    /// beside it would not distinguish from ordinary traffic), then the count, then the
    /// manually-marked-unread dot. The expanded row, which has the width for it, still shows the
    /// mention pill and the count together.
    @ViewBuilder
    private var badge: some View {
        if rowStatus == .pendingInvite {
            PendingInviteBadge()
        } else if chat.hasUnread {
            if chat.hasMention {
                Image(systemName: "at")
                    .wnFont(.bold10)
                    .foregroundStyle(WNColor.fillContentInfo)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(WNColor.fillInfo))
                    .accessibilityLabel(L10n.string("You were mentioned"))
            } else if chat.unreadCount > 0 {
                UnreadCountBadge(count: chat.unreadCount, textStyle: MessagesType.badge)
            } else {
                Circle()
                    .fill(WNColor.fillInfo)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel(L10n.string("Marked unread"))
            }
        }
    }
}

private struct ChatDeliveryStateIcon: View {
    let state: ChatMessageDeliveryState

    var body: some View {
        switch state {
        case .notApplicable:
            EmptyView()
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .help(L10n.string("Sending"))
        case .delivered:
            Image(systemName: "checkmark")
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .help(L10n.string("Delivered"))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(WNColor.intentionErrorContent)
                .help(L10n.string("Not delivered"))
        }
    }
}

/// Keeps date formatting out of ordinary chat-row render passes while still allowing
/// the label to change when the app's shared calendar-day reference advances.
private struct ChatTimestampText: View, Equatable {
    let chat: ChatItem
    let timelineAt: UInt64?
    let referenceDate: Date
    let locale: Locale

    var body: some View {
        if let timelineAt {
            Text(
                DisplayText.relativeTimestamp(
                    for: Date(timeIntervalSince1970: TimeInterval(timelineAt)),
                    now: referenceDate,
                    locale: locale
                )
            )
        } else {
            Text(chat.timestampLabel(at: referenceDate, locale: locale))
        }
    }
}

/// An invitation waiting on an answer, drawn in the row's unread slot as a `+` on the same
/// `fillInfo` disc the unread count and the mention pill use.
///
/// This is the other clients' `ChatStatusType.request`, and sharing the unread badge's shape is
/// the whole point of it: an invite and an unread message are the same kind of claim on the
/// reader — something in this chat is waiting — so they belong in the same slot, in the same fill,
/// distinguished only by the glyph. `+` reads as "join", which is the answer the row is asking
/// for. The neutral title-side capsule stays on `LeavingGroupBadge` and `MembershipEndedBadge`,
/// which report a settled state rather than ask for a decision.
///
/// Icon-only, so it carries both an accessibility label and a hover explanation; the row's
/// preview line says the same thing in words.
///
/// Both read "Invite pending" rather than "Group invite pending" or the bare "Invite":
/// `ChatRowStatus` never looks at `isDirect`, so this badge sits on direct invites too, and the
/// "Invite" key belongs to the group sheet's action button — translated as a verb ("Einladen",
/// "Invitar"), which is not what a status badge is saying.
struct PendingInviteBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .wnFont(.bold10)
            .foregroundStyle(WNColor.fillContentInfo)
            .frame(width: 18, height: 18)
            .background(Circle().fill(WNColor.fillInfo))
            .accessibilityLabel(L10n.string("Invite pending"))
            .help(L10n.string("Invite pending"))
    }
}

struct LeavingGroupBadge: View {
    var body: some View {
        Label(L10n.string("Leaving"), systemImage: "hourglass")
            .wnFont(.semiBold10)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(WNColor.fillContentTertiary)
            .background(WNColor.fillSecondary, in: Capsule())
            .overlay(Capsule().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
            .help(L10n.string("Leave request pending"))
    }
}

/// "Left" / "Removed" capsule on rows for groups the local account is no longer a
/// member of; the chat stays listed so the history remains readable.
struct MembershipEndedBadge: View {
    let membership: ChatSelfMembership

    var body: some View {
        Label(
            membership.sidebarBadgeLabel ?? "",
            systemImage: membership.endedSymbolName ?? ""
        )
        .wnFont(.semiBold10)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(WNColor.fillContentTertiary)
        .background(WNColor.fillSecondary, in: Capsule())
        .overlay(Capsule().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
        .help(membership.endedDescription ?? "")
    }
}
