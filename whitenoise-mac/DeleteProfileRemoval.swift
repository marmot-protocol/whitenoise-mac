//
//  DeleteProfileRemoval.swift
//  whitenoise-mac
//
//  The shell's half of Settings → Delete Profile: the remover handed to the page's model. It lives
//  beside the `App` rather than inside it so the outcome it reports can be tested.
//

import Foundation

@MainActor
enum DeleteProfileRemoval {
    /// Runs the removal through the workspace, which owns the teardown, and hands its failure to
    /// the page's model rather than leaving it on the shared `lastError`, where the page's scaffold
    /// would draw it a second time.
    static func remover(for workspace: WorkspaceState) -> DeleteProfileViewModel.RemoveAccount {
        { [weak workspace] account in
            guard let workspace else { return "" }
            await workspace.removeAccount(account)
            // Once the account is gone the removal succeeded, and anything on `lastError` came
            // from what ran after it — the next account's settings load — so it stays for that
            // account's page instead of being reported here as a failed deletion.
            guard workspace.accounts.contains(where: { $0.id == account.id }) else { return nil }
            let failure = workspace.lastError
            workspace.lastError = nil
            // `removeAccount` returns without a word when another account change holds the gate;
            // the account still being here is the only sign nothing ran.
            return failure ?? ""
        }
    }
}
