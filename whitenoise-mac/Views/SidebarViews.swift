//
//  SidebarViews.swift
//  whitenoise-mac
//
//  Left-hand navigation: the account rail, chat-list and settings-list
//  drawers, their rows, and the pending-invite badge. Extracted verbatim
//  from MessengerShellView.swift (no behavior change).
//

import AppKit
import SwiftUI

private func unreadBadgeLabel(for count: Int) -> String {
    count > 99 ? "99+" : "\(count)"
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
                size: 42,
                isSelected: isActive
            )
            .frame(width: 54, height: 54)
            .contentShape(Circle())
            .opacity(account.signedOut ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                badge
            }
        }
        .buttonStyle(.plain)
        .help(account.signedOut ? "\(account.displayName) — \(L10n.string("Signed out"))" : account.displayName)
        .contextMenu {
            if account.signedOut {
                Button {
                    Task { await workspace.signInAccount(account) }
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(workspace.isSigningOutAccount)
            } else {
                Button {
                    Task { await workspace.signOutAccount(account) }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(workspace.isSigningOutAccount)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if account.signedOut {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        } else if unread > 0 {
            Text(unreadBadgeLabel(for: unread))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(MessagesPalette.sentBubble))
                .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
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

                    MessagesSearchField(text: $workspace.searchText, accessibilityIdentifier: "chat.search")
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
                            .accessibilityIdentifier("chat.row.\(chat.id)")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("chat.list")
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

struct SettingsListDrawerView: View {
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
                    sanitizedPictureURL: account.sanitizedPictureURL,
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

struct SettingsSidebarRow: View {
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

struct ChatRowContent: View {
    let chat: ChatItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProfileImageAvatarView(
                seed: chat.avatarSeed,
                initials: chat.title,
                sanitizedPictureURL: chat.sanitizedPictureURL,
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
                HStack(spacing: 4) {
                    if chat.hasMention {
                        Image(systemName: "at")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.accentColor))
                            .help(L10n.string("You were mentioned"))
                    }
                    Text(unreadBadgeLabel(for: chat.unreadCount))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(MessagesPalette.sentBubble))
                }
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

struct PendingInviteBadge: View {
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
