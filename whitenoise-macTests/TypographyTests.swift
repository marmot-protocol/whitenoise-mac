//
//  TypographyTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Guards the two halves of the type ramp that fail *silently*: the bundled Manrope faces
/// registering at launch, and every rung staying on the Flutter client's ladder.
///
/// The registration half is the one worth having. `ATSApplicationFontsPath` is resolved
/// relative to `Contents/Resources`, and the app target's synchronized folder flattens
/// `Resources/Fonts` into that root — so the intuitive value ("Fonts") points at a directory
/// that does not exist in the built bundle. When that happens nothing errors: `NSFont(name:)`
/// returns nil, SwiftUI falls back to the system face, and the app builds, launches and looks
/// almost right. Only an assertion that the faces resolve catches it.
/// Sizes and their tracking, read off the Flutter client's `lib/theme/app_typography.dart`.
/// A drift on either side should fail here rather than quietly leave the two clients setting
/// the same screen at different sizes.
private let flutterLadder: [(CGFloat, CGFloat)] = [
    (10, 0.8), (12, 0.6), (14, 0.4), (16, 0.2), (18, 0.1), (20, 0), (24, -0.1),
    (28, -0.2), (32, -0.3), (36, -0.4), (48, -0.6), (60, -1.0), (72, -1.2), (96, -1.5),
]

@Suite struct TypographyTests {
    // MARK: - The bundled faces register

    @Test(arguments: WNFontWeight.allCases)
    func eachVendoredWeightResolvesByPostScriptName(weight: WNFontWeight) {
        let font = NSFont(name: weight.postScriptName, size: 14)

        #expect(font != nil, "\(weight.postScriptName) did not register; check ATSApplicationFontsPath")
        #expect(font?.familyName == "Manrope")
    }

    @Test(arguments: WNFontWeight.allCases)
    func eachVendoredWeightIsCopiedIntoTheBundle(weight: WNFontWeight) {
        let url = Bundle.main.url(forResource: weight.postScriptName, withExtension: "ttf")

        #expect(url != nil, "\(weight.fileName) is missing from the app bundle's Resources")
    }

    /// SemiBold and Bold both report AppKit's bold symbolic trait, which is why the ramp
    /// addresses faces by PostScript name instead of by family plus weight — a family lookup
    /// cannot tell these two apart.
    @Test func semiBoldAndBoldAreDistinctFaces() {
        let semiBold = NSFont(name: WNFontWeight.semiBold.postScriptName, size: 14)
        let bold = NSFont(name: WNFontWeight.bold.postScriptName, size: 14)

        #expect(semiBold != bold)
        #expect(semiBold?.fontName != bold?.fontName)
    }

    // MARK: - The ramp matches the Flutter ladder

    @Test(arguments: flutterLadder)
    func trackingMatchesTheFlutterLadder(size: CGFloat, tracking: CGFloat) {
        let style = WNTextStyle.custom(size: size, weight: .medium)

        #expect(style.size == size)
        #expect(style.tracking == tracking)
    }

    @Test func tokensCarryTheirLadderTracking() {
        #expect(WNTextStyle.medium10.tracking == 0.8)
        #expect(WNTextStyle.semiBold14.tracking == 0.4)
        #expect(WNTextStyle.medium16.tracking == 0.2)
        #expect(WNTextStyle.semiBold18.tracking == 0.1)
        #expect(WNTextStyle.medium24.tracking == -0.1)
    }

    @Test func tokensNameTheirOwnWeightAndSize() {
        #expect(WNTextStyle.medium14.weight == .medium)
        #expect(WNTextStyle.semiBold14.weight == .semiBold)
        #expect(WNTextStyle.bold14.weight == .bold)
        #expect(WNTextStyle.bold14.size == 14)
    }

    // MARK: - Off-ladder sizes snap onto the ramp

    /// An off-ladder size borrows the nearest rung's tracking rather than inventing one, and a
    /// size falling exactly between two rungs takes the larger — the rule the existing call
    /// sites were migrated onto, so `.system(size: 13)` and `.body` both land on 14.
    @Test(
        arguments: [
            (CGFloat(8), CGFloat(0.8)),  // below the floor
            (10.5, 0.8),
            (11, 0.6),  // tie 10/12 -> 12
            (13, 0.4),  // tie 12/14 -> 14
            (15.5, 0.2),
            (17, 0.1),  // tie 16/18 -> 18
            (22, -0.1),  // tie 20/24 -> 24
            (25, -0.1),
            (26, -0.2),  // tie 24/28 -> 28
            (30, -0.3),  // tie 28/32 -> 32
            (56, -1.0),
        ]
    )
    func offLadderSizesBorrowTheNearestRungsTracking(size: CGFloat, expected: CGFloat) {
        #expect(WNTextStyle.custom(size: size, weight: .medium).tracking == expected)
    }

    /// The escape hatch honours the size it is handed — it is there for text scaled at runtime,
    /// like an avatar monogram sized to its circle — while still sitting on the ramp's tracking.
    @Test func customHonoursARuntimeSize() {
        let style = WNTextStyle.custom(size: 37.4, weight: .bold)

        #expect(style.size == 37.4)
        #expect(style.weight == .bold)
        #expect(style.tracking == -0.4)  // borrowed from the 36 rung
    }

    // MARK: - Monospaced digits

    @Test func monospacedDigitKeepsTheRungIntact() {
        let style = WNTextStyle.medium10.monospacedDigit()

        #expect(style.usesMonospacedDigits)
        #expect(style.size == WNTextStyle.medium10.size)
        #expect(style.tracking == WNTextStyle.medium10.tracking)
        #expect(style.weight == WNTextStyle.medium10.weight)
    }

    /// Counters and timers ask for fixed-width digits. Manrope ships the Number Spacing
    /// feature, so this has to stay on Manrope rather than fall back to a system monospaced
    /// face — which would put a different typeface in the middle of a row.
    @Test func monospacedDigitStaysOnManrope() {
        let font = WNNSFont.font(for: .medium10.monospacedDigit())

        #expect(font.familyName == "Manrope")
    }

    // MARK: - The AppKit twin agrees with the SwiftUI face

    @Test(arguments: WNFontWeight.allCases)
    func appKitTwinResolvesTheSameFaceAndSize(weight: WNFontWeight) {
        let style = WNTextStyle.custom(size: 14, weight: weight)
        let font = WNNSFont.font(for: style)

        #expect(font.fontName == weight.postScriptName)
        #expect(font.pointSize == 14)
    }

    @Test func appKitAttributesCarryFontAndTracking() {
        let attributes = WNNSFont.attributes(for: .semiBold14)

        #expect((attributes[.font] as? NSFont)?.fontName == WNFontWeight.semiBold.postScriptName)
        #expect(attributes[.kern] as? CGFloat == 0.4)
    }

    // MARK: - The messenger ramp

    /// The shell's named roles resolve to rungs, not to ad-hoc sizes.
    @Test func messengerRolesSitOnTheLadder() {
        let ladder = Set(flutterLadder.map(\.0))
        let roles: [WNTextStyle] = [
            MessagesType.paneTitle, MessagesType.rowTitle, MessagesType.rowLabel,
            MessagesType.preview, MessagesType.meta, MessagesType.sectionHeader, MessagesType.badge,
        ]

        for role in roles {
            #expect(ladder.contains(role.size))
        }
    }
}
