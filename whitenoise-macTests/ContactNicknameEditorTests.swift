//
//  ContactNicknameEditorTests.swift
//  whitenoise-macTests
//
//  The Set / Edit Nickname sheet and the two controls that open it: when Save is offered, and
//  which lines each of them draws for a contact with and without a nickname.
//

import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

struct ContactNicknameEditorSaveRuleTests {

    @Test func anUntouchedDraftOffersNoSave() {
        #expect(!ContactNicknameEditorSheet.canSave(draft: "", currentNickname: nil))
        #expect(!ContactNicknameEditorSheet.canSave(draft: "Mum", currentNickname: "Mum"))
    }

    @Test func aNewOrChangedNameCanBeSaved() {
        #expect(ContactNicknameEditorSheet.canSave(draft: "Mum", currentNickname: nil))
        #expect(ContactNicknameEditorSheet.canSave(draft: "Mother", currentNickname: "Mum"))
    }

    /// Emptying the field is how the sheet removes a nickname, so it has to stay saveable.
    @Test func emptyingAnExistingNicknameCanBeSaved() {
        #expect(ContactNicknameEditorSheet.canSave(draft: "", currentNickname: "Mum"))
        #expect(ContactNicknameEditorSheet.canSave(draft: "   ", currentNickname: "Mum"))
    }

    /// Compared as stored: whitespace the sanitizer trims, or a blank draft with nothing to
    /// clear, would write exactly what is already there.
    @Test func editsTheStoreWouldNotSeeOfferNoSave() {
        #expect(!ContactNicknameEditorSheet.canSave(draft: "  Mum  ", currentNickname: "Mum"))
        #expect(!ContactNicknameEditorSheet.canSave(draft: "   ", currentNickname: nil))
    }

    /// Save hands over the draft as stored, never as typed.
    @Test func saveHandsOverTheDraftAsStored() {
        #expect(ContactNicknameEditorSheet.nicknameToStore(draft: "  Mum  ") == "Mum")
        #expect(ContactNicknameEditorSheet.nicknameToStore(draft: "Mum") == "Mum")
    }

    /// An emptied or whitespace-only draft is the remove gesture: Save hands over nil.
    @Test func anEmptiedDraftHandsOverARemoval() {
        #expect(ContactNicknameEditorSheet.nicknameToStore(draft: "") == nil)
        #expect(ContactNicknameEditorSheet.nicknameToStore(draft: " \n\t ") == nil)
    }

    /// Past the length bound the draft is stored truncated, so typing beyond it on an already
    /// full-length nickname changes nothing.
    @Test func charactersPastTheLengthBoundOfferNoSave() {
        let full = String(repeating: "x", count: ContactNicknames.maxLength)
        #expect(!ContactNicknameEditorSheet.canSave(draft: full + "yz", currentNickname: full))
    }
}

/// The profile header hands the editor `profileName`, so Set and Edit both name the contact the
/// way they name themselves, however the recipient was labelled.
struct ContactNicknameEditorProfileNameTests {

    private static func recipient(displayName: String?, publishedDisplayName: String? = nil) -> NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "alice",
            memberRef: "npub1alice",
            accountIdHex: String(repeating: "a", count: 64),
            npub: "npub1alice",
            displayName: displayName,
            publishedDisplayName: publishedDisplayName,
            pictureURL: nil
        )
    }

    /// No nickname: the projections leave `publishedDisplayName` nil, and the published name is
    /// the display name itself.
    @Test func withoutANicknameTheDisplayNameIsTheProfileName() {
        #expect(Self.recipient(displayName: "Alice").profileName == "Alice")
    }

    @Test func aNicknameNeverPassesForTheProfileName() {
        let relabeled = Self.recipient(displayName: "Alice")
            .relabeled(displayName: "Mum", publishedDisplayName: "Alice", displayNameIsPrivate: false)
        #expect(relabeled.profileName == "Alice")
    }

    @Test func aContactWithNoNameAtAllHasNoProfileName() {
        #expect(Self.recipient(displayName: nil).profileName == nil)
    }

    /// With no published name behind it, the nickname is the only label, and it stays private.
    @Test func aNicknameOverNoPublishedNameIsNoProfileName() {
        let relabeled = Self.recipient(displayName: nil)
            .relabeled(displayName: "Mum", publishedDisplayName: nil, displayNameIsPrivate: true)
        #expect(relabeled.title == "Mum")
        #expect(relabeled.profileName == nil)
    }

    /// Every site that builds a nickname-first label decides privacy with the same rule.
    @Test func aNicknameIsPrivateOnlyWithNoPublishedNameBehindIt() {
        #expect(WorkspaceState.nicknameIsPrivate("Mum", over: nil))
        #expect(WorkspaceState.nicknameIsPrivate("Mum", over: "  "))
        #expect(!WorkspaceState.nicknameIsPrivate("Mum", over: "Alice"))
        #expect(!WorkspaceState.nicknameIsPrivate("Alice", over: "Alice"))
        #expect(!WorkspaceState.nicknameIsPrivate(nil, over: nil))
    }
}

