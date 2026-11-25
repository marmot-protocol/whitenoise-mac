//
//  SidebarViews.swift
//  whitenoise-mac
//
//  Left-hand navigation: the chat-list sidebar, native search/filter controls,
//  global individual-message search mode, chat rows, and pending-invite badges.
//

import AppKit
import MarmotKit
import SwiftUI

/// The unread count, and the shape every other unread signal in the app borrows.
/// Digits are monospaced so a count ticking 9 → 10 does not shift the pill's width mid-scroll.
struct UnreadCountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(WNColor.fillContentPrimary)
            .padding(.horizontal, 5)
            .frame(minWidth: 19, minHeight: 19)
            .background(Capsule().fill(WNColor.fillPrimary))
    }
}

struct ChatListDrawerView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ChatListViewModel?
    let historyNotices: HistoryNoticesViewModel?
    let recoveryStatus: AccountRecoveryStatusViewModel?
    let selection: ChatListSelectionViewModel?
    let search: ChatListSearchViewModel?
    let globalSearch: SidebarGlobalSearchViewModel?
    let attentionModel: AccountAttentionViewModel?
    let deviceLinking: DeviceLinkingViewModel?
    let onOpenSettings: () -> Void
    let onOpenDevicesSettings: () -> Void
    let onOpenGlobalSearchResult: (GlobalMessageSearchResult, String) -> Void
    @State private var sidebarSearchFocusRequest: UUID?

    init(
        model: ChatListViewModel? = nil,
        historyNotices: HistoryNoticesViewModel? = nil,
        recoveryStatus: AccountRecoveryStatusViewModel? = nil,
        selection: ChatListSelectionViewModel? = nil,
        search: ChatListSearchViewModel? = nil,
        globalSearch: SidebarGlobalSearchViewModel? = nil,
        attentionModel: AccountAttentionViewModel? = nil,
        deviceLinking: DeviceLinkingViewModel? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onOpenDevicesSettings: @escaping () -> Void = {},
        onOpenGlobalSearchResult: @escaping (GlobalMessageSearchResult, String) -> Void = { _, _ in }
    ) {
        self.recoveryStatus = recoveryStatus
        self.model = model
        self.historyNotices = historyNotices
        self.selection = selection
        self.search = search
        self.globalSearch = globalSearch
        self.attentionModel = attentionModel
        self.deviceLinking = deviceLinking
        self.onOpenSettings = onOpenSettings
        self.onOpenDevicesSettings = onOpenDevicesSettings
        self.onOpenGlobalSearchResult = onOpenGlobalSearchResult
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            if let globalSearch, globalSearch.isActive {
                SidebarGlobalSearchView(
                    model: globalSearch,
                    onBack: { globalSearch.dismiss() },
                    onOpenResult: onOpenGlobalSearchResult
                )
            } else if workspace.isNewChatComposerVisible && workspace.composePane == .newChat {
                NewChatPanelView()
            } else {
                let filter = workspace.chatListFilter
                let isShowingArchived = filter == .archived
                let listing = visibleChats(for: filter)
                let visibleChats = listing.chats
                let showsBulkControls = SidebarSearchModeSelectionPolicy.showsBulkSelectionControls(
                    isSelectionActive: selection?.isActive == true,
                    isGlobalMessageSearchActive: globalSearch?.isActive == true
                )
                let activeSelection = showsBulkControls ? selection : nil

                SidebarProfileSwitcherView(
                    signedInAccounts: workspace.signedInAccounts,
                    activeAccount: workspace.activeAccount,
                    isAccountMutationInProgress: workspace.isAccountMutationInProgress,
                    attentionModel: attentionModel,
                    onSelectAccount: { workspace.selectAccount($0) },
                    onAddProfile: { workspace.showAccountOnboarding() },
                    onOpenSettings: onOpenSettings
                )

                MessagesSearchField(
                    text: $workspace.searchText,
                    accessibilityIdentifier: "chat.search",
                    placeholder: L10n.string("Search", locale: locale),
                    focusRequest: sidebarSearchFocusRequest
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

                if filter != .active {
                    HStack(spacing: 6) {
                        Label(filter.title, systemImage: filter.systemImage)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            workspace.chatListFilter = .active
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Clear", locale: locale))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }

                if let deviceLinking {
                    AccountDeviceWarningsBanner(
                        model: deviceLinking,
                        onOpenDevicesSettings: onOpenDevicesSettings
                    )
                }

                if let historyNotices {
                    AccountHistoryNoticesView(model: historyNotices)
                }

                if let recoveryStatus {
                    AccountCatchingUpRow(model: recoveryStatus)
                }

                if let activeSelection {
                    // Under the search field and beside the rows' checkmarks it acts on, rather
                    // than in place of the title row.
                    ChatListSelectAllRow(model: activeSelection)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }

                List(selection: openChatSelection(in: visibleChats)) {
                    ForEach(visibleChats) { chat in
                        ChatSidebarRow(
                            chat: chat,
                            isArchived: listing.archivedIds.contains(chat.id),
                            searchResult: workspace.sidebarMessageSearchResult(for: chat),
                            selection: showsBulkControls ? selection : nil
                        )
                        .tag(chat.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                        .listRowSeparator(.hidden)
                        .onAppear {
                            if isSearching {
                                search?.setVisibleAnchor(groupIdHex: chat.id)
                                if chat.id == visibleChats.last?.id { search?.pageForward() }
                                if chat.id == visibleChats.first?.id { search?.pageBackward() }
                                return
                            }
                            guard filter == .active else { return }
                            model?.setVisibleWindowAnchor(groupIdHex: chat.id)
                            if chat.id == visibleChats.last?.id {
                                Task { await model?.pageWindow(.forward) }
                            }
                            if chat.id == visibleChats.first?.id {
                                Task { await model?.pageWindow(.backward) }
                            }
                        }
                    }

                    if isSearching, search?.isTruncated == true, search?.hasMoreRows == false {
                        ChatListSearchTruncatedNote()
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                    }
                }
                .listStyle(.sidebar)
                .textSelection(.disabled)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        ChatListFilterMenu()
                    }
                    ToolbarItem(placement: .automatic) {
                        Button(action: openGlobalMessageSearch) {
                            Label(
                                L10n.string("Search all messages", locale: locale),
                                systemImage: "text.magnifyingglass"
                            )
                        }
                        .help(L10n.string("Search all messages", locale: locale))
                        .accessibilityIdentifier("chat.search.global")
                    }
                    if !isShowingArchived {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                workspace.showNewChat()
                            } label: {
                                Label(L10n.string("New chat", locale: locale), systemImage: "square.and.pencil")
                            }
                            .help(L10n.string("New chat", locale: locale))
                        }
                    }
                }
                .accessibilityIdentifier(isShowingArchived ? "chat.archived.list" : "chat.list")
                .overlay {
                    if visibleChats.isEmpty {
                        if isSearching, search?.phase != .ready, search?.phase != .failed {
                            ProgressView()
                                .controlSize(.small)
                        } else if isSearching, search?.phase == .failed {
                            ChatListSearchFailedState {
                                // The search key has not changed, so `.onChange` will not rerun it;
                                // a failed search reruns the same text when asked again.
                                search?.search(
                                    workspace.searchText,
                                    view: filter.chatListView,
                                    condition: filter.chatListCondition
                                )
                            }
                            .padding()
                        } else if isSearching {
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
                            case .invites:
                                InvitesEmptyDrawerState()
                            case .left:
                                LeftEmptyDrawerState()
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
                .onChange(of: workspace.searchText) { _, _ in
                    // MDK's search (`ChatListSearchViewModel`) decides which chats match and owns
                    // the progress shown in the list. This legacy search only supplies each
                    // row's message snippet (`sidebarMessageSearchResult(for:)`), so it shows no
                    // spinner of its own; a second one would duplicate the list's.
                    workspace.scheduleSidebarMessageSearch()
                }
                .onChange(
                    of: ChatListSearchKey(
                        text: workspace.searchText,
                        view: filter.chatListView,
                        condition: filter.chatListCondition
                    ),
                    initial: true
                ) { _, key in
                    search?.search(key.text, view: key.view, condition: key.condition)
                }
                .onChange(
                    of: ChatListSelectionScope(
                        query: isSearching
                            ? search?.matchesQuery ?? filter.unfilteredQuery
                            : filter.unfilteredQuery,
                        // Every tab reads Select All's universe from MDK. The inbox and search
                        // results are bounded windows, and the other tabs are drawn by host
                        // predicates that do not match MDK's views (MDK files a chat that is both
                        // archived and left under Left only; the Archived tab lists it too). The
                        // batch revalidates against MDK's view, so counting the host's rows would
                        // promise chats it then silently drops.
                        isWindowed: true,
                        visibleIds: visibleChats.map(\.id)
                    ),
                    initial: true
                ) { _, scope in
                    selection?.updateVisibleChats(scope.visibleIds, query: scope.query, isWindowed: scope.isWindowed)
                }

                if let activeSelection {
                    Divider()
                    let visibleById = Dictionary(
                        visibleChats.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    ChatListSelectionBar(
                        model: activeSelection,
                        chat: { [model, nicknames = workspace.activeContactNicknames] id in
                            visibleById[id] ?? model?.chatItem(groupIdHex: id, nicknames: nicknames)
                        },
                        archivedIds: listing.archivedIds
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .focusedSceneValue(
            \.sidebarSearchFocus,
            SidebarSearchFocus {
                if let globalSearch, globalSearch.isActive {
                    globalSearch.activate()
                } else {
                    sidebarSearchFocusRequest = UUID()
                }
            }
        )
        .animation(reduceMotion ? .none : .smooth(duration: 0.18), value: selection?.isActive == true)
        .onChange(of: showsSelectableList) { _, shows in
            // Selection belongs to the list on screen: settings, the composer or the collapsed rail
            // replacing it ends selection mode rather than leaving it armed out of sight.
            if !shows { selection?.end() }
        }
        // Hiding the chat list unmounts this drawer, so the `onChange` above never sees it go.
        // Selection would stay armed with no Done button on screen, and the conversation toolbar
        // leaves Escape to that missing button.
        .onDisappear { selection?.end() }
        .onChange(of: workspace.isNewChatComposerVisible) { _, isVisible in
            if isVisible {
                globalSearch?.dismiss()
            }
        }
        .modifier(ChatListSelectionDialogs(model: selection))
    }

    private func openGlobalMessageSearch() {
        globalSearch?.activate(initialQuery: workspace.searchText)
    }

    private var showsSelectableList: Bool {
        !workspace.isNewChatComposerVisible && workspace.isChatListVisible
    }

    private func openChatSelection(in visibleChats: [ChatItem]) -> Binding<String?> {
        Binding(
            get: {
                if case .chat(let id) = workspace.selection { return id }
                return nil
            },
            set: { newId in
                let currentOpenId: String? =
                    if case .chat(let id) = workspace.selection { id } else { nil }
                guard
                    ChatListRowClickPolicy.shouldApplyNativeListSelection(
                        newId: newId,
                        currentOpenChatId: currentOpenId,
                        isBatchSelectionActive: selection?.isActive == true,
                        modifiers: NSEvent.modifierFlags
                    ),
                    let newId,
                    let chat = visibleChats.first(where: { $0.id == newId })
                else { return }
                workspace.selectChat(chat)
            }
        )
    }
}

extension ChatListDrawerView {
    private var isSearching: Bool {
        !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The drawer's rows, and which of them are archived. `ChatItem` carries no archive flag, and
    /// the drawer's filter is not one either: the Left drawer lists archived chats beside active
    /// ones, and an archived row there must offer Unarchive rather than Pin — mdk refuses to pin
    /// an archived chat.
    fileprivate func visibleChats(for filter: ChatListFilter) -> (chats: [ChatItem], archivedIds: Set<String>) {
        if isSearching {
            // MDK matched these (`ChatListSearchViewModel`); until it answers nothing is shown.
            let rows = search?.rows ?? []
            let chats =
                model?.chatItems(
                    for: rows,
                    nicknames: workspace.activeContactNicknames,
                    mentionNames: workspace.cachedMentionNames(groupIdHex:)
                ) ?? []
            return (chats, Set(rows.filter(\.row.archived).map(\.row.groupIdHex)))
        }
        let chats: [ChatItem]
        let activeChats =
            model?.chats(
                view: .chats,
                nicknames: workspace.activeContactNicknames,
                mentionNames: workspace.cachedMentionNames(groupIdHex:)
            )
            ?? workspace.activeChats
        let archivedChats =
            model?.chats(
                view: .archived,
                nicknames: workspace.activeContactNicknames,
                mentionNames: workspace.cachedMentionNames(groupIdHex:)
            )
            ?? workspace.archivedChats
        switch filter {
        case .active:
            chats = activeChats.filter { !$0.belongsToLeft }
        case .unread:
            chats =
                model?.chats(
                    view: .unread,
                    nicknames: workspace.activeContactNicknames,
                    mentionNames: workspace.cachedMentionNames(groupIdHex:)
                )
                ?? activeChats.filter { $0.hasUnread && !$0.belongsToLeft }
        case .invites:
            chats =
                model?.pendingInvites(
                    nicknames: workspace.activeContactNicknames,
                    mentionNames: workspace.cachedMentionNames(groupIdHex:)
                )
                ?? activeChats.filter { $0.pendingConfirmation && !$0.belongsToLeft }
        case .archived:
            // A chat that is archived and left is filed under Left only, as in MDK's views.
            chats = archivedChats.filter { !$0.belongsToLeft }
        case .left:
            chats =
                model?.chats(
                    view: .left,
                    nicknames: workspace.activeContactNicknames,
                    mentionNames: workspace.cachedMentionNames(groupIdHex:)
                )
                ?? (activeChats + archivedChats).filter(\.belongsToLeft)
        }
        let archivedIds: Set<String>
        switch filter {
        case .archived, .left:
            archivedIds = model?.archivedGroupIds ?? Set(archivedChats.map(\.id))
        case .active, .unread, .invites:
            archivedIds = []
        }
        return (chats, archivedIds)
    }
}

/// Native menu Picker exposing the five real chat-list filters: Chats, Unread, Invites, Archived,
/// and Left chats (N08, C07, #1037).
private struct ChatListFilterMenu: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var workspace = workspace

        Menu {
            Picker(L10n.string("Filter chats", locale: locale), selection: $workspace.chatListFilter) {
                ForEach(ChatListFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                L10n.string("Filter chats", locale: locale),
                systemImage: workspace.chatListFilter == .active
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .menuIndicator(.hidden)
        .help(L10n.string("Filter chats", locale: locale))
        .accessibilityLabel(L10n.string("Filter chats", locale: locale))
        .accessibilityIdentifier("chat.list.filter")
    }
}

private struct ArchivedEmptyDrawerState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(title: L10n.string("No archived chats", locale: locale), systemImage: "archivebox")
            .padding()
    }
}

private struct InvitesEmptyDrawerState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(title: L10n.string("No pending invites", locale: locale), systemImage: "envelope")
            .padding()
    }
}

#Preview("No pending invites") {
    InvitesEmptyDrawerState()
        .frame(width: 320, height: 240)
}

private struct UnreadEmptyDrawerState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(title: L10n.string("No unread chats", locale: locale), systemImage: "bubble.left")
            .padding()
    }
}

private struct LeftEmptyDrawerState: View {
    @Environment(\.locale) private var locale

    var body: some View {
        WNEmptyStateView(
            title: L10n.string("No chats", locale: locale),
            systemImage: "rectangle.portrait.and.arrow.right"
        )
        .padding()
    }
}

private struct ChatSidebarRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem
    let isArchived: Bool
    let searchResult: GlobalMessageSearchResult?
    /// `nil` where selection is unavailable (the collapsed rail). The row reads only `isActive`;
    /// the checkmark observes the selected set on its own.
    let selection: ChatListSelectionViewModel?

    var body: some View {
        let isSelecting = selection?.isActive == true

        Button {
            click()
        } label: {
            HStack(spacing: 6) {
                if isSelecting, let selection {
                    ChatListSelectionIndicator(model: selection, groupIdHex: chat.id)
                        .padding(.leading, 4)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ChatSidebarRowContent(
                    chat: chat,
                    isArchived: isArchived,
                    searchResult: searchResult
                )
            }
            // A plain-style button exposes none of its label's text on its own, so without this the
            // row reached Accessibility as an unnamed "button": name, preview and time are read as one.
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isArchived ? "chat.archived.row.\(chat.id)" : "chat.row.\(chat.id)")
        .contextMenu {
            // A row's own actions would act on one chat while several are selected; the bar
            // is where a selection is acted on.
            if !isSelecting {
                ChatSidebarRowMenuItems(chat: chat, isArchived: isArchived, selection: selection)
            }
        }
    }

    /// A plain click opens the chat; in selection mode it toggles it instead. ⌘-click starts a
    /// selection from this row, and ⇧-click selects the range from the open chat (or the last
    /// clicked row) to this one — the Finder and Mail conventions.
    private func click() {
        if let selection {
            switch ChatListRowClickPolicy.action(
                modifiers: NSEvent.modifierFlags,
                isBatchSelectionActive: selection.isActive,
                openChatId: openChatId
            ) {
            case .extendSelection(let defaultAnchor):
                selection.extend(to: chat.id, defaultAnchor: defaultAnchor)
                return
            case .toggleSelection:
                selection.toggle(chat.id)
                return
            case .beginSelection:
                selection.begin(with: chat.id)
                return
            case .openChat:
                break
            }
        }
        workspace.selectChat(chat)
    }

    private var openChatId: String? {
        if case .chat(let id) = workspace.selection { return id }
        return nil
    }
}

private struct ChatSidebarRowContent: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem
    let isArchived: Bool
    let searchResult: GlobalMessageSearchResult?

    var body: some View {
        ChatRowContent(
            chat: chat,
            isPinned: !isArchived && workspace.isChatPinned(chat),
            searchResult: searchResult
        )
    }
}

