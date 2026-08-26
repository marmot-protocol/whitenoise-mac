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

/// The unread count, and the shape every other unread signal in the app borrows.
///
/// `fillPrimary` + `fillContentPrimary`: near-black with a white count in Aqua, white with a
/// near-black count in Dark Aqua. This used to be a blue pill (`fillInfo`, a token that existed
/// for it alone and is gone with it), on the argument that `fillPrimary` is already the sent
/// bubble and the send button, so a badge wearing it would read as chrome. The iOS prototype and
/// the Flutter client both settle it the other way: one inverted accent for everything the app
/// wants you to act on, and blue reserved for text that behaves like a link. A badge drawn in it
/// is not competing with the selected row, which is `fillTertiaryHover`.
///
/// Digits are monospaced so a count ticking 9 → 10 does not shift the pill's width mid-scroll.
struct UnreadCountBadge: View {
    let count: Int
    var textStyle: WNTextStyle = .bold10

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .wnFont(textStyle.monospacedDigit())
            .foregroundStyle(WNColor.fillContentPrimary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(WNColor.fillPrimary))
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
                    ForEach(workspace.signedInAccounts) { account in
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
        .sidebarTitlebarClearance()
        .padding(.bottom, 14)
        .frame(width: MessagesLayout.accountRailWidth)
        .background {
            MessagesSidebarBackground(level: .rail)
        }
    }
}

/// A single account avatar in the rail: selects that identity on tap, and overlays an
/// unread badge. Nothing else — the rail switches accounts and does not manage them.
///
/// Deliberately has no context menu, and no signed-out case. It used to offer Sign In /
/// Sign Out on right-click, where Sign Out fired `signOutAccount` with no prompt at all,
/// so an accidental click dropped that identity's relay key packages. It also used to
/// draw deactivated identities, dimmed to 0.4 behind a pause glyph, where one tap signed
/// one back in. Every one of those is account management, and all of it lives in Settings'
/// switcher now (`SettingsAccountSwitcherCard`): sign-out and removal behind confirmations,
/// sign-in on the row itself.
///
/// The rail is fed `signedInAccounts`, so `account.signedOut` is false here by
/// construction. Reintroducing a branch on it would be dead code describing a row that
/// cannot reach this view.
private struct AccountRailAvatar: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem

    private var unread: Int { workspace.unreadCount(forAccountIdHex: account.accountIdHex) }
    private var isActive: Bool { account.id == workspace.activeAccountId }

    var body: some View {
        Button {
            workspace.selectAccount(account)
        } label: {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: account.initials,
                sanitizedPictureURL: account.sanitizedPictureURL,
                // These are the viewer's *own* identities, so the rail sits with the profile
                // editor and the account switcher on the exempt side of the "Load Remote Profile
                // Images" preference — see `RemoteImageDisplayPolicy`. Left on the default, the
                // rail drew initials for a picture the viewer had just set and could see in
                // Settings, which reads as a broken avatar rather than as privacy. Unconditional
                // because every row here is signed in; the switcher's list still gates its
                // deactivated rows, since signing out drops an identity's relay key packages and
                // the app should not then put traffic on the wire on its behalf.
                isOwnAccountImage: true,
                size: MessagesLayout.accountRailAvatarSize,
                isSelected: isActive
            )
            .frame(width: MessagesLayout.accountRailAvatarFrameSize, height: MessagesLayout.accountRailAvatarFrameSize)
            .contentShape(Circle())
            .overlay(alignment: .topTrailing) {
                // A `badge` view builder used to stand here to choose between this and the
                // signed-out pause glyph. With one case left there is nothing to choose.
                if unread > 0 {
                    UnreadCountBadge(count: unread)
                        .overlay(Capsule().strokeBorder(WNColor.backgroundTertiary, lineWidth: 1.5))
                }
            }
        }
        .buttonStyle(.plain)
        .help(account.displayName)
    }
}

struct ChatListDrawerView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale

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
                    // The notice needs room for an icon over a line or two of prose; in the
                    // collapsed rail it would render as a column of hyphenated fragments. An
                    // empty rail is legible on its own, and widening it brings the wording back.
                    if visibleChats.isEmpty, !isCollapsed {
                        if workspace.isSearchingSidebarMessages {
                            ProgressView()
                                .controlSize(.small)
                        } else if !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            WNEmptyStateView(
                                title: L10n.string("No matching chats", locale: locale),
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
                                // An account with no chats at all is told so by the detail
                                // pane, which has room for the invitation to start one and
                                // nothing else to say. Repeating it here left the window
                                // holding two notices about the same nothing. When the
                                // active drawer is empty only because everything is
                                // archived, the detail pane is back to "Select a chat" and
                                // this rail is the only place that fact can be stated.
                                if !workspace.hasNoChats {
                                    EmptyDrawerState()
                                }
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
        .sidebarTitlebarClearance()
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
        .sidebarTitlebarClearance()
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
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(title: L10n.string("No archived chats", locale: locale), systemImage: "archivebox")
            .padding()
    }
}

