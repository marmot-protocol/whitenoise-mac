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
    static func remover(
        for workspace: WorkspaceState,
        session: SessionState? = nil
    ) -> DeleteProfileViewModel.RemoveAccount {
        { [weak workspace, weak session] account in
            guard let workspace else { return "" }
            // Keep errors off both `workspace.lastError` and Settings' shared error channel:
            // Delete Profile displays its own failure inline, and a racing switch to another
            // profile must never let this removal read or clear the new profile's Settings error.
            let result = await workspace.removeAccountResult(account, errorTarget: .none)
            session?.reportWipe(result.outcome)
            // Once the account is gone the removal succeeded, and anything on Settings' error
            // channel came from what ran after it — the next account's settings load — so it stays
            // for that account's page instead of being reported here as a failed deletion.
            guard workspace.accounts.contains(where: { $0.id == account.id }) else { return nil }
            // `removeAccountResult` returns without an error when another account change holds the
            // gate; the account still being here is the only sign nothing ran.
            return result.errorMessage ?? ""
        }
    }
}
