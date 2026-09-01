//
//  PublicIdentitySheetTests.swift
//  whitenoise-macTests
//
//  The public-identity QR sheet: which address it may caption an identity with, and
//  the order it puts the identity, the code and the caption in.
//

import Foundation
import Testing

@testable import whitenoise_mac

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

    /// The layout is the request: the identity — avatar, name, Nostr address, npub — above the
    /// code, and the caption that says what the code is for below it. That order is the Flutter
    /// client's `share_profile_screen.dart`, and it is the half of this work that no behavior
    /// test can see: SwiftUI exposes neither a view's children nor their positions, and a render
    /// assertion would be pinned to the pixel heights of six elements rather than to their order.
    ///
    /// Sliced to the sheet's own declaration rather than matched against the file, because
    /// `PublicIdentityQRCodeButton` above it and `NostrAddressLabel` below it name several of the
    /// same symbols.
    @Test func theSheetStacksTheIdentityAboveTheCodeAndTheCaptionBelowIt() throws {
        let source = try Self.sheetDeclaration()

        let order = [
            "ProfileImageAvatarView(",  // the avatar
            "Text(displayName)",  // the name
            "NostrAddressLabel(address: nostrAddress)",  // the Nostr address
            "WNCopyCard(",  // the npub
            "QRCodeImageView(payload:",  // the code
            "Text(L10n.string(\"Scan to connect\"))",  // the caption
        ]

        var cursor = source.startIndex
        for element in order {
            let found = try #require(
                source.range(of: element, range: cursor..<source.endIndex),
                "\(element) is missing from the sheet, or is above the element before it"
            )
            cursor = found.upperBound
        }
    }

    /// The npub and the avatar are drawn by the components the rest of the app draws them with,
    /// rather than by shapes this one sheet owns. `WNCopyCard` is the same card the Profile page
    /// puts the npub in and the macOS twin of the other clients' `WnCopyCard`; a bespoke capsule
    /// here — which is what the iOS prototype uses — would be a second way to show one value.
    @Test func theSheetReusesTheSharedIdentityComponentsRatherThanItsOwn() throws {
        let source = try Self.sheetDeclaration()

        #expect(source.contains("WNCopyCard("))
        #expect(source.contains("style: .pill"))
        #expect(source.contains("ProfileImageAvatarView("))
        // No hand-rolled ground for either of them.
        #expect(!source.contains(".capsule"))
        #expect(!source.contains("fillSecondary"))
    }

    /// The code card is a shape, not a bordered box. `wn-ios-prototype`'s `ShareableQRCodeView`
    /// names a 16pt continuous container and no stroke at all: a QR code is already an object
    /// made of high-contrast marks, so an outline around it only adds an edge competing with the
    /// matrix. The border this sheet used to draw was there to keep a card from vanishing into
    /// the glass behind it, and the flat ground removed the reason for it.
    ///
    /// A source contract because a stroke is not observable from a rendered assertion that is
    /// robust: at a 1pt line on a rounded corner, antialiasing against the ground makes "is there
    /// an edge here" a threshold question rather than a yes-or-no one.
    @Test func theCodeCardIsAShapeWithNoBorder() throws {
        let source = try Self.sheetDeclaration()

        #expect(source.contains("cornerRadius: 16, style: .continuous"))
        #expect(!source.contains(".stroke("))
        #expect(!source.contains("WNColor.border"))
    }

    /// The sheet is drawn on a flat surface rather than `LiquidGlassBackground()`. Glass resolves
    /// close to `fillSecondary` in light, which is the npub capsule's own ground — on glass the
    /// two were the same colour and the pill had no edge to be seen by.
    @Test func theSheetIsDrawnOnAFlatGroundRatherThanGlass() throws {
        let source = try Self.sheetDeclaration()

        #expect(source.contains("WNColor.backgroundSecondary"))
        #expect(!source.contains("LiquidGlassBackground"))
    }

    private static func sheetDeclaration() throws -> String {
        // Comments are stripped: the sheet's doc comment names the prototype controls it
        // deliberately omits, which would satisfy an absence check that read the whole slice.
        return try SourceContract.declaration("PublicIdentityQRCodeSheet")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
