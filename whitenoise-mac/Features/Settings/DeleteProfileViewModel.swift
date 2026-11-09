//
//  DeleteProfileViewModel.swift
//  whitenoise-mac
//
//  Settings → Delete Profile: the dedicated page that signs the active profile out and wipes
//  its data from this Mac, ported from `whitenoise-ios`'s `SignOutView(intent: .deleteProfile)`.
//
//  The sign-out sheet can wipe too, behind a toggle. This page exists beside it for the same
//  reason it does on iOS: someone who came to Settings to *delete* their profile should find a
//  row that says so, and a page that spells out what goes and what stays before the one button
//  that does it.
//

import Foundation
import Observation

@MainActor
@Observable
final class DeleteProfileViewModel {
    /// Removes the account and its local data. Returns `nil` once the account is gone, or the
    /// message to show when nothing was removed.
    typealias RemoveAccount = @MainActor (AccountItem) async -> String?

    /// What the reader has typed into the confirmation field.
    var confirmation = "" {
        didSet {
            // A new attempt at the gate is a new attempt at the action; the old failure no
            // longer describes what the button will do.
            if confirmation != oldValue { error = nil }
        }
    }
    private(set) var isDeleting = false
    private(set) var error: String?

    @ObservationIgnored private let removeAccount: RemoveAccount?

    init(removeAccount: RemoveAccount?) {
        self.removeAccount = removeAccount
    }

    /// Whether the Delete Profile button is live for an account whose confirmation phrase is
    /// `challenge`. `isAccountMutationInProgress` covers a sign-out or switch started elsewhere.
    func canDelete(challenge: String, isAccountMutationInProgress: Bool) -> Bool {
        removeAccount != nil
            && !isAccountMutationInProgress
            && ProfileDeletionConfirmation.canDelete(input: confirmation, challenge: challenge, busy: isDeleting)
    }

    func showsExtraWhitespaceHint(challenge: String) -> Bool {
        ProfileDeletionConfirmation.hasExtraSurroundingWhitespace(confirmation, challenge: challenge)
    }

    /// Starts a visit to the page from an empty field, the way iOS's pushed page does with its own
    /// `@State`. This model outlives the page — it sits on the account's scope — so without this a
    /// name typed on an earlier visit would still be in the field, the button already armed.
    /// A deletion still running keeps its state: the page is reporting on it.
    func beginVisit() {
        guard !isDeleting else { return }
        confirmation = ""
        error = nil
    }

    /// Runs the removal. Returns whether the account was removed.
    @discardableResult
    func delete(account: AccountItem, challenge: String, isAccountMutationInProgress: Bool) async -> Bool {
        guard let removeAccount,
            canDelete(challenge: challenge, isAccountMutationInProgress: isAccountMutationInProgress)
        else { return false }
        isDeleting = true
        error = nil
        let failure = await removeAccount(account)
        isDeleting = false
        guard let failure else {
            confirmation = ""
            return true
        }
        error = failure.isEmpty ? L10n.string("Couldn't wipe profile") : failure
        return false
    }

    static func preview() -> DeleteProfileViewModel {
        DeleteProfileViewModel(removeAccount: { _ in nil })
    }
}
