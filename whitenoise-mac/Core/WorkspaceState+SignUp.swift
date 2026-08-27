//
//  WorkspaceState+SignUp.swift
//  whitenoise-mac
//
//  Creating an identity and giving it a face, in that order, from one button.
//

import Foundation

@MainActor
extension WorkspaceState {
    // MARK: - Entering and leaving the pane

    /// Open the sign-up pane. Creates nothing: see `completeSignUp()`.
    func showSignUp() {
        guard !isAuthenticating else { return }
        signUpDraft = SignUpDraft()
        signUpCreatedAccountRef = nil
        lastError = nil
        authenticationMode = .signUp
    }

    /// Leave the sign-up pane, wherever that turns out to be.
    ///
    /// The back control means "leave this screen", and where that lands depends on whether
    /// `completeSignUp()` got as far as minting the identity before it failed:
    ///
    /// * **Nothing created yet** — the common case, and the prototype's nav-back: return to the
    ///   landing pane with the draft discarded.
    /// * **The identity exists** — a publish or upload failed and the user would rather get on
    ///   with it than keep retrying. Going "back" to a landing pane offering to create an account
    ///   would be a lie, so this goes *forward* into the app with the profile left unpublished.
    ///   It is exactly the state a pre-#808 sign-up left behind, and Settings → Profile is where
    ///   the rest of it gets filled in.
    func cancelSignUp() async {
        guard !isAuthenticating else { return }
        let createdAccountRef = signUpCreatedAccountRef
        signUpDraft = SignUpDraft()
        signUpCreatedAccountRef = nil
        lastError = nil
        authenticationMode = .landing

        if let createdAccountRef {
            // Read before `activateReadyState()` — see
            // `presentImprovementsPromptIfNeeded(forEnteredAccountIdHex:)` for the switch window.
            let entered = enteredIdentity(forCreatedAccountRef: createdAccountRef)
            await activateReadyState()
            presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: entered)
        }
    }

    /// The identity to offer the improvements prompt to on the way out of the sign-up pane, or
    /// `nil` when the identity sign-up created is not the one that ended up active.
    ///
    /// `completeSignUp()` records `signUpCreatedAccountRef` *before* `start()` and the account
    /// refresh, so that a retry resumes instead of minting a second identity. Either of those can
    /// still fail, and both are ordered to leave the previously ready account active when they do
    /// (#333) — so the new identity can exist on disk while a different account is still the active
    /// one. Both exits from the pane then go into the app as *that* account, and this pane is also
    /// Settings → Add Account, so that account is routinely a real, long-signed-in one.
    ///
    /// Offering to it would spend its one lifetime offer on a moment that is not its first entry
    /// and record it as asked for good, while the identity that was just created — not active, not
    /// even started — would never be asked at all. `presentImprovementsPromptIfNeeded` cannot catch
    /// this on its own: its guard compares the identity that entered against whoever is active now,
    /// and here those are the same wrong account.
    private func enteredIdentity(forCreatedAccountRef createdAccountRef: String) -> String? {
        guard let activeAccount, activeAccount.accountRef == createdAccountRef else { return nil }
        return activeAccount.accountIdHex
    }

    // MARK: - The photo

    func showSignUpImagePicker() {
        guard authenticationMode == .signUp, !isAuthenticating else { return }
        presentProfileImagePicker(destination: .signUpDraft)
    }

    // MARK: - Committing

    /// Create the identity, upload the staged photo under it, publish the profile, and go in.
    ///
    /// The order is `whitenoise`'s (`use_signup.dart`), and it is forced: a Blossom upload is
    /// signed by an account key, so the picture cannot become a URL before the identity exists,
    /// and the profile event cannot be published before the picture has a URL to carry.
    ///
    /// Every failure keeps the pane up with `lastError` under the fields, and the button retries.
    /// What makes a retry safe is `signUpCreatedAccountRef`: without it the second press would
    /// mint a second identity and abandon the first, which is the one sharp edge the Flutter
    /// implementation still has.
    func completeSignUp() async {
        guard authenticationMode == .signUp, !isAuthenticating else { return }
        guard signUpDraft.isSubmittable else { return }

        lastError = nil
        authenticationActivity = .signUp
        defer { authenticationActivity = nil }

        guard let client = await clientForAuthentication() else { return }

        do {
            if signUpCreatedAccountRef == nil {
                let summary = try await client.createIdentity(
                    defaultRelays: MarmotClient.seedRelays,
                    bootstrapRelays: MarmotClient.seedRelays
                )
                // Recorded before the two calls that can still throw, not after: a `start()` or an
                // account refresh that fails leaves an identity on disk either way, and a retry
                // that had not recorded it would mint a second one and abandon the first.
                signUpCreatedAccountRef = AccountItem(summary: summary).accountRef
                // Same ordering rule as `signUp()` / `login()`: wait until `start()` succeeds so a
                // failure leaves the previously ready account intact (#333).
                try await bringRuntimeOnline(client)
                try await refreshAccounts(preferred: summary)
            }

            guard let account = activeAccount, let accountRef = signUpCreatedAccountRef else {
                lastError = L10n.string("Couldn't publish profile")
                return
            }

            var picture = ""
            if let image = signUpDraft.image {
                picture = try await client.uploadProfileImage(
                    accountRef: accountRef,
                    data: image.data,
                    mediaType: image.mediaType,
                    blossomServer: nil
                )
                // The staged bytes have been drawing the sign-up avatar all along; keep them
                // drawing it once the account rail switches to the published URL.
                primeUploadedProfileImage(url: picture, data: image.data)
            }

            // Built here rather than by mutating `profileDraft`, so a failed publish leaves the
            // settings page's own draft untouched — it is loaded from the core on first visit and
            // has no business carrying half of an abandoned sign-up.
            let draft = ProfileDraft(
                displayName: signUpDraft.trimmedDisplayName,
                about: signUpDraft.trimmedAbout,
                picture: picture
            )
            let published = try await client.publishUserProfile(
                accountRef: accountRef,
                profile: draft.metadata,
                defaultRelays: relaySettings.publishRelays,
                bootstrapRelays: relaySettings.networkBootstrapRelays
            )

            profileDraft = ProfileDraft(profile: published, fallbackName: account.displayName)
            updateActiveAccountProfile(
                displayName: profileDraft.primaryDisplayName(fallback: account.displayName),
                pictureURL: profileDraft.picture
            )

            signUpDraft = SignUpDraft()
            signUpCreatedAccountRef = nil
            authenticationMode = .landing
            // Read before `activateReadyState()` — see
            // `presentImprovementsPromptIfNeeded(forEnteredAccountIdHex:)` for the switch window.
            // `accountRef`-matched because a retry reaches here without ever re-running `start()`
            // or the refresh: see `enteredIdentity(forCreatedAccountRef:)`.
            let entered = enteredIdentity(forCreatedAccountRef: accountRef)
            await activateReadyState()
            presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: entered)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
