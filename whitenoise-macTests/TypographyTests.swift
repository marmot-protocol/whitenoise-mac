//
//  TypographyTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Guards the halves of the type ramp that fail *silently*: every rung staying on the Flutter
/// client's ladder, and the AppKit twin resolving the same face the SwiftUI side does.
///
/// The app typesets in the system face, the way `wn-ios-prototype` does — nothing is registered
/// and nothing is vendored. That is also why the ramp carries no tracking of its own: the
/// values it used to carry existed to open up a face that was drawn tight, and San Francisco is
/// already tracked optically per size. Re-adding them would apply them twice, so a test below
/// pins their absence rather than leaving it to a comment.

/// Sizes read off the Flutter client's `lib/theme/app_typography.dart`. Spelled out here rather
/// than read from `WNTextStyle.ladder` so a drift in the ladder fails against the other client
/// instead of agreeing with itself.
private let flutterLadder: [CGFloat] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96]

/// Every named rung, so a token added off the ladder fails here.
private let allTokens: [WNTextStyle] = [
    .medium10, .semiBold10, .bold10, .medium12, .semiBold12, .bold12,
    .medium14, .semiBold14, .bold14, .medium16, .semiBold16, .bold16,
    .medium18, .semiBold18, .bold18, .medium20, .semiBold20, .bold20,
    .medium24, .semiBold24, .bold24, .medium28, .semiBold28, .bold28,
    .medium32, .semiBold32, .bold32, .medium36, .semiBold36, .bold36,
    .medium48, .semiBold48, .bold48, .medium60, .semiBold60, .bold60,
    .medium72, .semiBold72, .bold72, .medium96, .semiBold96, .bold96,
]

@Suite struct TypographyTests {
    // MARK: - The ramp matches the Flutter ladder

    @Test func theLadderIsTheFlutterLadder() {
        #expect(WNTextStyle.ladder == flutterLadder)
    }

    @Test func everyTokenSitsOnTheLadder() {
        let ladder = Set(flutterLadder)

        for token in allTokens {
            #expect(ladder.contains(token.size), "\(token.size)pt is not a rung of the ladder")
        }
    }

    @Test func tokensNameTheirOwnWeightAndSize() {
        #expect(WNTextStyle.medium14.weight == .medium)
        #expect(WNTextStyle.semiBold14.weight == .semiBold)
        #expect(WNTextStyle.bold14.weight == .bold)
        #expect(WNTextStyle.bold14.size == 14)
        #expect(WNTextStyle.medium10.size == 10)
        #expect(WNTextStyle.semiBold96.size == 96)
    }

    /// The escape hatch honours the size it is handed — it is there for text scaled at runtime,
    /// like an avatar monogram sized to its circle.
    @Test func customHonoursARuntimeSize() {
        let style = WNTextStyle.custom(size: 37.4, weight: .bold)

        #expect(style.size == 37.4)
        #expect(style.weight == .bold)
    }

    // MARK: - The face is the system one

    /// Nothing is vendored, so a rung has to resolve to the framework's own face. A name-based
    /// lookup would be the silent failure here: CoreText answers one for a system font with a
    /// substitute rather than an error.
    @Test(arguments: WNFontWeight.allCases)
    func eachWeightResolvesToTheSystemFace(weight: WNFontWeight) {
        let font = WNNSFont.font(for: .custom(size: 14, weight: weight))

        #expect(font.familyName == NSFont.systemFont(ofSize: 14).familyName)
        #expect(font.pointSize == 14)
    }

    /// The three rungs of the weight axis have to stay three distinct faces — a ramp whose
    /// SemiBold and Bold render identically loses its loudest emphasis without failing anywhere.
    @Test func theThreeWeightsAreDistinctFaces() {
        let faces = WNFontWeight.allCases.map { WNNSFont.font(for: .custom(size: 14, weight: $0)).fontName }

        #expect(Set(faces).count == WNFontWeight.allCases.count)
    }

    @Test(arguments: WNFontWeight.allCases)
    func bothFrameworksSpellTheSameWeight(weight: WNFontWeight) {
        let expected: (Font.Weight, NSFont.Weight) =
            switch weight {
            case .medium: (.medium, .medium)
            case .semiBold: (.semibold, .semibold)
            case .bold: (.bold, .bold)
            }

        #expect(weight.swiftUI == expected.0)
        #expect(weight.appKit == expected.1)
    }

    // MARK: - Monospaced digits

    @Test func monospacedDigitKeepsTheRungIntact() {
        let style = WNTextStyle.medium10.monospacedDigit()

        #expect(style.usesMonospacedDigits)
        #expect(style.size == WNTextStyle.medium10.size)
        #expect(style.weight == WNTextStyle.medium10.weight)
    }

    /// Counters and timers ask for fixed-width digits so the label's edge stops moving as the
    /// clock ticks. The face still has to be the system one at the rung's weight — a fallback to
    /// a monospaced *family* would put a different typeface in the middle of a row.
    @Test func monospacedDigitStaysOnTheSystemFaceAndFixesDigitWidths() {
        let font = WNNSFont.font(for: .medium12.monospacedDigit())
        let one = ("1" as NSString).size(withAttributes: [.font: font]).width
        let eight = ("8" as NSString).size(withAttributes: [.font: font]).width

        #expect(font.pointSize == 12)
        #expect(one == eight)
    }

    // MARK: - The AppKit twin agrees with the SwiftUI face

    @Test(arguments: WNFontWeight.allCases)
    func appKitTwinResolvesTheSameSizeAndWeight(weight: WNFontWeight) {
        let style = WNTextStyle.custom(size: 14, weight: weight)
        let font = WNNSFont.font(for: style)

        #expect(font.pointSize == style.size)
        #expect(font == NSFont.systemFont(ofSize: 14, weight: weight.appKit))
    }

    /// The ramp carries no tracking: San Francisco is already tracked optically per size, so a
    /// `.kern` here would be applied on top of a face that has had it. Pinned rather than left
    /// to a comment, because re-adding one would look right in a diff and wrong on screen.
    @Test func appKitAttributesCarryTheFaceAndNoTracking() {
        let attributes = WNNSFont.attributes(for: .semiBold14)

        #expect((attributes[.font] as? NSFont) == NSFont.systemFont(ofSize: 14, weight: .semibold))
        #expect(attributes[.kern] == nil)
    }

    // MARK: - The messenger ramp

    /// The shell's named roles resolve to rungs, not to ad-hoc sizes.
    @Test func messengerRolesSitOnTheLadder() {
        let ladder = Set(flutterLadder)
        let roles: [WNTextStyle] = [
            MessagesType.paneTitle, MessagesType.rowTitle, MessagesType.rowLabel,
            MessagesType.preview, MessagesType.meta, MessagesType.sectionHeader, MessagesType.badge,
        ]

        for role in roles {
            #expect(ladder.contains(role.size))
        }
    }
}