/// Measured rather than inspected: the test host builds no accessibility tree, so each extra line
/// or button shows up as extra height or width.
@Suite(.serialized) @MainActor struct ContactNicknameEditorLayoutTests: WorkspaceTestSupport {
    private static let contact = String(repeating: "2", count: 64)

    /// The sheet restates the published name only while a nickname hides it; that line is the
    /// only height difference between Set and Edit.
    @Test func theEditSheetRestatesThePublishedNameAndTheSetSheetDoesNot() {
        let set = Self.size(
            ContactNicknameEditorSheet(currentNickname: nil, publishedName: "Satoshi", onSave: { _ in }))
        let edit = Self.size(
            ContactNicknameEditorSheet(currentNickname: "Sats", publishedName: "Satoshi", onSave: { _ in }))
        let editWithoutPublishedName = Self.size(
            ContactNicknameEditorSheet(currentNickname: "Sats", publishedName: nil, onSave: { _ in }))

        #expect(set.width == 400)
        #expect(edit.height > set.height)
        #expect(editWithoutPublishedName.height == set.height)
    }

    /// Save writes the store while the sheet is still closing, so its caller re-inits it with the
    /// nickname just stored. An open sheet keeps the one it opened with: a Set sheet that grew
    /// Edit's published-name line here would flash it during the dismissal.
    @Test func anOpenSheetKeepsTheNicknameItOpenedWith() {
        let host = NSHostingView(
            rootView: ContactNicknameEditorSheet(currentNickname: nil, publishedName: "Satoshi", onSave: { _ in }))
        host.layoutSubtreeIfNeeded()
        let opened = host.fittingSize

        host.rootView = ContactNicknameEditorSheet(
            currentNickname: "Sats", publishedName: "Satoshi", onSave: { _ in })
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize == opened)
    }

    /// What Save hands over is what `ContactNicknameEditor` writes: a padded draft lands trimmed,
    /// and an emptied one clears the nickname instead of storing an empty label.
    @Test func whatSaveHandsOverLandsInTheStoreAsIs() {
        let state = makeWorkspace()

        state.setContactNickname(
            ContactNicknameEditorSheet.nicknameToStore(draft: "  Mum  "), forContactAccountIdHex: Self.contact)
        #expect(state.contactNickname(forContactAccountIdHex: Self.contact) == "Mum")

        state.setContactNickname(
            ContactNicknameEditorSheet.nicknameToStore(draft: "   "), forContactAccountIdHex: Self.contact)
        #expect(state.contactNickname(forContactAccountIdHex: Self.contact) == nil)
    }

    /// While a nickname is in force the header gains a Remove button beside the pencil.
    @Test func theHeaderOffersRemoveOnlyWhileANicknameIsSet() {
        let state = makeWorkspace()
        let withoutNickname = Self.size(
            ContactNicknameHeaderActions(accountIdHex: Self.contact, publishedName: "Alice"), in: state)

        state.setContactNickname("Mum", forContactAccountIdHex: Self.contact)
        let withNickname = Self.size(
            ContactNicknameHeaderActions(accountIdHex: Self.contact, publishedName: "Alice"), in: state)

        #expect(withoutNickname.width > 0)
        #expect(withNickname.width > withoutNickname.width)
    }

    /// While a nickname is in force the row keeps the published name visible under it.
    @Test func theRowShowsThePublishedNameOnlyWhileANicknameHidesIt() {
        let state = makeWorkspace()
        let withoutNickname = Self.size(
            ContactNicknameRow(accountIdHex: Self.contact, publishedName: "Alice").frame(width: 360), in: state)

        state.setContactNickname("Mum", forContactAccountIdHex: Self.contact)
        let withNickname = Self.size(
            ContactNicknameRow(accountIdHex: Self.contact, publishedName: "Alice").frame(width: 360), in: state)

        #expect(withoutNickname.height > 0)
        #expect(withNickname.height > withoutNickname.height)
    }

    /// One of this device's own accounts keeps its local label, so neither control is offered.
    @Test func ownAccountsGetNoNicknameControls() {
        let state = makeWorkspace()
        let own = desktopAccount().accountIdHex

        let header = Self.size(ContactNicknameHeaderActions(accountIdHex: own), in: state)
        let row = Self.size(ContactNicknameRow(accountIdHex: own, publishedName: nil), in: state)

        #expect(header == .zero)
        #expect(row == .zero)
    }

    // MARK: - Helpers

    private func makeWorkspace() -> WorkspaceState {
        let account = desktopAccount()
        let state = WorkspaceState(
            accounts: [AccountItem(summary: account)],
            clientFactory: { FakeMarmotRuntime(accounts: [account]) }
        )
        state.activeAccountId = account.label
        return state
    }

    private static func size(_ view: some View, in state: WorkspaceState? = nil) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.environment(state ?? WorkspaceState.preview())))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
