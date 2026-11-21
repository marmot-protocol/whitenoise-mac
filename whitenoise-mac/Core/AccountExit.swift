//
//  AccountExit.swift
//  whitenoise-mac
//
//  The app's side of an account leaving: what the shell does once MDK has signed it out. Moved out
//  of `WorkspaceState.signOutAccount` so that MDK's own sign-out (another device unlinked this Mac)
//  takes the same steps without going through the user's account-change gate.
//

import Foundation
import MarmotKit

@MainActor
enum AccountExit {
    /// Moves the app off an account MDK signed out by itself, because another of its devices
    /// unlinked this Mac: drops its chats and drafts and, if it was the profile on screen, leaves
    /// it as Sign Out does.
    ///
    /// Not gated by `isAccountMutationInProgress`, and doesn't set it. That gate stops a second
    /// change the user asked for and drops it silently, which is right for a double click and
    /// wrong here: MDK has already signed the account out, so the app has to follow whatever else
    /// is running. A change in flight decides its own recovery from the state after its awaits.
    ///
    /// A change already in flight may have read the account list before MDK signed this account
    /// out. `AccountRoster` installs reads in order, so this one's read lands after that one, and
    /// every recovery decides from the installed list rather than from its own read.
    static func leaveSignedOutAccount(accountIdHex: String, in workspace: WorkspaceState) async {
        guard let client = workspace.client,
            let account = workspace.accounts.first(where: { $0.accountIdHex.lowercased() == accountIdHex })
        else { return }
        let wasActive = workspace.activeAccountId == account.id
        let selectedGroupId = wasActive ? workspace.selectedChat?.id : nil
        // MDK has signed it out already, so the app follows even if the next read fails. The event
        // fires once; restoring the old session on a failed read would leave its chats showing.
        workspace.accountRoster.markSignedOut(accountId: account.id)
        // Off screen before the first await: its chats and transcript go now, and nothing captured
        // here can later stop the work of a profile the user switches to meanwhile. Recovery after
        // the reload picks what to show next.
        workspace.removeChats(forAccountId: account.id)
        if wasActive {
            workspace.stopTimelineListener()
            workspace.cancelTimelineLoad()
            workspace.cancelChatListReload()
            workspace.stopChatListListener()
            workspace.resetActiveAccountUIState()
            workspace.activeAccountId = nil
        }
        do {
            await workspace.flushComposerDraftPersistence(forAccountId: account.id)
            try await finishSigningOut(
                accountId: account.id, in: workspace, client: client, keepingListIfReadFails: true)
        } catch {
            if wasActive, workspace.activeAccountId == account.id {
                await workspace.restoreReadySessionAfterInterruptedMutation(selectedGroupId: selectedGroupId)
            }
            workspace.lastError = UserFacingError.message(for: error)
        }
    }

    /// Deletes an account another device unlinked, once nothing else is changing accounts.
    ///
    /// The alert's Delete Everything can be pressed while another account change runs, and
    /// `removeAccount` drops a call that arrives then. So this waits for the gate to open and
    /// calls it in the same main-actor step, against the account as it stands then. Returns the
    /// wipe outcome to report, which is nil for an account already signed out.
    static func removeUnlinkedAccount(accountIdHex: String, in workspace: WorkspaceState) async -> WipeOutcomeFfi? {
        await untilNoAccountChange(in: workspace)
        guard let account = workspace.accounts.first(where: { $0.accountIdHex.lowercased() == accountIdHex })
        else { return nil }
        return await workspace.removeAccount(account)
    }

    /// The steps after MDK's sign-out, shared by Sign Out and `leaveSignedOutAccount`.
    /// `keepingListIfReadFails` carries on with the installed list when the reload fails, for an
    /// account the list already shows signed out; the failure is still reported.
    static func finishSigningOut(
        accountId: String, in workspace: WorkspaceState, client: any MarmotRuntime,
        keepingListIfReadFails: Bool = false
    ) async throws {
        workspace.clearComposerDrafts(forAccountId: accountId)
        workspace.clearMediaReferenceResolutionCache(forAccountId: accountId)
        do {
            try await workspace.accountRoster.reload(from: client)
        } catch  where keepingListIfReadFails && !(error is CancellationError) {
            workspace.lastError = UserFacingError.message(for: error)
        }
        workspace.removeChats(forAccountId: accountId)

        // `activeAccountId` may have changed during the awaits above — e.g. the user
        // selected another account while this sign-out was in flight (account switching
        // is not gated by `isSigningOutAccount`). Decide recovery from post-await state,
        // not the pre-await `wasActive` snapshot: if a still-signed-in account is active
        // (an untouched background account, or the one the user just raced to), leave its
        // freshly loaded session intact rather than tearing it down and reselecting.
        let currentActiveAccount = workspace.activeAccountId.flatMap { id in
            workspace.accounts.first { $0.id == id && !$0.signedOut }
        }
        guard currentActiveAccount == nil else { return }

        workspace.resetActiveAccountUIState()
        let signedInAccounts = workspace.signedInAccounts
        if signedInAccounts.count == 1, let remaining = signedInAccounts.first {
            // Exactly one profile left: a chooser with a single row is no choice, so continue
            // straight into it, still on the settings page the sign-out left — as deleting
            // the active profile does (`removeAccount`).
            workspace.switchActiveAccount(remaining, finalSelection: workspace.settingsSelectionAfterAccountMutation)
            await workspace.configureObservabilityRuntimeBestEffort()
            await workspace.loadSettingsData()
        } else if !signedInAccounts.isEmpty {
            // Signing out of the profile the user was in, with two or more others still
            // signed in, asks which one to continue with — exactly as deleting it does
            // (`removeAccount`) — rather than silently moving into whichever identity
            // `accounts` lists first. Settings stays selected behind `ProfileChooserView`, so
            // the pick lands back on Settings.
            workspace.activeAccountId = nil
            workspace.invalidateNotificationSettingsOperations()
            UserDefaults.standard.removeObject(forKey: WorkspaceState.activeAccountKey)
            workspace.notificationSettings = .defaults
            workspace.selection = workspace.settingsSelectionAfterAccountMutation
        } else {
            // Signing out the last identity is a way out of the app, so it lands where a
            // first launch does. It used to stay in `.ready` with no active account, which
            // drew a list of this Mac's deactivated identities offering to reactivate one
            // with a click — undoing the sign-out that had just been confirmed. Coming back
            // is Sign In or Sign Up now; the core reactivates a matching signed-out account
            // on login, so this identity's chats are still waiting behind its key.
            workspace.activeAccountId = nil
            workspace.invalidateNotificationSettingsOperations()
            UserDefaults.standard.removeObject(forKey: WorkspaceState.activeAccountKey)
            workspace.selection = nil
            workspace.authenticationMode = .landing
            workspace.clearEnteredLoginIdentity()
            workspace.phase = .onboarding
            workspace.notificationSettings = .defaults
        }
    }

    /// Returns once no account change holds `isAccountMutationInProgress`. The caller acts in the
    /// same main-actor step, so nothing can take the gate in between.
    private static func untilNoAccountChange(in workspace: WorkspaceState) async {
        while workspace.isAccountMutationInProgress {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = workspace.isAccountMutationInProgress
                } onChange: {
                    resume.resume()
                }
            }
        }
    }
}
