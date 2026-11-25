//
//  SignOutSheet.swift
//  whitenoise-mac
//
//  The one way out of an account, and the one place that decides whether its local data
//  goes with it.
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
    @Environment(SessionState.self) private var session
    @Environment(SettingsWindowCoordinator.self) private var settings: SettingsWindowCoordinator?
    @Environment(\.dismiss) private var dismiss

    let account: AccountItem

    /// Off by default so signing out preserves local data unless the user explicitly opts in and
    /// clears the type-to-confirm gate.
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

    /// This account has other linked devices here, so a wipe first hands this device's removal to
    /// them. Known only for the account whose scope is open, which is the one this sheet signs out.
    private var handsOffToLinkedDevices: Bool {
        guard let scope = session.accountScope, scope.account.id == account.id else { return false }
        return !scope.deviceLinking.otherDevices.isEmpty
    }

    private var canSignOut: Bool {
        stage == nil && (!wipesLocalData || isConfirmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Sign Out"))
                .font(.headline)

            SignOutAccountIdentity(account: account)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                WNToggle(isOn: $wipesLocalData) {
                    Text(L10n.string("Wipe Data From This Device"))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(stage != nil)

                SettingsFooterText(
                    wipesLocalData
                        ? L10n.string(
                            "This account and all of its local data will be permanently removed from this Mac. Previous chats won't return."
                        )
                        : L10n.string(
                            "The account and its local data will stay on this Mac so you can sign in again later.")
                )
                if wipesLocalData, handsOffToLinkedDevices {
                    SettingsFooterText(L10n.string(LinkedDeviceHandOff.note))
                }
            }

            if wipesLocalData {
                SignOutWipeConfirmationField(
                    challenge: challenge,
                    confirmationInput: $confirmationInput,
                    isDisabled: stage != nil
                )
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button(L10n.string("Cancel")) {
                    dismiss()
                }
                .wnSecondaryButtonStyle()
                .keyboardShortcut(.cancelAction)
                .disabled(stage != nil)

                Button(role: .destructive) {
                    Task { await signOut() }
                } label: {
                    HStack(spacing: 8) {
                        if stage != nil {
                            ProgressView().controlSize(.small)
                        }
                        Text(L10n.string("Sign Out"))
                    }
                }
                .accessibilityValue(stage.map { Text(L10n.string($0.labelKey)) } ?? Text(verbatim: ""))
                .wnDestructiveButtonStyle()
                .disabled(stage == nil && !canSignOut)
            }

            if let error = settings?.lastError {
                SettingsErrorView(error: error)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(stage != nil)
        .onAppear {
            workspace.setSettingsError(nil)
        }
        .onChange(of: wipesLocalData) { _, wipesLocalData in
            if !wipesLocalData { confirmationInput = "" }
        }
        .onChange(of: account.id) {
            wipesLocalData = false
            confirmationInput = ""
        }
    }

    private func signOut() async {
        guard canSignOut else { return }
        // Captured before the teardown: once it succeeds the host may hand this sheet another
        // account, and `.onChange(of: account.id)` resets the toggle under the await.
        let wipes = wipesLocalData
        if wipes {
            stage = .wiping
            session.reportWipe(await workspace.removeAccount(account))
        } else {
            stage = .signingOut
            await workspace.signOutAccount(account)
        }
        stage = nil
        // Dismiss only when the teardown actually ran, read off the account list it left behind —
        // the rule `DeleteProfileRemoval` follows — and never off `lastError`. There are three
        // outcomes, and `lastError` cannot tell the last two apart:
        //  - Nothing was torn down (the core refused, or another account change held the gate):
        //    the account is still signed in. The sheet stays, so the error it draws in its
        //    `SettingsErrorView` is read rather than dismissed with it.
        //  - The exit ran and the app moved on, to the profile chooser or onboarding: dismissing
        //    covers the first, and is harmless in the second, which takes the sheet with it.
        //  - The exit ran and the app switched straight into the only profile left, whose
        //    settings then failed to load. That error is the survivor's and stays on `lastError`
        //    for its settings page; it is no reason to keep this sheet up. The host re-renders it
        //    for the now-active survivor, so staying would put a Sign Out button for the wrong
        //    identity under the reader's cursor.
        guard Self.exitSucceeded(for: account, wipedLocalData: wipes, in: workspace.accounts) else {
            return
        }
        dismiss()
    }

    /// Whether the exit this sheet ran went through for `account`, judged from the account list
    /// the workspace holds afterwards. A wipe succeeded when the account is gone from this Mac; a
    /// sign-out when it is gone or still listed but signed out.
    static func exitSucceeded(for account: AccountItem, wipedLocalData: Bool, in accounts: [AccountItem]) -> Bool {
        guard let remaining = accounts.first(where: { $0.id == account.id }) else { return true }
        return !wipedLocalData && remaining.signedOut
    }
}

private struct SignOutAccountIdentity: View {
    let account: AccountItem

    var body: some View {
        HStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: account.initials,
                sanitizedPictureURL: account.sanitizedPictureURL,
                size: 48,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.headline)
                    .lineLimit(1)
                CopyableKeyLabel(accountIdHex: account.accountIdHex, showsCopyButton: false)
            }
        }
    }
}

private struct SignOutWipeConfirmationField: View {
    let challenge: String
    @Binding var confirmationInput: String
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(challenge, text: $confirmationInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(isDisabled)
                .accessibilityLabel(Text(L10n.string("Wipe Data From This Device")))

            SettingsFooterText(
                String(
                    format: L10n.string(
                        "Type “%@” to confirm permanent removal of this account and its local data."),
                    challenge)
            )
        }
    }
}

#Preview("Sign out sheet") {
    SignOutSheet(account: AccountItem.samples[0])
        .environment(WorkspaceState.preview())
        .environment(SessionState())
}