private struct ChatSidebarRowMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.endingGroupIds) private var endingGroupIds
    @Environment(\.locale) private var locale
    let chat: ChatItem
    let isArchived: Bool
    let selection: ChatListSelectionViewModel?

    private var actions: ChatMenuActions { ChatMenuActions(workspace: workspace, chat: chat) }

    var body: some View {
        Group {
            if let selection {
                Button {
                    selection.begin(with: chat.id)
                } label: {
                    ChatRowMenuLabel(action: .select)
                }
                .disabled(selection.isBusy)

                Divider()
            }

            Button {
                Task {
                    await workspace.setChatManuallyUnread(
                        chat,
                        manuallyUnread: !chat.manuallyMarkedUnread
                    )
                }
            } label: {
                ChatRowMenuLabel(action: chat.manuallyMarkedUnread ? .clearUnread : .markUnread)
            }
            .disabled(workspace.isMutatingChatPreferences(chat))

            ChatMuteMenu(actions: actions, locale: locale, showsRowIcon: true, isCurrent: { true })

            Divider()

            if isArchived {
                Button {
                    Task { await actions.setArchived(false) }
                } label: {
                    ChatRowMenuLabel(action: .unarchive)
                }
                .disabled(!actions.canArchive)
            } else {
                let isPinned = workspace.isChatPinned(chat)
                Button {
                    Task { await workspace.setChatPinned(chat, pinned: !isPinned) }
                } label: {
                    ChatRowMenuLabel(action: isPinned ? .unpin : .pin)
                }
                .disabled(workspace.isMutatingChatPreferences(chat))

                Divider()

                Button {
                    Task { await actions.setArchived(true) }
                } label: {
                    ChatRowMenuLabel(action: .archive)
                }
                .disabled(!actions.canArchive)
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

            Button(role: .destructive) {
                switch action {
                case .deleteLocally:
                    actions.requestDeleteLocally(endingGroupIDs: endingGroupIds)
                case .leave:
                    let originAccountId = workspace.activeAccountId
                    Task {
                        guard workspace.activeAccountId == originAccountId else { return }
                        await actions.requestLeave(endingGroupIDs: endingGroupIds)
                    }
                }
            } label: {
                ChatRowMenuLabel(action: action == .leave ? .leave : .deleteLocally)
            }
            .disabled(!actions.canPerformDestructive(action, endingGroupIDs: endingGroupIds))
        }
    }
}