private struct UnreadEmptyDrawerState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(title: L10n.string("No unread chats", locale: locale), systemImage: "bubble.left")
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
                    isSelected: workspace.selection == .chat(chat.id),
                    isPinned: !isArchived && workspace.isChatPinned(chat)
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
                .disabled(
                    workspace.leavingChatId != nil
                        || workspace.preparingChatLeaveId != nil
                        || workspace.handingOffAdminChatId != nil)

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
            Text(L10n.string("Settings", locale: locale))
                .wnFont(.semiBold18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .sidebarTitlebarClearance()
                .padding(.bottom, 10)

            // No rule under the title. The account card used to be pinned above a
            // `GlassSeparator`, which split the surface into a header and a list; the prototype's
            // hub has the profile as the *first card of the same grouped list*, so it scrolls with
            // the destinations and the only grouping signal is the gap between cards.
            ScrollView {
                // One card per group, then the isolated destructive row — the shape
                // `wn-ios-prototype`'s hub takes. The gap between cards is the only grouping
                // signal, because the prototype's hub carries no category headings.
                LazyVStack(spacing: 12) {
                    SettingsAccountSwitcherCard()

                    ForEach(Array(SettingsPage.sidebarGroups.enumerated()), id: \.offset) { _, group in
                        SettingsSidebarGroupCard {
                            ForEach(Array(group.enumerated()), id: \.element) { index, page in
                                Button {
                                    workspace.showSettingsPage(page)
                                } label: {
                                    SettingsSidebarRow(page: page)
                                }
                                .buttonStyle(.plain)

                                if index < group.count - 1 {
                                    SettingsSidebarRowSeparator()
                                }
                            }
                        }
                    }

                    SettingsSignOutRow()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }

            // The line that closes the settings surface. It sits under the page list rather than
            // on a page, because it is about the app and not about any one group of settings.
            SettingsVersionFooter()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .background {
            MessagesSidebarBackground(level: .settingsDrawer)
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
        // Glyph and title, nothing else: the prototype's hub states outright that it carries no
        // explanatory subtitles, and a second line under every row is what stopped the ten rows
        // from reading as a list you could scan.
        HStack(spacing: SettingsSidebarRowMetrics.glyphSpacing) {
            Image(systemName: page.systemImage)
                .wnFont(.medium14)
                .foregroundStyle(
                    isSelected
                        ? WNColor.backgroundContentPrimary : WNColor.backgroundContentSecondary
                )
                .frame(width: SettingsSidebarRowMetrics.glyphWidth)

            Text(page.title(in: locale))
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, SettingsSidebarRowMetrics.verticalPadding)
        .padding(.horizontal, SettingsSidebarRowMetrics.horizontalPadding)
        .background {
            SettingsSidebarRowBackground(isSelected: isSelected)
        }
        .contentShape(Rectangle())
    }
}

/// The drawer's last row: sign out of the active account, on its own away from the
/// destinations above it.
///
/// Isolated by the same argument the prototype's hub makes — a row that ends a session does not
/// belong in a card of rows that open a page. It was previously reachable only from inside the
/// switcher popover, where you had to open a list of identities to act on the one already active.
struct SettingsSignOutRow: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    @State private var isConfirming = false

    var body: some View {
        if let account = workspace.activeAccount {
            SettingsSidebarGroupCard {
                Button {
                    isConfirming = true
                } label: {
                    HStack(spacing: SettingsSidebarRowMetrics.glyphSpacing) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .wnFont(.medium14)
                            .foregroundStyle(WNColor.backgroundContentDestructive)
                            .frame(width: SettingsSidebarRowMetrics.glyphWidth)

                        Text(L10n.string("Sign Out", locale: locale))
                            .wnFont(.medium14)
                            .foregroundStyle(WNColor.backgroundContentDestructive)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, SettingsSidebarRowMetrics.verticalPadding)
                    .padding(.horizontal, SettingsSidebarRowMetrics.horizontalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(workspace.isAccountMutationInProgress)
            }
            .signOutConfirmation(account: account, isPresented: $isConfirming) {
                Task { await workspace.signOutAccount(account) }
            }
        }
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
            .overlay(alignment: .bottomTrailing) {
                if isPinned {
                    ChatAvatarPinBadge()
                }
            }

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
                    case .membershipEnded(let membership)
                    where !membership.reportsInChatRowPreviewLine:
                        MembershipEndedBadge(membership: membership)
                    // A pending invite reports itself on the line below instead — the invite text
                    // where the last message would be, the `+` badge where the unread count would
                    // be. The two capsules above stay here because they report a settled state
                    // about the chat rather than something waiting on the reader. A removal is the
                    // one settled state that goes to the line below too, in the chat's own words.
                    case .membershipEnded, .pendingInvite, nil:
                        EmptyView()
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
                    // Monospaced digits, as the prototype sets this label: the timestamp is the
                    // row's right edge, and proportional digits move that edge as the clock ticks.
                    .wnFont(MessagesType.meta.monospacedDigit())
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                HStack(alignment: .top, spacing: 4) {
                    previewText
                        .wnFont(MessagesType.preview)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The marker describes the message on this line, so it only appears when the
                    // line is actually showing one — not beside a removal notice or a placeholder.
                    if searchResult == nil, chat.previewNotice(locale: locale) == nil {
                        ChatDeliveryStateIcon(state: chat.latestMessageDelivery)
                    }
                    // An unanswered invite takes this slot outright, the way the other clients
                    // read it: it is the one thing in the chat that is actually waiting on you,
                    // and a count beside it would offer messages the invite has not let you open.
                    if rowStatus == .pendingInvite {
                        PendingInviteBadge()
                    } else if chat.hasUnread {
                        // The three unread signals share `fillPrimary` with `UnreadCountBadge`: a
                        // row can show the mention pill next to the count, and one of them in a
                        // different fill would read as a different kind of thing than the other.
                        if chat.hasMention {
                            Image(systemName: "at")
                                .wnFont(.bold10)
                                .foregroundStyle(WNColor.fillContentPrimary)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(WNColor.fillPrimary))
                                .help(L10n.string("You were mentioned"))
                        }
                        if chat.unreadCount > 0 {
                            UnreadCountBadge(count: chat.unreadCount, textStyle: MessagesType.badge)
                        } else {
                            Circle()
                                .fill(WNColor.fillPrimary)
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
            // says so in words rather than in a badge beside the title — as does a removal, which
            // takes this line even when the chat has messages behind it.
            if let notice = chat.previewNotice(locale: locale) {
                return Text(notice)
            }
            return Self.attributedPreview(for: chat)
        }
        // The emphasised runs name the Bold rung outright instead of taking `.bold()`: a rung
        // carries its own weight, and `.bold()` on top of one is a weight the ladder no
        // longer controls.
        return Text(verbatim: "\(searchResult.senderName): ").wnFont(.bold12)
            + Text(searchResult.snippet.leading)
            + Text(searchResult.snippet.match).wnFont(.bold12)
            .foregroundColor(WNColor.intentionInfoContent)
            + Text(searchResult.snippet.trailing)
    }

    /// The last-message line with the sender it is attributed to set in Bold, the way the
    /// prototype's row draws it: **Maya** then what Maya said, so a group's traffic can be scanned
    /// by who is talking without reading the messages.
    ///
    /// The prefix is recovered from the composed line rather than rebuilt from
    /// `previewAttribution.publishedSenderName`, because the name on display may be a private
    /// nickname that `relabelingPreviewSender` patched in — see `ChatItem.previewAttributionParts`.
    ///
    /// An attachment glyph belongs to the message, not to the attribution, so it follows the name
    /// rather than leading the line. Everything stays inside one `Text` so the whole line wraps,
    /// truncates and inherits the row's preview font and secondary style.
    ///
    /// A line of your own ("You: …") carries no attribution and so stays one plain run. That is the
    /// right reading rather than a gap: the Bold run marks *who else* is talking, which is what a
    /// group is scanned for, and "You" is never the answer to that question.
    private static func attributedPreview(for chat: ChatItem) -> Text {
        let glyph: Text =
            chat.previewAttachmentKind.map { kind in
                Text(Image(systemName: kind.systemImageName)) + Text(verbatim: " ")
            } ?? Text(verbatim: "")

        guard let parts = chat.previewAttributionParts else {
            return glyph + Text(chat.preview)
        }
        // The Bold rung is named outright rather than taken with `.bold()`: a rung carries its
        // own weight, and `.bold()` on top of one is a weight the ladder no longer controls.
        return Text(verbatim: parts.senderName).wnFont(.bold12)
            + Text(verbatim: ": ")
            + glyph
            + Text(parts.body)
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
    var isPinned = false

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
        // The other corner, so the pin never contends with the badge slot above. Moving the pin
        // onto the avatar is what lets the collapsed row keep it at all — there is no title line
        // here to put it beside.
        .overlay(alignment: .bottomTrailing) {
            if isPinned {
                ChatAvatarPinBadge()
            }
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
                    .foregroundStyle(WNColor.fillContentPrimary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(WNColor.fillPrimary))
                    .accessibilityLabel(L10n.string("You were mentioned"))
            } else if chat.unreadCount > 0 {
                UnreadCountBadge(count: chat.unreadCount, textStyle: MessagesType.badge)
            } else {
                Circle()
                    .fill(WNColor.fillPrimary)
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
/// `fillPrimary` disc the unread count and the mention pill use.
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
            .foregroundStyle(WNColor.fillContentPrimary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(WNColor.fillPrimary))
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

/// "Left" capsule on rows for groups the local account walked out of; the chat stays listed so
/// the history remains readable.
///
/// It renders any ended membership it is handed — the label, symbol and tooltip all come from
/// `ChatSelfMembership` — but the sidebar row only hands it the memberships that
/// `reportsInChatRowPreviewLine` leaves to a capsule. A removal takes the preview line instead.
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
