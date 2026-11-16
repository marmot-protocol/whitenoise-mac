//
//  WorkspaceState+ImprovementsPrompt.swift
//  whitenoise-mac
//
//  The one-time "Help Improve White Noise" choice, offered over Chats the first time an identity
//  reaches it on a Mac whose diagnostics choice has never been made.
//
//  The choice is device-wide — MarmotKit keeps one usage consent receipt for every account on this
//  Mac — so it is asked once per Mac, not once per identity. Signing up a second account must not
//  ask a question the first one already answered. As on iOS, MarmotKit's receipt is the only
//  record: `decision == .acceptanceRequired` means nobody has answered yet (or the policy changed
//  since), and closing the sheet writes a decline through `DiagnosticsSettingsViewModel
//  .finishPrompt()` so the receipt stops being pending. What lives here is only *when to ask*.
//

import Foundation
import MarmotKit

extension WorkspaceState {
    /// Offer the choice, unless this Mac has already answered it.
    ///
    /// Called from every path that takes a *newly entered* identity into Chats, once
    /// `activateReadyState()` has returned — the first moment Chats is on screen behind it. The
    /// prototype presents this over Chats, not as a step inside the onboarding panes, precisely so
    /// the account is already usable if it is dismissed without a decision.
    ///
    /// Those paths are `completeSignUp()` and `cancelSignUp()` (the sign-up pane's two exits once
    /// an identity exists), `login()`, `signUp()`, and the shell's leave-onboarding task.
    ///
    /// `bootstrap()` reaches `activateReadyState()` too and is deliberately *not* hooked: it
    /// restores an existing session at launch, which is not a first entry.
    ///
    /// `enteredAccountIdHex` is the identity that entered the session, read *before*
    /// `activateReadyState()` — see the switch note below for why it cannot be read here.
    func presentImprovementsPromptIfNeeded(forEnteredAccountIdHex enteredAccountIdHex: String?) async {
        guard isEnteredIdentityStillActive(enteredAccountIdHex), let client else { return }

        // An unreadable receipt is not a pending one: asking anyway could repeat the prompt on
        // every sign-in, while not asking is recoverable — Privacy & Security carries both switches.
        let settings = try? await FFIExecutor.run { try client.usageDiagnosticsSettings() }
        guard settings?.decision == .acceptanceRequired else { return }

        // The read crossed an await, so the identity guard is taken again on the far side of it.
        guard isEnteredIdentityStillActive(enteredAccountIdHex) else { return }
        isImprovementsPromptPresented = true
    }

    /// `activateReadyState()` sets `phase` to `.ready` before the rest of its own awaits, so
    /// Chats — and the account switcher on Settings — is on screen for the remainder of that call.
    /// A switch landing in that window leaves a *different* identity active by the time the prompt
    /// would go up, and that moment is not anybody's first entry. Dropped rather than deferred:
    /// once the user has moved on, the moment has passed, and the next first entry asks again
    /// because the receipt is still pending.
    private func isEnteredIdentityStillActive(_ enteredAccountIdHex: String?) -> Bool {
        guard case .ready = phase, let activeAccount else { return false }
        let accountIdHex = activeAccount.accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountIdHex.isEmpty, let enteredAccountIdHex else { return false }
        return enteredAccountIdHex.trimmingCharacters(in: .whitespacesAndNewlines) == accountIdHex
    }

    /// Close the prompt. The toggles wrote through as they were flipped, and the sheet has already
    /// recorded a decline if nothing was chosen, so there is nothing else to do here.
    func dismissImprovementsPrompt() {
        isImprovementsPromptPresented = false
    }
}
