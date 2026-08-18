//
//  RemoveAccountConfirmation.swift
//  whitenoise-mac
//
//  The two-step confirmation for removing an identity from this Mac, as a modifier so
//  every call site asks the same question and spells out the same consequence.
//

import SwiftUI

struct RemoveAccountConfirmationModifier: ViewModifier {
    let account: AccountItem?
    @Binding var isPresented: Bool
    let isRemoveDisabled: Bool
    let onRemove: () -> Void

    private static var message: String {
        L10n.string(
            "This deletes the private key and local message history for this identity from this Mac. This cannot be undone."
        )
    }

    private static func title(for account: AccountItem?) -> String {
        guard let account else { return L10n.string("Remove account?") }
        return String(format: L10n.string("Remove %@?"), account.displayName)
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Self.title(for: account),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove Account"), role: .destructive) {
                onRemove()
            }
            .disabled(isRemoveDisabled)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(Self.message)
        }
    }
}

extension View {
    func removeAccountConfirmation(
        account: AccountItem?,
        isPresented: Binding<Bool>,
        isRemoveDisabled: Bool,
        onRemove: @escaping () -> Void
    ) -> some View {
        modifier(
            RemoveAccountConfirmationModifier(
                account: account,
                isPresented: isPresented,
                isRemoveDisabled: isRemoveDisabled,
                onRemove: onRemove
            )
        )
    }
}