struct ChatRowContent: View {
    @Environment(\.locale) private var locale
    @Environment(\.timestampReferenceDate) private var timestampReferenceDate
    let chat: ChatItem
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

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // Precedence lives in `ChatRowStatus` so the badge and the row's
                    // destructive menu item are decided by one rule.
                    switch rowStatus {
                    case .groupLifecycle(let lifecycle) where lifecycle.sidebarBadgeLabel != nil:
                        GroupLifecycleBadge(lifecycle: lifecycle)
                    case .leaving:
                        LeavingGroupBadge()
                    // Settled endings — left, removed, group ended — report themselves on the line
                    // below instead, in the words the chat's own system message and composer notice
                    // use (`ChatItem.previewNotice(locale:)`). A pending invite does too: the invite
                    // text where the last message would be, the `+` badge where the unread count
                    // would be. Only the in-flight states keep a capsule beside the title.
                    case .groupLifecycle, .membershipEnded, .pendingInvite, nil:
                        EmptyView()
                    }
                    if chat.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.string("Muted"))
                    }
                    Spacer(minLength: 6)
                    ChatTimestampText(
                        chat: chat,
                        timelineAt: searchResult?.timelineAt,
                        referenceDate: timestampReferenceDate,
                        locale: locale
                    )
                    .equatable()
                    // Monospaced digits so the row's trailing edge stays steady as the clock ticks.
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 4) {
                    previewText
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(WNColor.fillContentPrimary)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(WNColor.fillPrimary))
                                .help(L10n.string("You were mentioned"))
                        }
                        if chat.unreadCount > 0 {
                            UnreadCountBadge(count: chat.unreadCount)
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
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var previewText: Text {
        // A search hit shows the matched message rather than the chat's last one, so the
        // last-message glyph would describe the wrong message.
        guard let searchResult else {
            // What an empty chat says here depends on why it is empty, and an unanswered invite
            // says so in words rather than in a badge beside the title — as do a left or removed
            // membership and an ended group, which take this line even when the chat has messages
            // behind it.
            if let notice = chat.previewNotice(locale: locale) {
                return Text(notice)
            }
            return Self.attributedPreview(for: chat)
        }
        return Text(verbatim: "\(searchResult.senderName): ").font(.callout.weight(.semibold))
            + SearchMatchHighlightStyle.text(searchResult.snippet)
    }

    /// Recovers the sender prefix from the composed preview line rather than rebuilding it from
    /// `publishedSenderName`, because a user's private contact nickname may have been patched into
    /// the preview. A line of your own ("You: …") carries no attribution and stays one plain run.
    private static func attributedPreview(for chat: ChatItem) -> Text {
        let glyph: Text =
            chat.previewAttachmentKind.map { kind in
                Text(Image(systemName: kind.systemImageName)) + Text(verbatim: " ")
            } ?? Text(verbatim: "")

        guard let parts = chat.previewAttributionParts else {
            return glyph + Text(chat.preview)
        }
        return Text(verbatim: parts.senderName).font(.callout.weight(.semibold))
            + Text(verbatim: ": ")
            + glyph
            + Text(parts.body)
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
/// for. The neutral title-side capsule stays on `LeavingGroupBadge` and `GroupLifecycleBadge`,
/// which report a state in progress rather than ask for a decision.
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
            .font(.caption2.weight(.bold))
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
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(WNColor.fillContentTertiary)
            .background(WNColor.fillSecondary, in: Capsule())
            .overlay(Capsule().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
            .help(L10n.string("Leave request pending"))
    }
}

/// What a search runs on: the typed text and the drawer's view, with the tab's condition.
private struct ChatListSearchKey: Equatable {
    let text: String
    let view: ChatListViewFfi
    let condition: ChatListConditionFfi?
}

/// Under search results capped at MDK's 500-id window: the rest exist but are not listed.
/// A chat search MDK could not finish. Typing again reruns it, but nothing else would: the text
/// it failed on is still the text in the field.
private struct ChatListSearchFailedState: View {
    @Environment(\.locale) private var locale
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("Search couldn't be completed.", locale: locale),
                systemImage: "magnifyingglass"
            )
        } actions: {
            Button(L10n.string("Try Again", locale: locale), action: retry)
                .wnSecondaryButtonStyle()
                .controlSize(.small)
                .accessibilityIdentifier("chat.search.retry")
        }
        .controlSize(.small)
    }
}

#Preview("ChatListSearchFailedState") {
    ChatListSearchFailedState {}
        .frame(width: 280)
}

private struct ChatListSearchTruncatedNote: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Text(
            L10n.string(
                "Showing the first 500 matches. Refine your search to see the rest.",
                locale: locale
            )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("chat.search.truncated")
    }
}

#Preview("ChatListSearchTruncatedNote") {
    ChatListSearchTruncatedNote()
        .frame(width: 280)
}

#Preview("ChatSidebarRowContent") {
    ChatSidebarRowContent(chat: ChatItem.samples[0], isArchived: false, searchResult: nil)
        .padding()
        .frame(width: 320)
        .environment(WorkspaceState.preview())
}
