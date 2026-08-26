//
//  SignOutConfirmation.swift
//  whitenoise-mac
//
//  The one sign-out confirmation, shared by the two places that can raise it: the account
//  switcher card, where a specific identity is picked, and the drawer's isolated Sign Out row,
//  which always means the active one.
//
//  Extracted rather than written twice, because the copy is the promise: signing out leaves the
//  account and its local data on this Mac. Two dialogs would be two chances to say that
//  differently, and only one of them would be the one the reader remembers.
//

import SwiftUI

private struct SignOutConfirmationModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    // Localizing against `\.locale` rather than the stored preference is what re-renders the
    // dialog's copy on a language switch — see `L10n.string(_:locale:)`.
    @Environment(\.locale) private var locale

    let account: AccountItem?
    @Binding var isPresented: Bool
    let onSignOut: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.string("Sign out of this account?", locale: locale),
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button(L10n.string("Sign Out", locale: locale), role: .destructive) {
                    onSignOut()
                }
                Button(L10n.string("Cancel", locale: locale), role: .cancel) {}
            } message: {
                Text(
                    L10n.string(
                        "The account and its local data will stay on this Mac so you can sign in again later.",
                        locale: locale
                    )
                )
            }
    }
}

extension View {
    /// Raises the sign-out confirmation for `account`. `onSignOut` runs only if the reader
    /// confirms; dismissing does nothing, so the caller clears its own pending state through
    /// `isPresented`.
    func signOutConfirmation(
        account: AccountItem?,
        isPresented: Binding<Bool>,
        onSignOut: @escaping () -> Void
    ) -> some View {
        modifier(
            SignOutConfirmationModifier(
                account: account,
                isPresented: isPresented,
                onSignOut: onSignOut
            )
        )
    }
}
