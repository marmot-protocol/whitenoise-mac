//
//  SettingsAccountSwitcherViews.swift
//  whitenoise-mac
//
//  The account switcher that sits at the top of Settings: the card naming the
//  active identity, and the popover listing the identities signed in on this Mac.
//  The popover switches between them and manages them — sign out, remove — and it
//  neither creates one nor reactivates one. The `Add Account` button that used to
//  sit under its row list opened the onboarding landing pane, which put account
//  creation in the same dropdown as account switching; creating one is the card's
//  own `profileManagementRow` instead, which offers it precisely when there is
//  nothing to switch to. Signed-out identities are not listed at all: a row that
//  cannot be switched to does not belong in a switcher, and a deactivated identity is
//  reached again through Sign In with its key rather than by a click that asks for
//  nothing. This is where the former Accounts settings page went —
//  the iOS and Flutter clients open Settings on the current profile with a
//  switch control directly underneath it rather than routing identity work
//  through a separate Accounts tab, and this mirrors that on macOS.
//

import MarmotKit
import SwiftUI

/// Top-of-Settings account card: shows who is signed in, and opens the switcher.
///
/// The card owns the sign-out and remove confirmations rather than the popover
/// that raises them, because a popover dismisses as soon as the dialog takes key
/// focus — the confirmation has to outlive it.
struct SettingsAccountSwitcherCard: View {
    @Environment(WorkspaceState.self) private var workspace
    // Localizing through `\.locale` (not the stored preference) is what re-renders
    // the card when the language changes while settings are open — see
    // `L10n.string(_:locale:)`.
    @Environment(\.locale) private var locale
    @State private var isSwitcherPresented = false
    @State private var accountPendingRemoval: AccountItem?
    @State private var accountPendingSignOut: AccountItem?
    @State private var isQRPresented = false

    var body: some View {
        // The prototype's first hub card: the active profile, then the one row that manages
        // profiles. Same surface as every other card in the drawer — it used to be a
        // `glassCard()`, which made the identity read as chrome pinned above the list rather
        // than as the list's first group.
        SettingsSidebarGroupCard {
            activeProfileRow

            SettingsSidebarRowSeparator()

            profileManagementRow
        }
        .sheet(isPresented: $isQRPresented) {
            if let account = workspace.activeAccount {
                PublicIdentityQRCodeSheet(
                    displayName: account.displayName,
                    npub: workspace.npub(forAccountIdHex: account.accountIdHex)
                )
            }
        }
        .removeAccountConfirmation(
            account: accountPendingRemoval,
            isPresented: removeConfirmationBinding,
            isRemoveDisabled: workspace.isAccountMutationInProgress
        ) {
            guard let account = accountPendingRemoval else { return }
            accountPendingRemoval = nil
            Task { await workspace.removeAccount(account) }
        }
        .signOutConfirmation(
            account: accountPendingSignOut,
            isPresented: signOutConfirmationBinding
        ) {
            guard let account = accountPendingSignOut else { return }
            accountPendingSignOut = nil
            Task { await workspace.signOutAccount(account) }
        }
    }

    /// The active identity, and the way to hand it to someone else.
    ///
    /// The whole row opens the QR sheet, with the glyph and a disclosure chevron at the trailing
    /// edge — the prototype's profile row shows a QR symbol beside a disclosure indicator and
    /// pushes Share & Connect, and a row that is one big affordance is easier to hit than a 24pt
    /// glyph.
    @ViewBuilder
    private var activeProfileRow: some View {
        if let account = workspace.activeAccount {
            Button {
                isQRPresented = true
            } label: {
                HStack(spacing: 10) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.initials,
                        sanitizedPictureURL: account.sanitizedPictureURL,
                        isOwnAccountImage: true,
                        size: 34,
                        isSelected: false
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName)
                            .wnFont(.medium14)
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                            .lineLimit(1)
                        CopyableKeyLabel(
                            accountIdHex: account.accountIdHex, head: 8, tail: 6, showsCopyButton: false)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "qrcode")
                        .wnFont(.medium14)
                        .foregroundStyle(WNColor.backgroundContentSecondary)

                    Image(systemName: "chevron.right")
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                }
                .padding(.vertical, SettingsSidebarRowMetrics.verticalPadding)
                .padding(.horizontal, SettingsSidebarRowMetrics.horizontalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Show npub QR code", locale: locale))
        } else {
            Label(
                L10n.string("No account", locale: locale),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .wnFont(.medium14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SettingsSidebarRowMetrics.verticalPadding)
            .padding(.horizontal, SettingsSidebarRowMetrics.horizontalPadding)
        }
    }

