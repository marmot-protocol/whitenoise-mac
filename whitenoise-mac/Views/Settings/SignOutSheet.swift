//
//  SignOutSheet.swift
//  whitenoise-mac
//
//  The one way out of an account, and the one place that decides whether its local data
//  goes with it.
//
//  This replaces two separate confirmations: a `confirmationDialog` for signing out, raised
//  from the drawer's isolated Sign Out row, and a second one for Remove Account, raised from
//  a group of its own on the Identity & Keys page. Two surfaces for two halves of one
//  question — am I leaving this account, or erasing it? — is what `wn-ios-prototype`'s
//  `docs/screens/sign-out.md` settles by making the erasure a toggle on the sign-out sheet:
//  the exit is one task, and the toggle is the only decision inside it.
//
//  A sheet rather than a dialog because a dialog cannot hold a toggle, a note that rewrites
//  itself, and a type-to-confirm field. It is also why the destructive half needs no second
//  alert on top: the sheet is the confirmation.
//

import SwiftUI

/// Signing out of the active account, with or without wiping it off this Mac.
struct SignOutSheet: View {
    /// Which teardown is running, once one is.
    private enum Stage: Equatable {
        case signingOut
        case wiping

        var labelKey: String {
            switch self {
            case .signingOut: "Signing out…"
            case .wiping: "Signing out and wiping data…"
            }
        }
    }

    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    let account: AccountItem

    /// Off by default, unlike the prototype, which arms wiping on open.
    ///
    /// The prototype has no data to lose. Here the promise this app has always made for Sign Out
    /// is that "the account and its local data will stay on this Mac" — the sentence the dialog
    /// this sheet replaced was built around — and defaulting the toggle on would quietly invert it
    /// for everyone who signs out without reading. Erasure is opt-in, and the type-to-confirm gate
    /// under the toggle is the second half of the same rule.
    @State private var wipesLocalData = false
    @State private var confirmationInput = ""
    @State private var stage: Stage?

    private var challenge: String {
        AccountWipeConfirmation.challenge(
            displayName: account.displayName,
            accountRef: account.accountRef,
            fallback: L10n.string("WIPE")
        )
    }

    private var isConfirmed: Bool {
        AccountWipeConfirmation.matches(confirmationInput, challenge: challenge)
    }

    private var canSignOut: Bool {
        stage == nil && (!wipesLocalData || isConfirmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let stage {
                progress(stage)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(stage != nil)
        .onAppear {
            // Required, not cosmetic, now that `signOut()` keeps the sheet up whenever `lastError`
            // is set: `signOutAccount`/`removeAccount` clear it only *after* their entry guard, so
            // an error left behind by some earlier profile or relay failure would both render here
            // as if this sheet caused it and stop a successful sign-out from ever dismissing.
            workspace.lastError = nil
        }
        .onChange(of: wipesLocalData) { _, wipesLocalData in
            // The typed name is scoped to the armed toggle. Leaving it behind would let a reader
            // who turned wiping off and back on find the gate already cleared.
            if !wipesLocalData { confirmationInput = "" }
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.string("Sign Out"))
                .wnFont(.semiBold16)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(stage != nil)
            .accessibilityLabel(Text(L10n.string("Close")))
        }
    }

    @ViewBuilder
    private func progress(_ stage: Stage) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(L10n.string(stage.labelKey))
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var form: some View {
        // The account the button acts on, named on the sheet that acts on it. With several
        // identities signed in on this Mac, "Sign Out" alone does not say which one is leaving.
        HStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: account.initials,
                sanitizedPictureURL: account.sanitizedPictureURL,
                isOwnAccountImage: true,
                size: 48,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .wnFont(.semiBold14)
                    .lineLimit(1)
                CopyableKeyLabel(accountIdHex: account.accountIdHex, showsCopyButton: false)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            WNToggle(isOn: $wipesLocalData) {
                // The label takes the width so the switch lands at the trailing edge, the way a
                // grouped `Form` row places it. A bare label hugs, which put the switch in the
                // middle of the sheet with dead space beside it.
                Text(L10n.string("Wipe Data From This Device"))
                    .wnFont(.medium14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // One note, rewritten by the toggle rather than two notes stacked. What changes when
            // the switch moves is what happens to the data, so the sentence about the data is the
            // thing that changes.
            SettingsFooterText(
                wipesLocalData
                    ? L10n.string(
                        "This account and all of its local data will be permanently removed from this Mac. Previous chats won't return."
                    )
                    : L10n.string(
                        "The account and its local data will stay on this Mac so you can sign in again later.")
            )
        }

        if wipesLocalData {
            VStack(alignment: .leading, spacing: 8) {
                TextField(challenge, text: $confirmationInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text(L10n.string("Wipe Data From This Device")))

                SettingsFooterText(
                    String(
                        format: L10n.string(
                            "Type “%@” to confirm permanent removal of this account and its local data."),
                        challenge)
                )
            }
        }

        Button {
            Task { await signOut() }
        } label: {
            Text(L10n.string("Sign Out"))
                .frame(maxWidth: .infinity)
        }
        // One button in one place with one label, armed or not, because the choice the reader made
        // is the toggle above it — a second, differently-worded button appearing when the toggle
        // moves would make the sheet look like it had swapped tasks. Red in both states: without
        // wiping this still ends the session and drops the account's published key packages.
        .buttonStyle(.wnDestructive)
        .controlSize(.large)
        .disabled(!canSignOut)

        if let error = workspace.lastError {
            SettingsErrorView(error: error)
        }
    }

    private func signOut() async {
        guard canSignOut else { return }
        if wipesLocalData {
            stage = .wiping
            await workspace.removeAccount(account)
        } else {
            stage = .signingOut
            await workspace.signOutAccount(account)
        }
        stage = nil
        // Dismiss only when the teardown actually ran. Both calls clear `lastError` on entry and
        // set it from their `catch`, so a non-nil error here means nothing was torn down —
        // dismissing would take the only place that error is shown away with it and leave the
        // reader guessing whether they are still signed in. Same rule the encrypted-export sheet
        // follows, and the reason this sheet draws a `SettingsErrorView` at all.
        guard workspace.lastError == nil else { return }
        // On success both paths either reselect another identity or land the app in onboarding,
        // which takes this sheet with it. Dismissing covers the first case, harmless in the second.
        dismiss()
    }
}
