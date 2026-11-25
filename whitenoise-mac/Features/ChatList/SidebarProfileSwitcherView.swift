import SwiftUI

/// Summarizes unread attention for signed-in profiles other than the active one so the compact
/// sidebar profile switcher keeps background-profile unread counts visible while closed (S03).
nonisolated struct SidebarProfileAttentionSummary: Equatable, Sendable {
    let backgroundUnreadCount: Int
    let perAccountUnreadCounts: [String: Int]

    static func compute(
        signedInAccounts: [AccountItem],
        activeAccountId: String?,
        unreadCountForAccountIdHex: (String) -> Int?
    ) -> Self {
        var perAccount: [String: Int] = [:]
        var backgroundTotal = 0
        for account in signedInAccounts {
            let count = max(0, unreadCountForAccountIdHex(account.accountIdHex) ?? 0)
            perAccount[account.id] = count
            if account.id != activeAccountId {
                backgroundTotal += count
            }
        }
        return Self(backgroundUnreadCount: backgroundTotal, perAccountUnreadCounts: perAccount)
    }

    func unreadCount(for account: AccountItem) -> Int {
        perAccountUnreadCounts[account.id] ?? 0
    }
}

/// Formats account entries inside the native sidebar profile switcher `Menu`.
nonisolated enum SidebarAccountMenuFormatting {
    static func menuTitle(displayName: String, unreadCount: Int) -> String {
        guard unreadCount > 0 else { return displayName }
        let formattedCount = unreadCount > 99 ? "99+" : "\(unreadCount)"
        return "\(displayName) (\(formattedCount))"
    }
}

/// Compact native `Menu`-based profile switcher anchored at the foot of the chat-list sidebar
/// (S03, N02). Replaces the fixed-width left `AccountRailView` column while preserving the exact
/// account-switching, Add Profile, Settings, and background-profile attention contracts.
///
/// Only lists `workspace.signedInAccounts` (never signed-out identities) and carries no
/// unconfirmed destructive account actions.
struct SidebarProfileSwitcherView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let attentionModel: AccountAttentionViewModel?
    let onOpenSettings: () -> Void

    var body: some View {
        let signedInAccounts = workspace.signedInAccounts
        let attention = SidebarProfileAttentionSummary.compute(
            signedInAccounts: signedInAccounts,
            activeAccountId: workspace.activeAccountId,
            unreadCountForAccountIdHex: { accountIdHex in
                attentionModel?.unreadCount(accountIdHex: accountIdHex)
            }
        )

        HStack(spacing: 8) {
            Menu {
                Section {
                    ForEach(signedInAccounts) { account in
                        let isActive = account.id == workspace.activeAccountId
                        let unread = attention.unreadCount(for: account)
                        Button {
                            guard !isActive else { return }
                            workspace.selectAccount(account)
                        } label: {
                            if isActive {
                                Label(
                                    SidebarAccountMenuFormatting.menuTitle(
                                        displayName: account.displayName,
                                        unreadCount: unread
                                    ),
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(
                                    SidebarAccountMenuFormatting.menuTitle(
                                        displayName: account.displayName,
                                        unreadCount: unread
                                    )
                                )
                            }
                        }
                        .disabled(workspace.isAccountMutationInProgress)
                    }
                }

                Divider()

                Button {
                    workspace.showAccountOnboarding()
                } label: {
                    Label(L10n.string("Add Profile", locale: locale), systemImage: "person.badge.plus")
                }
                .disabled(workspace.isAccountMutationInProgress)

                Button(action: onOpenSettings) {
                    Label(L10n.string("Settings…", locale: locale), systemImage: "gearshape")
                }
            } label: {
                SidebarProfileSwitcherLabel(
                    activeAccount: workspace.activeAccount,
                    backgroundUnreadCount: attention.backgroundUnreadCount
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help(workspace.activeAccount?.displayName ?? L10n.string("Choose a profile", locale: locale))
            .accessibilityIdentifier("sidebar.profileSwitcher")

            Spacer(minLength: 4)

            Button(action: onOpenSettings) {
                Label(L10n.string("Settings…", locale: locale), systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.body)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.string("Settings…", locale: locale))
            .accessibilityLabel(L10n.string("Settings…", locale: locale))
            .accessibilityIdentifier("sidebar.settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SidebarProfileSwitcherLabel: View {
    @Environment(\.locale) private var locale
    let activeAccount: AccountItem?
    let backgroundUnreadCount: Int

    var body: some View {
        HStack(spacing: 8) {
            if let account = activeAccount {
                ProfileImageAvatarView(
                    seed: account.accountIdHex,
                    initials: account.initials,
                    sanitizedPictureURL: account.sanitizedPictureURL,
                    size: 24,
                    isSelected: false
                )
                Text(account.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(L10n.string("No account", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if backgroundUnreadCount > 0 {
                UnreadCountBadge(count: backgroundUnreadCount)
            }

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#Preview("Sidebar profile switcher") {
    SidebarProfileSwitcherView(attentionModel: nil, onOpenSettings: {})
        .environment(WorkspaceState.preview())
        .frame(width: 280)
}

#Preview("Profile switcher label with background unread") {
    SidebarProfileSwitcherLabel(
        activeAccount: WorkspaceState.preview().activeAccount,
        backgroundUnreadCount: 7
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(width: 240)
}
