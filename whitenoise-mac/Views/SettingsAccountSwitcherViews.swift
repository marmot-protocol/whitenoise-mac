//
//  SettingsAccountSwitcherViews.swift
//  whitenoise-mac
//
//  The account switcher that sits at the top of Settings: the card naming the
//  active identity, the popover listing every identity on this Mac, and the
//  add-account sheet. This is where the former Accounts settings page went —
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
    @State private var isAddAccountPresented = false
    @State private var accountPendingRemoval: AccountItem?
    @State private var accountPendingSignOut: AccountItem?

    var body: some View {
        VStack(spacing: 10) {
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
                            .wnFont(.semiBold12)
                            .lineLimit(1)
                        CopyableKeyLabel(accountIdHex: account.accountIdHex, head: 8, tail: 6, showsCopyButton: false)
                    }
                } else {
                    Label(
                        L10n.string("No account", locale: locale),
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .wnFont(.semiBold12)
                }

                Spacer(minLength: 0)

                if let account = workspace.activeAccount {
                    PublicIdentityQRCodeButton(
                        accountIdHex: account.accountIdHex,
                        displayName: account.displayName
                    )
                }
            }

            Button {
                isSwitcherPresented = true
            } label: {
                Label(
                    L10n.string("Switch Account", locale: locale),
                    systemImage: "arrow.up.arrow.down"
                )
                .wnFont(.semiBold12)
                .frame(maxWidth: .infinity)
            }
            .nativeGlassButtonStyle()
            .help(L10n.string("Switch Account", locale: locale))
            .popover(isPresented: $isSwitcherPresented, arrowEdge: .bottom) {
                AccountSwitcherPopover(
                    onSelect: { account in
                        isSwitcherPresented = false
                        workspace.selectAccountFromSettings(account)
                    },
                    onSignIn: { account in
                        isSwitcherPresented = false
                        Task { await workspace.signInAccount(account) }
                    },
                    onAddAccount: {
                        isSwitcherPresented = false
                        isAddAccountPresented = true
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
                // A popover is hosted in its own window, so SwiftUI re-derives the
                // system-backed environment values — `\.locale` among them — instead of
                // inheriting the one ContentView injects. `AccountSwitcherPopover` is a
                // separate `View` that reads `@Environment(\.locale)` for itself, so
                // without this it resolves every label against the *system* language and
                // renders English while the rest of the app follows the preference. The
                // confirmation dialogs below don't need it: their closures capture this
                // view's own `locale`. Same re-injection as the global search sheet in
                // `ContentView`.
                .environment(workspace)
                .environment(\.locale, workspace.preferredLocale)
            }
        }
        .padding(10)
        .glassCard()
        .sheet(isPresented: $isAddAccountPresented) {
            AddAccountSheet()
                .environment(workspace)
                .environment(\.locale, workspace.preferredLocale)
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
        .confirmationDialog(
            L10n.string("Sign out of this account?", locale: locale),
            isPresented: signOutConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Sign Out", locale: locale), role: .destructive) {
                guard let account = accountPendingSignOut else { return }
                accountPendingSignOut = nil
                Task { await workspace.signOutAccount(account) }
            }
            Button(L10n.string("Cancel", locale: locale), role: .cancel) {
                accountPendingSignOut = nil
            }
        } message: {
            Text(
                L10n.string(
                    "The account and its local data will stay on this Mac so you can sign in again later.",
                    locale: locale
                )
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

    private var signOutConfirmationBinding: Binding<Bool> {
        Binding(
            get: { accountPendingSignOut != nil },
            set: { isPresented in
                if !isPresented { accountPendingSignOut = nil }
            }
        )
    }
}

/// The switcher itself: every identity stored on this Mac, with the active one
/// marked, plus the way in for a new one. Every action is reported to the card that
/// presents this popover: it is the view that outlives the popover, so it is the one
/// that can close it and then raise a confirmation or a sheet.
struct AccountSwitcherPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let onSelect: (AccountItem) -> Void
    let onSignIn: (AccountItem) -> Void
    let onAddAccount: () -> Void
    let onSignOut: (AccountItem) -> Void
    let onRemove: (AccountItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Accounts", locale: locale))
                    .wnFont(.semiBold14)
                Text(L10n.string("Manage the identities available on this Mac.", locale: locale))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if workspace.accounts.isEmpty {
                Text(L10n.string("No accounts", locale: locale))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(workspace.accounts) { account in
                            AccountSwitcherRow(
                                account: account,
                                isActive: account.id == workspace.activeAccountId,
                                unreadCount: workspace.unreadCount(forAccountIdHex: account.accountIdHex),
                                isAccountMutationInProgress: workspace.isAccountMutationInProgress,
                                onSelect: { onSelect(account) },
                                onSignIn: { onSignIn(account) },
                                onSignOut: { onSignOut(account) },
                                onRemove: { onRemove(account) }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 260)
            }

            Divider()

            Button(action: onAddAccount) {
                Label(L10n.string("Add Account", locale: locale), systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .nativeGlassProminentButtonStyle()
            .disabled(workspace.isAuthenticating || workspace.isAccountMutationInProgress)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// One identity in the switcher. Tapping switches to it (or signs it back in when
/// it was signed out); the trailing menu carries the actions that need a
/// confirmation.
struct AccountSwitcherRow: View {
    @Environment(\.locale) private var locale
    let account: AccountItem
    let isActive: Bool
    let unreadCount: Int
    let isAccountMutationInProgress: Bool
    let onSelect: () -> Void
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: account.signedOut ? onSignIn : onSelect) {
                HStack(spacing: 10) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.initials,
                        sanitizedPictureURL: account.sanitizedPictureURL,
                        size: 32,
                        isSelected: isActive
                    )
                    .opacity(account.signedOut ? 0.4 : 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .wnFont(.semiBold12)
                            .lineLimit(1)

                        Text(statusText)
                            .wnFont(.medium10)
                            .foregroundStyle(
                                account.signedOut
                                    ? WNColor.intentionWarningContent
                                    : WNColor.backgroundContentSecondary)
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
            .disabled(account.signedOut && isAccountMutationInProgress)

            Menu {
                Group {
                    if account.signedOut {
                        Button(action: onSignIn) {
                            Label(
                                L10n.string("Sign In", locale: locale),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                    } else {
                        Button(action: onSignOut) {
                            Label(
                                L10n.string("Sign Out", locale: locale),
                                systemImage: "rectangle.portrait.and.arrow.right"
                            )
                        }
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
        if account.signedOut {
            return L10n.string("Signed out", locale: locale)
        }
        if account.localSigning {
            return L10n.string("Local signing", locale: locale)
        }
        return account.externalSigning
            ? L10n.string("External signing", locale: locale)
            : L10n.string("Watch-only", locale: locale)
    }
}

/// Adds an identity without leaving Settings: log in with an existing `nsec`, or
/// create a new one. Both paths land on the new identity's profile page so the
/// switcher card visibly reflects the account that is now active.
struct AddAccountSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// Authentication adds an account, so it waits out any other account mutation
    /// (sign-out, removal, wipe) rather than racing its account-list refresh.
    private var isAuthenticationBlocked: Bool {
        workspace.isAuthenticating || workspace.isAccountMutationInProgress
    }

    private var isLoginDisabled: Bool {
        workspace.loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isAuthenticationBlocked
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("Add Account", locale: locale))
                    .wnFont(.semiBold16)

                Spacer()

                GlassCircleCloseButton {
                    cancel()
                }
            }

            SecureField(
                L10n.string("nsec1...", locale: locale),
                text: $workspace.loginIdentity,
                prompt: Text(L10n.string("nsec1...", locale: locale))
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .disabled(workspace.isAuthenticating)

            HStack(spacing: 10) {
                Button {
                    Task { await addAccount { await workspace.login() } }
                } label: {
                    Label(
                        workspace.authenticationActivity == .login
                            ? L10n.string("Logging in...", locale: locale)
                            : L10n.string("Log in with key", locale: locale),
                        systemImage: "key"
                    )
                }
                .nativeGlassProminentButtonStyle()
                .disabled(isLoginDisabled)

                Button {
                    workspace.clearEnteredLoginIdentity()
                    Task { await addAccount { await workspace.signUp() } }
                } label: {
                    Label(
                        workspace.authenticationActivity == .signUp
                            ? L10n.string("Creating...", locale: locale)
                            : L10n.string("Create identity", locale: locale),
                        systemImage: "plus.circle"
                    )
                }
                .nativeGlassButtonStyle()
                .disabled(isAuthenticationBlocked)

                Spacer()

                Button(L10n.string("Cancel", locale: locale)) {
                    cancel()
                }
                .disabled(workspace.isAuthenticating)
            }

            SettingsErrorView(error: workspace.lastError)
        }
        .padding(22)
        .frame(width: 420)
        .background {
            LiquidGlassBackground()
        }
        // Esc, or the presenter going away, dismisses the sheet without running
        // `cancel()`; the entered nsec must not survive either. See #32.
        .onDisappear {
            workspace.clearEnteredLoginIdentity()
        }
    }

    /// Runs an authentication path and, when it succeeds, returns to Settings on
    /// the new account's profile. `login`/`signUp` clear the selection on success,
    /// so without this the window would jump to the chat list.
    private func addAccount(_ authenticate: () async -> Void) async {
        await authenticate()
        guard workspace.lastError == nil else { return }
        dismiss()
        workspace.showSettingsPage(.overview)
    }

    /// Scrubs the entered nsec (private key) rather than letting it linger in
    /// observable memory behind a dismissed sheet. See #32.
    private func cancel() {
        workspace.clearEnteredLoginIdentity()
        dismiss()
    }
}
