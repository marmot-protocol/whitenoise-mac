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

/// Compact native `Menu`-based profile switcher anchored at the top of the chat-list sidebar above
/// Search (S03, N02). Replaces the fixed-width left `AccountRailView` column while preserving the
/// exact account-switching, Add Profile, Settings, and background-profile attention contracts.
///
/// Only lists `signedInAccounts` (never signed-out identities) and carries no unconfirmed
/// destructive account actions.
struct SidebarProfileSwitcherView: View {
    @Environment(\.locale) private var locale
    let signedInAccounts: [AccountItem]
    let activeAccount: AccountItem?
    let isAccountMutationInProgress: Bool
    let attentionModel: AccountAttentionViewModel?
    let onSelectAccount: (AccountItem) -> Void
    let onAddProfile: () -> Void
    let onOpenSettings: () -> Void
    @State private var isHovering = false

    var body: some View {
        let attention = SidebarProfileAttentionSummary.compute(
            signedInAccounts: signedInAccounts,
            activeAccountId: activeAccount?.id,
            unreadCountForAccountIdHex: { accountIdHex in
                attentionModel?.unreadCount(accountIdHex: accountIdHex)
            }
        )

        Menu {
            Section {
                ForEach(signedInAccounts) { account in
                    let isActive = account.id == activeAccount?.id
                    let unread = attention.unreadCount(for: account)
                    Button {
                        guard !isActive else { return }
                        onSelectAccount(account)
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
                    .disabled(isAccountMutationInProgress)
                }
            }

            Divider()

            Button(action: onAddProfile) {
                Label(L10n.string("Add Profile", locale: locale), systemImage: "person.badge.plus")
            }
            .disabled(isAccountMutationInProgress)

            Button(action: onOpenSettings) {
                Label(L10n.string("Settings…", locale: locale), systemImage: "gearshape")
            }
        } label: {
            SidebarProfileSwitcherLabel(
                activeAccount: activeAccount,
                backgroundUnreadCount: attention.backgroundUnreadCount,
                isHovering: isHovering
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
        .help(activeAccount?.displayName ?? L10n.string("Choose a profile", locale: locale))
        .accessibilityIdentifier("sidebar.profileSwitcher")
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

private struct SidebarProfileSwitcherLabel: View {
    @Environment(\.locale) private var locale
    let activeAccount: AccountItem?
    let backgroundUnreadCount: Int
    var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let account = activeAccount {
                ProfileImageAvatarView(
                    seed: account.accountIdHex,
                    initials: account.initials,
                    sanitizedPictureURL: account.sanitizedPictureURL,
                    size: 26,
                    isSelected: false
                )
                Text(account.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(L10n.string("No account", locale: locale))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if backgroundUnreadCount > 0 {
                UnreadCountBadge(count: backgroundUnreadCount)
            }

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview("Sidebar profile switcher") {
    let workspace = WorkspaceState.preview()
    SidebarProfileSwitcherView(
        signedInAccounts: workspace.signedInAccounts,
        activeAccount: workspace.activeAccount,
        isAccountMutationInProgress: false,
        attentionModel: nil,
        onSelectAccount: { _ in },
        onAddProfile: {},
        onOpenSettings: {}
    )
    .environment(workspace)
    .frame(width: 280)
}

#Preview("Profile switcher label with background unread") {
    SidebarProfileSwitcherLabel(
        activeAccount: WorkspaceState.preview().activeAccount,
        backgroundUnreadCount: 7
    )
    .environment(WorkspaceState.preview())
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(width: 240)
}
