//
//  PublicIdentitySheetTests.swift
//  whitenoise-macTests
//
//  The public-identity QR sheet: which address it may caption an identity with, and
//  the order it puts the identity, the code and the caption in.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized)
struct PublicIdentitySheetTests {

    // MARK: - Whose Nostr address the sheet is allowed to show

    private static let account = String(repeating: "a1", count: 32)
    private static let otherAccount = String(repeating: "b2", count: 32)

    @Test func theSheetShowsTheNostrAddressOfTheAccountTheProfileWasLoadedFor() {
        #expect(
            PublicIdentityQRCodeSheet.nostrAddress(
                for: Self.account,
                loadedFor: Self.account,
                nip05: "pepi@whitenoise.chat"
            ) == "pepi@whitenoise.chat"
        )
    }

    /// The defect the id check exists to prevent. `profileDraft` carries one account's metadata at
    /// a time, so reading it unguarded would print the *active* account's address under whichever
    /// identity the sheet was opened for — a wrong claim about who someone is, not a blank field.
    @Test func theSheetShowsNoNostrAddressForAnAccountTheProfileWasNotLoadedFor() {
        #expect(
            PublicIdentityQRCodeSheet.nostrAddress(
                for: Self.otherAccount,
                loadedFor: Self.account,
                nip05: "pepi@whitenoise.chat"
            ) == nil
        )
        #expect(
            PublicIdentityQRCodeSheet.nostrAddress(
                for: Self.account,
                loadedFor: nil,
                nip05: "pepi@whitenoise.chat"
            ) == nil
        )
    }

    /// Most accounts have no NIP-05 at all, and `ProfileDraft` spells that as `""` rather than nil.
    @Test func anAccountWithoutANostrAddressDrawsNoAddressRow() {
        #expect(
            PublicIdentityQRCodeSheet.nostrAddress(
                for: Self.account, loadedFor: Self.account, nip05: "") == nil
        )
        #expect(
            PublicIdentityQRCodeSheet.nostrAddress(
                for: Self.account, loadedFor: Self.account, nip05: "   ") == nil
        )
    }

    // MARK: - What the sheet stacks, and in what order

    /// The identity — avatar, name, Nostr address, npub — above the code, and the caption saying
    /// what the code is for below it.
    ///
    /// That order is `share_profile_screen.dart`'s in the sibling clients, and it is the half of
    /// this sheet nothing rendered can see: SwiftUI exposes neither a view's children nor their
    /// positions. So the sheet is built from this list rather than from a stack whose order is only
    /// legible by reading it.
    @Test func theSheetStacksTheIdentityAboveTheCodeAndTheCaptionBelowIt() throws {
        let withAddress = PublicIdentitySheetLayout.elements(hasNostrAddress: true)

        #expect(withAddress == [.avatar, .displayName, .nostrAddress, .npubCard, .qrCode, .caption])

        let code = try #require(withAddress.firstIndex(of: .qrCode))
        for identityElement in [PublicIdentitySheetElement.avatar, .displayName, .nostrAddress, .npubCard] {
            let index = try #require(withAddress.firstIndex(of: identityElement))
            #expect(index < code, "\(identityElement) fell below the code it identifies")
        }
        #expect(try #require(withAddress.firstIndex(of: .caption)) > code)
    }

    /// Most accounts have no NIP-05, and the row is dropped rather than left blank — the rest of
    /// the order closing up around it.
    @Test func anAccountWithoutANostrAddressLosesThatRowAndKeepsTheOrder() {
        let withoutAddress = PublicIdentitySheetLayout.elements(hasNostrAddress: false)

        #expect(withoutAddress == [.avatar, .displayName, .npubCard, .qrCode, .caption])
        #expect(!withoutAddress.contains(.nostrAddress))
    }

    /// The npub is the alternative to the code, not a second copy of the same claim.
    ///
    /// Both are the account's public key, so a sheet that showed them as unrelated things would be
    /// asking the reader which one to hand over. The npub the card shows is the shortened form of
    /// the value it copies, and the code carries that same key as its payload.
    @MainActor
    @Test func theCodeAndTheNpubCardCarryTheSameKey() throws {
        let npub = "npub1" + String(repeating: "q", count: 58)

        let shortened = DisplayText.short(npub, head: 14, tail: 4)
        #expect(shortened != npub, "the card is showing the whole 63-character key")
        #expect(npub.hasPrefix(shortened.prefix(14)))
        #expect(npub.hasSuffix(shortened.suffix(4)))

        let payload = MarmotProfileLink.qrPayload(npub: npub)
        #expect(payload.contains(npub), "the code and the card are offering different keys")
    }

    /// The code sits on a 16pt continuous card.
    ///
    /// `wn-ios-prototype`'s `ShareableQRCodeView` names that radius and no stroke at all: a QR code
    /// is already an object made of high-contrast marks, so an outline around it only adds an edge
    /// competing with the matrix. The border the sheet used to draw was there to keep a card from
    /// vanishing into the glass behind it, and the flat ground removed the reason for it.
    @Test func theCodeCardIsACornerRadiusRatherThanAnOutline() {
        #expect(PublicIdentitySheetLayout.codeCardCornerRadius == 16)
    }

    /// The sheet is drawn on a flat surface rather than glass.
    ///
    /// Glass resolves close to `fillSecondary` in Light, which is the npub capsule's own ground — on
    /// glass the two were the same colour and the pill had no edge to be seen by. Rasterized and
    /// read back, because "did the pill separate from what is behind it" is a question about
    /// pixels.
    @MainActor
    @Test func theNpubPillSeparatesFromTheGroundTheSheetIsDrawnOn() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let pill = WNCopyCard(
                displayText: "npub1qqqq…qqqq",
                value: "npub1" + String(repeating: "q", count: 58),
                actionDescription: L10n.string("Copy npub"),
                style: .pill
            )
            .padding(24)
            .background(WNColor.backgroundSecondary)

            let rep = try #require(HostedView.render(pill, appearance: appearance, scale: 2))
            let ground = try #require(rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
            let onPill = try #require(
                rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            )

            #expect(
                abs(onPill.brightnessComponent - ground.brightnessComponent) > 0.01,
                "the pill is the same value as the ground behind it in \(appearance.rawValue)"
            )
        }
    }
}
