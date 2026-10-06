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

    /// Past the length bound the draft is stored truncated, so typing beyond it on an already
    /// full-length nickname changes nothing.
    @Test func charactersPastTheLengthBoundOfferNoSave() {
        let full = String(repeating: "x", count: ContactNicknames.maxLength)
        #expect(!ContactNicknameEditorSheet.canSave(draft: full + "yz", currentNickname: full))
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
