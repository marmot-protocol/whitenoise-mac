//
//  SettingsAccountSwitcherViews.swift
//  whitenoise-mac
//
//  The profile card that sits at the top of Settings: the row naming the active identity, and
//  the row that adds another one.
//
//  This is where the former Accounts settings page went — the iOS and Flutter clients open
//  Settings on the current profile rather than routing identity work through a separate Accounts
//  tab, and this mirrors that on macOS.
//
//  It no longer raises a switcher popover. Switching identities is the account rail's job in this
//  window (`AccountRailAvatar`), and a second control for it in Settings was offering, in a
//  dropdown, a choice the rail already presents as a row of avatars. What the popover also
//  carried — signing out, removing an account, reactivating a deactivated identity — either has
//  another home (`SettingsSignOutRow` for the active identity, Identity & Keys for removing it)
//  or is not offered anywhere by design: a deactivated identity is reached again by signing in
//  with its key, never by a click that asks for nothing.
//

import SwiftUI

/// Top-of-Settings profile card: who is signed in, and how to add another identity.
struct SettingsAccountSwitcherCard: View {
    @Environment(WorkspaceState.self) private var workspace
    // Localizing through `\.locale` (not the stored preference) is what re-renders the
    // card when the language changes while settings are open — see
    // `L10n.string(_:locale:)`.
    @Environment(\.locale) private var locale
    @State private var isQRPresented = false

    var body: some View {
        // The prototype's first hub card: the active profile, then the one row that manages
        // profiles. Same surface as every other card in the drawer — it used to be a
        // `glassCard()`, which made the identity read as chrome pinned above the list rather
        // than as the list's first group.
        SettingsSidebarGroupCard {
            activeProfileRow

            SettingsSidebarRowSeparator()

            addProfileRow
        }
        .sheet(isPresented: $isQRPresented) {
            if let account = workspace.activeAccount {
                PublicIdentityQRCodeSheet(
                    account: account,
                    displayName: account.displayName
                )
            }
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
                        size: MessagesLayout.settingsProfileAvatarSize,
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

                    // Primary, not secondary: the prototype tints this glyph the same as the row's
                    // text, and a dimmed QR symbol directly above a full-strength `Add Profile`
                    // glyph in the same card read as the disabled one of the two.
                    Image(systemName: "qrcode")
                        .wnFont(.medium14)
                        .foregroundStyle(WNColor.backgroundContentPrimary)

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

    /// The card's second row: add an identity alongside the ones already on this Mac.
    ///
    /// One row with one job, whatever this Mac already holds. It used to adapt — `Add Account`
    /// with a single identity, `Switch Account` with more, the latter opening a popover — and the
    /// adaptive form meant the row's label and its destination changed under you as you signed a
    /// second identity in. `person.crop.circle.badge.plus` is the prototype's own glyph for this
    /// line; the `arrow.up.arrow.down` it replaced described the switching this row no longer does.
    private var addProfileRow: some View {
        Button {
            workspace.showAccountOnboarding()
        } label: {
            SettingsSidebarRowLabel(
                systemImage: "person.crop.circle.badge.plus",
                title: L10n.string("Add Profile", locale: locale)
            )
        }
        .buttonStyle(.plain)
    }
}
