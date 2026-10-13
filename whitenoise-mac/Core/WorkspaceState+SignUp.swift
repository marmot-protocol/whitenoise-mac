//
//  WorkspaceState+SignUp.swift
//  whitenoise-mac
//
//  Creating an identity and giving it a face, in that order, from one button.
//

import Foundation
import MarmotKit

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
        let hasCreatedIdentity = signUpCreatedAccountRef != nil
        signUpDraft = SignUpDraft()
        signUpCreatedAccountRef = nil
        lastError = nil
        authenticationMode = .landing

        if hasCreatedIdentity {
            // Read before `activateReadyState()` — see
            // `presentImprovementsPromptIfNeeded(forEnteredAccountIdHex:)` for the switch window.
            let enteredAccountIdHex = activeAccount?.accountIdHex
            await activateReadyState()
            presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: enteredAccountIdHex)
        }
    }

    // MARK: - The photo

    func showSignUpImagePicker() {
        guard authenticationMode == .signUp, !isAuthenticating else { return }
        presentProfileImagePicker(destination: .signUpDraft)
    }

    // MARK: - Committing

    /// Create the durable identity with the typed name and about as its first profile, upload the
    /// staged photo under it, publish once more only if needed, and go in.
    ///
    /// `createIdentityWithInitialProfile` (MarmotKit 0.13) makes the chosen name the account's
    /// first kind 0, so contacts never see the key-derived default that a create-then-publish
    /// sign-up exposed first. A second publish happens only when the profile still has to change:
    /// a photo was staged (a Blossom upload is signed by the account key, so the picture cannot
    /// become a URL before the identity exists), MDK resumed a setup that ignored the supplied
    /// profile, or this is a retry after the identity was already created.
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

        let requestedProfile = ProfileDraft(
            displayName: signUpDraft.trimmedDisplayName,
            about: signUpDraft.trimmedAbout
        )

        do {
            // The profile identity creation published, when it is exactly what the user typed.
            var publishedInitialProfile: UserProfileMetadataFfi?
            // The minted identity still to bring online: just created, or left behind by an attempt
            // whose `start()` or account refresh threw after `signUpCreatedAccountRef` was set.
            var accountToBringOnline: AccountSummaryFfi?
            if signUpCreatedAccountRef == nil {
                let existingAccountLabels = Set(accounts.map(\.accountRef))
                let creation = try await client.createIdentityWithInitialProfile(
                    profile: requestedProfile.metadata,
                    defaultRelays: MarmotClient.accountRelays,
                    bootstrapRelays: MarmotClient.seedRelays,
                    inboxRelays: MarmotClient.seedRelays
                )
                // MDK coalesces a retry while secure setup is still publishing. Treat a returned
                // pre-existing label as recovery, not as a newly-created editable identity.
                guard !existingAccountLabels.contains(creation.account.label) else {
                    throw MarmotKitError.AccountSetupRetryRequired
                }
                // Recorded before the two calls that can still throw, not after: a `start()` or an
                // account refresh that fails leaves an identity on disk either way, and a retry
                // that had not recorded it would mint a second one and abandon the first.
                signUpCreatedAccountRef = AccountItem(summary: creation.account).accountRef
                // MDK returns the profile its setup stamped; a resumed setup ignores the one
                // supplied, so only the fields sign-up sets decide whether it was kept.
                if creation.profile.displayName == requestedProfile.metadata.displayName,
                    creation.profile.about == requestedProfile.metadata.about
                {
                    publishedInitialProfile = creation.profile
                }
                accountToBringOnline = creation.account
            } else if let createdAccountRef = signUpCreatedAccountRef, activeAccount?.accountRef != createdAccountRef {
                accountToBringOnline = try await FFIExecutor.run { try client.listAccounts() }
                    .first { AccountItem(summary: $0).accountRef == createdAccountRef }
            }
            if let accountToBringOnline {
                // Same ordering rule as `signUp()` / `login()`: wait until `start()` succeeds so a
                // failure leaves the previously ready account intact (#333).
                try await bringRuntimeOnline(client)
                try await refreshAccounts(preferred: accountToBringOnline)
            }

            guard let account = activeAccount, let accountRef = signUpCreatedAccountRef else {
                lastError = L10n.string("Couldn't publish profile")
                return
            }

            let published: UserProfileMetadataFfi
            if let publishedInitialProfile, signUpDraft.image == nil {
                published = publishedInitialProfile
            } else {
                // Built here rather than by mutating `profileDraft`, so a failed publish leaves the
                // settings page's own draft untouched — it is loaded from the core on first visit
                // and has no business carrying half of an abandoned sign-up.
                var draft = requestedProfile
                if let image = signUpDraft.image {
                    draft.picture = try await client.uploadProfileImage(
                        accountRef: accountRef,
                        data: image.data,
                        mediaType: image.mediaType,
                        blossomServer: nil
                    )
                    // The staged bytes have been drawing the sign-up avatar all along; keep them
                    // drawing it once the account rail switches to the published URL.
                    primeUploadedProfileImage(url: draft.picture, data: image.data)
                }
                published = try await client.publishUserProfile(
                    accountRef: accountRef,
                    profile: draft.metadata,
                    defaultRelays: relaySettings.publishRelays,
                    bootstrapRelays: relaySettings.networkBootstrapRelays
                )
            }

            profileDraft = ProfileDraft(profile: published, fallbackName: account.displayName)
            // What sign-up just published is the baseline Settings → Profile compares against, so
            // the page opens without Cancel and Save over a form the user has not touched yet.
            publishedProfile = profileDraft
            updateActiveAccountProfile(
                displayName: profileDraft.primaryDisplayName(fallback: account.displayName),
                pictureURL: profileDraft.picture
            )

            signUpDraft = SignUpDraft()
            signUpCreatedAccountRef = nil
            authenticationMode = .landing
            // Read before `activateReadyState()` — see
            // `presentImprovementsPromptIfNeeded(forEnteredAccountIdHex:)` for the switch window.
            let enteredAccountIdHex = activeAccount?.accountIdHex
            await activateReadyState()
            presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: enteredAccountIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
