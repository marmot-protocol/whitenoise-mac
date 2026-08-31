//
//  WorkspaceState+ImprovementsPrompt.swift
//  whitenoise-mac
//
//  The one-time "Help Improve White Noise" choice, offered once per identity right after it first
//  reaches Chats.
//
//  Both toggles it presents are the Privacy & Security ones — `setRelayTelemetryEnabled` and
//  `setAuditLoggingEnabled` — so there is nothing to commit when the sheet closes and no third
//  state to keep in step. What lives here is only *when to ask*.
//

import Foundation

extension WorkspaceState {
    /// Offer the choice to the active identity, unless it has been offered before.
    ///
    /// Called from every path that takes a *newly entered* identity into Chats, once
    /// `activateReadyState()` has returned — the first moment Chats is on screen behind it. The
    /// prototype presents this over Chats, not as a step inside the onboarding panes, precisely so
    /// the account is already usable if it is dismissed without a decision.
    ///
    /// Those paths are `completeSignUp()` and `cancelSignUp()` (the sign-up pane's two exits once
    /// an identity exists), `login()`, and `signUp()`. The sign-up pane calls `completeSignUp()`,
    /// **not** `signUp()` — `signUp()` has no caller in the app at all and survives only in tests,
    /// so hooking it alone left the prompt unreachable for every real sign-up.
    ///
    /// `bootstrap()` reaches `activateReadyState()` too and is deliberately *not* hooked: it
    /// restores an existing session at launch, which is not a first entry.
    ///
    /// `enteredAccountIdHex` is the identity that entered the session, read *before*
    /// `activateReadyState()` — see the switch note below for why it cannot be read here.
    func presentImprovementsPromptIfNeeded(forEnteredAccountIdHex enteredAccountIdHex: String?) {
        guard case .ready = phase, let activeAccount else { return }
        let accountIdHex = activeAccount.accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        // An identity with no hex cannot be recorded as asked, so asking it would repeat forever.
        guard !accountIdHex.isEmpty else { return }

        // `activateReadyState()` sets `phase` to `.ready` before the rest of its own awaits, so
        // Chats — and the account switcher on Settings — is on screen for the remainder of that
        // call. `selectAccountFromSettings` commits `activeAccountId` synchronously and takes no
        // authentication guard, so a switch landing in that window leaves a *different* identity
        // active by the time this runs. Asking whoever is active now would spend that account's one
        // lifetime offer on a moment that is not its first entry, and the identity that actually
        // just signed in would never be asked at all.
        //
        // Dropped rather than deferred: the offer is "right after this identity first reaches
        // Chats", and once the user has moved on that moment has passed. Not asking is the
        // recoverable half — Settings → Privacy & Security carries both switches — while a
        // wrongly-spent record is not.
        guard let enteredAccountIdHex,
            enteredAccountIdHex.trimmingCharacters(in: .whitespacesAndNewlines) == accountIdHex
        else { return }

        guard !improvementsPromptStore.hasBeenOffered(toOwnerAccountIdHex: accountIdHex) else { return }

        // Recorded when it goes up rather than when it comes down. Dismissal is a valid answer
        // ("leave both off"), and the sheet is only ever reached from a fresh sign-up or sign-in —
        // so a quit with it still open would otherwise mean the identity is asked again on a path
        // it can no longer take, or never asked at all.
        improvementsPromptStore.markOffered(toOwnerAccountIdHex: accountIdHex)
        isImprovementsPromptPresented = true
    }

    /// Close the prompt. Both toggles wrote through as they were flipped, so there is nothing else
    /// to do here.
    func dismissImprovementsPrompt() {
        isImprovementsPromptPresented = false
    }

    /// Drop the record for a removed identity, so a later sign-in with the same key is asked again
    /// rather than inheriting an answer it can no longer see.
    func forgetImprovementsPrompt(forOwnerAccountIdHex accountIdHex: String) {
        improvementsPromptStore.forget(ownerAccountIdHex: accountIdHex)
    }

    /// Part of "Erase App Data": a Mac reset to a newly installed state has asked nobody.
    func clearImprovementsPromptRecords() {
        isImprovementsPromptPresented = false
        improvementsPromptStore.clearAll()
    }
}
