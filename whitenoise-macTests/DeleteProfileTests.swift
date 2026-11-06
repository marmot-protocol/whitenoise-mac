//
//  DeleteProfileTests.swift
//  whitenoise-macTests
//
//  Settings → Delete Profile: the typed gate, the page's model, and where the page sits in
//  the settings navigation.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@Suite
struct ProfileDeletionConfirmationTests {
    @Test func onlyTheExactPhraseClearsTheGate() {
        #expect(ProfileDeletionConfirmation.canDelete(input: "Jeff", challenge: "Jeff", busy: false))
        // Stricter than the sign-out sheet's wipe gate, as on iOS: case and spacing count.
        #expect(!ProfileDeletionConfirmation.canDelete(input: "jeff", challenge: "Jeff", busy: false))
        #expect(!ProfileDeletionConfirmation.canDelete(input: " Jeff ", challenge: "Jeff", busy: false))
        #expect(!ProfileDeletionConfirmation.canDelete(input: "", challenge: "Jeff", busy: false))
    }

    @Test func nothingClearsAnEmptyChallengeOrABusyGate() {
        #expect(!ProfileDeletionConfirmation.canDelete(input: "", challenge: "", busy: false))
        #expect(!ProfileDeletionConfirmation.canDelete(input: "Jeff", challenge: "Jeff", busy: true))
    }

    @Test func surroundingWhitespaceGetsAHintInsteadOfSilence() {
        #expect(ProfileDeletionConfirmation.hasExtraSurroundingWhitespace(" Jeff", challenge: "Jeff"))
        #expect(ProfileDeletionConfirmation.hasExtraSurroundingWhitespace("Jeff\n", challenge: "Jeff"))
        #expect(!ProfileDeletionConfirmation.hasExtraSurroundingWhitespace("Jeff", challenge: "Jeff"))
        #expect(!ProfileDeletionConfirmation.hasExtraSurroundingWhitespace(" Jef", challenge: "Jeff"))
        #expect(!ProfileDeletionConfirmation.hasExtraSurroundingWhitespace(" ", challenge: ""))
    }
}

@Suite
@MainActor
struct DeleteProfileViewModelTests {
    private let account = AccountItem.samples[0]

    @Test func theButtonWaitsForTheTypedName() {
        let model = DeleteProfileViewModel(removeAccount: { _ in nil })
        #expect(!model.canDelete(challenge: "Jeff", isAccountMutationInProgress: false))

        model.confirmation = "Jeff"
        #expect(model.canDelete(challenge: "Jeff", isAccountMutationInProgress: false))
        // A sign-out or switch already running elsewhere holds the button too.
        #expect(!model.canDelete(challenge: "Jeff", isAccountMutationInProgress: true))
    }

    @Test func withoutARemoverTheButtonNeverArms() {
        let model = DeleteProfileViewModel(removeAccount: nil)
        model.confirmation = "Jeff"
        #expect(!model.canDelete(challenge: "Jeff", isAccountMutationInProgress: false))
    }

    @Test func aSuccessfulDeletionRemovesThatAccountOnce() async {
        var removed: [String] = []
        let model = DeleteProfileViewModel(removeAccount: { account in
            removed.append(account.id)
            return nil
        })
        model.confirmation = "Jeff"

        let didDelete = await model.delete(account: account, challenge: "Jeff", isAccountMutationInProgress: false)

        #expect(didDelete)
        #expect(removed == [account.id])
        #expect(!model.isDeleting)
        #expect(model.error == nil)
        #expect(model.confirmation.isEmpty)
    }

    @Test func anUnconfirmedDeletionNeverReachesTheRemover() async {
        var calls = 0
        let model = DeleteProfileViewModel(removeAccount: { _ in
            calls += 1
            return nil
        })
        model.confirmation = "jeff"

        let didDelete = await model.delete(account: account, challenge: "Jeff", isAccountMutationInProgress: false)

        #expect(!didDelete)
        #expect(calls == 0)
    }

    @Test func aFailureStaysOnThePageAndClearsOnTheNextEdit() async {
        let model = DeleteProfileViewModel(removeAccount: { _ in "The relay refused." })
        model.confirmation = "Jeff"

        let didDelete = await model.delete(account: account, challenge: "Jeff", isAccountMutationInProgress: false)

        #expect(!didDelete)
        #expect(model.error == "The relay refused.")
        #expect(!model.isDeleting)
        // The typed name survives a failure, so a retry is one click.
        #expect(model.confirmation == "Jeff")

        model.confirmation = "Jef"
        #expect(model.error == nil)
    }

    @Test func aSilentFailureStillSaysSomething() async {
        let model = DeleteProfileViewModel(removeAccount: { _ in "" })
        model.confirmation = "Jeff"

        await model.delete(account: account, challenge: "Jeff", isAccountMutationInProgress: false)

        #expect(model.error == L10n.string("Couldn't wipe profile"))
    }