    /// One row that adapts to how many identities are signed in, the way the prototype's hub
    /// does: with a single profile there is nothing to switch to, so the row offers to add one;
    /// with more, it opens the switcher. A permanent "Switch Account" button was offering a
    /// choice that, for most people, has exactly one option.
    ///
    /// Counted over `hasOtherSignedInAccount` rather than the stored identities: a deactivated
    /// one is not in the switcher's list, so counting it here promised a switch to a list of one.
    private var profileManagementRow: some View {
        Button {
            if workspace.hasOtherSignedInAccount {
                isSwitcherPresented = true
            } else {
                workspace.showAccountOnboarding()
            }
        } label: {
            HStack(spacing: SettingsSidebarRowMetrics.glyphSpacing) {
                Image(
                    systemName: workspace.hasOtherSignedInAccount
                        ? "arrow.up.arrow.down" : "person.crop.circle.badge.plus"
                )
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(width: SettingsSidebarRowMetrics.glyphWidth)

                Text(
                    workspace.hasOtherSignedInAccount
                        ? L10n.string("Switch Account", locale: locale)
                        : L10n.string("Add Account", locale: locale)
                )
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, SettingsSidebarRowMetrics.verticalPadding)
            .padding(.horizontal, SettingsSidebarRowMetrics.horizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isSwitcherPresented, arrowEdge: .trailing) {
            AccountSwitcherPopover(
                onSelect: { account in
                    isSwitcherPresented = false
                    workspace.selectAccountFromSettings(account)
                },
                onSignOut: { account in
                    isSwitcherPresented = false
                    accountPendingSignOut = account
                },
                onRemove: { account in
                    isSwitcherPresented = false
                    accountPendingRemoval = account
                }
            )
            // A popover is hosted in its own window, so SwiftUI re-derives the system-backed
            // environment values — `\.locale` among them — instead of inheriting the one
            // ContentView injects. `AccountSwitcherPopover` reads `@Environment(\.locale)` for
            // itself, so without this it resolves every label against the *system* language and
            // renders English while the rest of the app follows the preference. The confirmation
            // dialogs don't need it: their closures capture this view's own `locale`.
            .environment(workspace)
            .environment(\.locale, workspace.preferredLocale)
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

    private var signOutConfirmationBinding: Binding<Bool> {
        Binding(
            get: { accountPendingSignOut != nil },
            set: { isPresented in
                if !isPresented { accountPendingSignOut = nil }
            }
        )
    }
}

/// The switcher itself: the identities signed in on this Mac, with the active one
/// marked. Switching and managing only — neither creating an identity nor bringing
/// a deactivated one back is offered here. Every action is reported to the card that
/// presents this popover: it is the view that outlives the popover, so it is the one
/// that can close it and then raise a confirmation or a sheet.
struct AccountSwitcherPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let onSelect: (AccountItem) -> Void
    let onSignOut: (AccountItem) -> Void
    let onRemove: (AccountItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Accounts", locale: locale))
                    .wnFont(.semiBold14)
                Text(L10n.string("Manage the accounts signed in on this Mac.", locale: locale))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Signed-out identities are filtered out, so this is reachable with accounts still
            // stored: every one of them deactivated leaves nothing to switch between.
            if workspace.signedInAccounts.isEmpty {
                Text(L10n.string("No accounts", locale: locale))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(workspace.signedInAccounts) { account in
                            AccountSwitcherRow(
                                account: account,
                                isActive: account.id == workspace.activeAccountId,
                                unreadCount: workspace.unreadCount(forAccountIdHex: account.accountIdHex),
                                isAccountMutationInProgress: workspace.isAccountMutationInProgress,
                                onSelect: { onSelect(account) },
                                onSignOut: { onSignOut(account) },
                                onRemove: { onRemove(account) }
                            )
                        }
                    }
                    .padding(.horizontal, Self.rowChromeInset)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 260)
                // A `ScrollView` clips to its bounds, and the active row's avatar is seated flush
                // against the leading one: the selection ring is drawn *outside* the avatar's
                // frame, so it came out with a flat left side. The content is inset by the ring's
                // reach and the scroll view widened by the same amount, which leaves the rows
                // where they were — aligned with the header above them — while giving the chrome
                // somewhere to draw. Insetting alone would indent every row instead.
                .padding(.horizontal, -Self.rowChromeInset)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Slack the scrolling row list leaves on each side for the avatar chrome that draws outside
    /// its frame. Vertically the rows' own `.padding(.vertical, 4)` already covers the ring, so
    /// only the horizontal edges need it.
    private static var rowChromeInset: CGFloat {
        AvatarChromeModifier.overhang(forAvatarSize: AccountSwitcherRow.avatarSize)
    }
}

/// One identity in the switcher. Tapping switches to it; the trailing menu carries
/// the actions that need a confirmation.
///
/// The list is fed `signedInAccounts`, so `account.signedOut` is false here by
/// construction. It used to branch on it — a dimmed avatar under a `Signed out`
/// caption, whose tap and whose menu item signed the identity back in — and
/// reintroducing that branch would be dead code describing a row that cannot reach
/// this view.
struct AccountSwitcherRow: View {
    /// Diameter of the row's avatar. Read by `AccountSwitcherPopover.rowChromeInset`, which sizes
    /// the scroll inset from it — the chrome's reach scales with the avatar.
    static let avatarSize: CGFloat = 32

    @Environment(\.locale) private var locale
    let account: AccountItem
    let isActive: Bool
    let unreadCount: Int
    let isAccountMutationInProgress: Bool
    let onSelect: () -> Void
    let onSignOut: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.initials,
                        sanitizedPictureURL: account.sanitizedPictureURL,
                        // Every row here is one of this Mac's own signed-in accounts, so this is
                        // unconditional — see `RemoteImageDisplayPolicy`. The narrower
                        // `!account.signedOut` it used to carry existed for the deactivated rows,
                        // whose relay key packages sign-out drops; with those rows gone from the
                        // list there is nothing left for it to exclude.
                        isOwnAccountImage: true,
                        size: Self.avatarSize,
                        isSelected: isActive
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .wnFont(.semiBold12)
                            .lineLimit(1)

                        Text(statusText)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if unreadCount > 0 {
                        UnreadCountBadge(count: unreadCount)
                    }

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.intentionSuccessContent)
                            .accessibilityLabel(Text(L10n.string("Active", locale: locale)))
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Group {
                    Button(action: onSignOut) {
                        Label(
                            L10n.string("Sign Out", locale: locale),
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                    }

                    Divider()

                    Button(role: .destructive, action: onRemove) {
                        Label(
                            L10n.string("Remove Account", locale: locale),
                            systemImage: "person.crop.circle.badge.minus"
                        )
                    }
                }
                .menuLabelIcons()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isAccountMutationInProgress)
            .help(L10n.string("Account actions", locale: locale))
            .accessibilityLabel(
                Text(String(format: L10n.string("Actions for %@", locale: locale), account.displayName))
            )
        }
    }

    private var statusText: String {
        if account.localSigning {
            return L10n.string("Local signing", locale: locale)
        }
        return account.externalSigning
            ? L10n.string("External signing", locale: locale)
            : L10n.string("Watch-only", locale: locale)
    }
}
