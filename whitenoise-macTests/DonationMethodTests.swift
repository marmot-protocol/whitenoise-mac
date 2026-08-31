//
//  DonationMethodTests.swift
//  whitenoise-macTests
//
//  The Donate page's two methods: the exact addresses, which of them is shown whole,
//  and the fact that every string the page draws comes out of the catalog.
//

import CoreImage
import Foundation
import SwiftUI
import Testing

@testable import whitenoise_mac

// `@MainActor` and serialized because `QRCodePalette.resolved(for:)` goes through
// `performAsCurrentDrawingAppearance`, which takes the test host down if it runs off the main
// actor or alongside another suite doing the same thing.
@MainActor
@Suite(.serialized)
struct DonationMethodTests {

    // MARK: - The addresses

    // Transcribed from the Flutter client's `lib/screens/donate_screen.dart`, which is where
    // the shipped pair lives. Spelled out again here rather than read back off
    // `DonationMethod` so that this is an independent second copy: a test that compares the
    // type to itself would pass just as happily after a typo.
    private static let flutterLightningAddress = "whitenoise@donate.ipf.dev"
    private static let flutterBitcoinAddress =
        "sp1qqvp56mxcj9pz9xudvlch5g4ah5hrc8rj6neu25p34rc9gxhp38cwqqlmld28u57w2srgckr34dkyg3q02phu8tm05cyj483q026xedp0s5f5j40p"

    /// The one thing on this page that must not drift. A wrong character here does not draw
    /// badly or throw — it sends a donation to an address nobody controls, with no way to
    /// notice and no way back.
    @Test func donationAddressesMatchTheFlutterClientExactly() {
        #expect(DonationMethod.lightning.address == Self.flutterLightningAddress)
        #expect(DonationMethod.bitcoin.address == Self.flutterBitcoinAddress)
    }

    @Test func silentPaymentAddressKeepsItsFullLength() {
        // 116 characters: the `sp1` human-readable prefix plus 113 of bech32m payload, the
        // length a BIP-352 silent payment address carrying two 33-byte keys comes out at.
        // Pinned because the failure mode of a truncated address is a string that still
        // *looks* like an address.
        #expect(DonationMethod.bitcoin.address.count == 116)
        #expect(DonationMethod.bitcoin.address.hasPrefix("sp1"))
    }

    @Test func bothMethodsAreOfferedInProtocolOrder() {
        // Lightning first, as in `wn-ios-prototype`'s picker, and the default selection: it is
        // the address a reader can actually check by eye.
        #expect(DonationMethod.allCases == [.lightning, .bitcoin])
    }

    // MARK: - What is drawn, versus what is copied

    /// A Lightning address is a handle someone reads; a silent payment address is 117
    /// characters nobody reads end to end. The page shows the first whole and shortens the
    /// second — but copies both whole, which is the part that matters.
    @Test func onlyTheSilentPaymentAddressIsShortenedForDisplay() {
        #expect(DonationMethod.lightning.displayAddress == DonationMethod.lightning.address)

        let shortened = DonationMethod.bitcoin.displayAddress
        #expect(shortened != DonationMethod.bitcoin.address)
        #expect(shortened.contains("..."))
        #expect(shortened.hasPrefix("sp1qqvp56mxcj9"))
        #expect(DonationMethod.bitcoin.address.hasSuffix(shortened.suffix(6)))
    }

    // MARK: - Localization

    /// Every label the page draws resolves through the catalog. Asserted by key rather than
    /// against English text: the test host runs with a persisted language preference, so a
    /// literal comparison here would be a comparison against whatever language that is.
    @Test func methodLabelsComeFromTheCatalog() {
        #expect(DonationMethod.lightning.addressLabel == L10n.string("Lightning address"))
        #expect(DonationMethod.bitcoin.addressLabel == L10n.string("Bitcoin Silent Payment"))
        #expect(DonationMethod.lightning.switcherLabel == L10n.string("Lightning"))
        #expect(DonationMethod.bitcoin.switcherLabel == L10n.string("Bitcoin"))
    }

    /// The protocol names stay themselves in every language — the rule this app already
    /// follows for `KeyPackage` and the relay terms.
    @Test func protocolNamesAreNotTranslated() {
        for locale in [Locale(identifier: "es"), Locale(identifier: "ru"), Locale(identifier: "zh-Hans")] {
            #expect(L10n.string("Lightning", locale: locale) == "Lightning")
            #expect(L10n.string("Bitcoin", locale: locale) == "Bitcoin")
        }
    }

    /// The copy and QR descriptions are built by formatting a catalog string, so a missing
    /// entry would leave the raw `%@` on screen.
    @Test func copyAndQRDescriptionsInterpolateTheMethodName() {
        for method in DonationMethod.allCases {
            #expect(!method.copyActionDescription.contains("%@"))
            #expect(!method.qrCodeAccessibilityLabel.contains("%@"))
            #expect(method.copyActionDescription.contains(method.addressLabel))
            #expect(method.qrCodeAccessibilityLabel.contains(method.addressLabel))
        }
    }

    // MARK: - The QR code

    /// Each method's code decodes back to that method's *full* address, in both appearances.
    ///
    /// Decoded rather than measured, and asserted here rather than by snapshotting the page:
    /// `QRCodeImageView` rasterizes on a detached task, so a render harness photographs the
    /// spinner and proves nothing. What this rules out is the failure a reader cannot see — a
    /// scannable, well-formed code carrying the shortened display string, which would hand a
    /// wallet an address that can never receive.
    @Test func everyMethodsCodeDecodesToItsFullAddress() throws {
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(options: nil),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))

        for method in DonationMethod.allCases {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let palette = QRCodePalette.resolved(for: scheme)
                let image = try #require(
                    QRCodeImageView.ciImage(for: method.address, palette: palette),
                    "no code generated for \(method) in \(scheme)")
                let decoded = detector.features(in: image).compactMap {
                    ($0 as? CIQRCodeFeature)?.messageString
                }
                #expect(
                    decoded == [method.address],
                    "\(method) in \(scheme) decoded to \(decoded)")

                // Only meaningful where the two differ: Lightning is displayed whole, so for
                // that method the display form *is* the address.
                if method.displayAddress != method.address {
                    #expect(decoded.first != method.displayAddress)
                }
            }
        }
    }

    // MARK: - Where the page sits

    /// The prototype's hub keeps Donate on the support card beside Developer Tools, and the
    /// ask here was the same: the card that already holds Preferences and Developer mode.
    @Test func donateSitsBetweenPreferencesAndDeveloperMode() throws {
        let card = try #require(
            SettingsPage.sidebarGroups.first(where: { $0.contains(.donate) })
        )
        #expect(card == [.preferences, .donate, .developerMode])
    }
}