    @Test func theWhitespaceHintFollowsTheTypedText() {
        let model = DeleteProfileViewModel(removeAccount: { _ in nil })
        model.confirmation = "Jeff "
        #expect(model.showsExtraWhitespaceHint(challenge: "Jeff"))
        #expect(!model.canDelete(challenge: "Jeff", isAccountMutationInProgress: false))
    }

    @Test func theConfirmationHintNamesThePhrase() {
        let hint = String(DeleteProfileConfirmationHint.text(challenge: "Jeff").characters)
        #expect(hint == String(format: L10n.string("Type %@ to confirm."), "Jeff"))
    }
}

@Suite
struct DeleteProfileSettingsPageTests {
    /// Reached from the drawer's destructive card, beside Sign Out — not from either page group.
    @Test func deleteProfileIsADestinationOutsideThePageGroups() {
        #expect(!SettingsPage.sidebarPages.contains(.deleteProfile))
        #expect(SettingsPage.deleteProfile.drawerPage == .deleteProfile)
    }

    /// The page is about one profile, so a change of identity must never land on it.
    @Test func onlyDeleteProfileIsLeftWhenTheActiveAccountChanges() {
        #expect(SettingsPage.deleteProfile.pageAfterActiveAccountChange == .overview)
        for page in SettingsPage.sidebarPages + [.overview, .keyPackages, .manageStorage] {
            #expect(page.pageAfterActiveAccountChange == page)
        }
    }

    @Test func theSixConsequencesAreDistinct() {
        #expect(DeleteProfileConsequence.all.count == 6)
        #expect(Set(DeleteProfileConsequence.all.map(\.id)).count == 6)
    }
}

/// The remover the shell hands the page's model: what it reports once the workspace's removal has
/// run, read off the account list and `lastError` the removal leaves behind.
@Suite
@MainActor
struct DeleteProfileRemovalTests: WorkspaceTestSupport {
    private struct RelayListReadFailed: LocalizedError {
        var errorDescription: String? { "Relay lists could not be read." }
    }

    private struct RemovalRefused: LocalizedError {
        var errorDescription: String? { "The account could not be removed." }
    }

    private static let backup = AccountSummaryFfi(
        label: "Backup Account",
        accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: true
    )

    /// A workspace signed in to the desktop account and a backup, with the desktop one active.
    private func signedInWorkspace(_ runtime: FakeMarmotRuntime) async throws -> (WorkspaceState, AccountItem) {
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let active = try #require(state.activeAccount)
        try #require(active.id == "Desktop Account")
        return (state, active)
    }

    /// The deletion went through and the app moved on to the backup identity, whose settings then
    /// failed to load. That failure is the backup's, not the deletion's: the page reports success,
    /// and the error stays where the backup's settings page will show it.
    @Test func aFailedLoadForTheNextAccountIsNotAFailedDeletion() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let runtime = FakeMarmotRuntime(accounts: [desktopAccount(), Self.backup])
        runtime.accountRelayListsErrorByAccountRef = ["Backup Account": RelayListReadFailed()]
        let (state, active) = try await signedInWorkspace(runtime)

        let failure = await DeleteProfileRemoval.remover(for: state)(active)

        #expect(failure == nil)
        #expect(runtime.removedAccountRefs == ["Desktop Account"])
        #expect(!state.accounts.contains(where: { $0.id == "Desktop Account" }))
        #expect(state.activeAccountId == "Backup Account")
        #expect(state.lastError == RelayListReadFailed().errorDescription)
    }

    /// The core refused and the account is still here: the page is told why, and the message moves
    /// off `lastError` so the page's scaffold does not draw it a second time.
    @Test func aRefusedRemovalIsReportedToThePageOnly() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let runtime = FakeMarmotRuntime(accounts: [desktopAccount(), Self.backup])
        runtime.removeAccountError = RemovalRefused()
        let (state, active) = try await signedInWorkspace(runtime)

        let failure = await DeleteProfileRemoval.remover(for: state)(active)

        #expect(failure == RemovalRefused().errorDescription)
        #expect(state.accounts.contains(where: { $0.id == "Desktop Account" }))
        #expect(state.lastError == nil)
    }

    /// Another account change holds the gate, so nothing ran and nothing said why. The page still
    /// hears that the deletion did not happen, rather than that it did.
    @Test func aHeldGateIsASilentFailureNotASuccess() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let runtime = FakeMarmotRuntime(accounts: [desktopAccount(), Self.backup])
        let (state, active) = try await signedInWorkspace(runtime)
        state.isSigningOutAccount = true

        let failure = await DeleteProfileRemoval.remover(for: state)(active)

        #expect(failure == "")
        #expect(runtime.removedAccountRefs.isEmpty)
        #expect(state.accounts.contains(where: { $0.id == "Desktop Account" }))
    }
}
