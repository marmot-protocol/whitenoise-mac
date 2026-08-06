//
//  AvatarPaletteTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// `.serialized` + `@MainActor` are load-bearing, not stylistic. Half of these assertions resolve
/// appearance-dependent colors, which on macOS means `performAsCurrentDrawingAppearance` — and that
/// mutates *process-global* drawing state. Left to run concurrently off the main thread, as
/// swift-testing does by default, it destabilizes the AppKit test host badly enough that the runner
/// exits mid-run (`exited with code 0 before finishing running tests`) and takes whichever tests
/// were in flight in other suites down with it, which reads as five unrelated failures.
@Suite(.serialized) @MainActor struct AvatarPaletteTests {
    // MARK: - Seed → accent mapping

    /// The mapping is the Flutter client's, recomputed here from its definition — the value of the
    /// seed's first hex digit, modulo the accent count — so a drift on either side fails here rather
    /// than silently giving one person two colors across the two apps.
    @Test(arguments: Array("0123456789abcdef"))
    func accentIndexMatchesTheFlutterClientMapping(digit: Character) {
        let seed = String(digit) + "f2a1c4b9e7d3056a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071"
        let flutterIndex = digit.hexDigitValue! % AvatarPalette.accentCount

        #expect(AvatarPalette.accentIndex(for: seed) == flutterIndex)
    }

    @Test func uppercaseHexSeedsResolveLikeLowercase() {
        #expect(AvatarPalette.accentIndex(for: "ABCD") == AvatarPalette.accentIndex(for: "abcd"))
        #expect(AvatarPalette.accentIndex(for: "E1") == AvatarPalette.accentIndex(for: "e1"))
    }

    /// Only the leading nibble participates, on both platforms — worth pinning, because it is the
    /// surprising part of the design and the thing a "let's hash the whole seed" refactor would break.
    @Test func onlyTheFirstCharacterDecidesTheAccent() {
        let index = AvatarPalette.accentIndex(for: "a000000000000000000000000000000000000000000000000000000000000000")
        let other = AvatarPalette.accentIndex(for: "affffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")

        #expect(index == other)
        #expect(AvatarPalette.accentIndex(for: "a") == index)
    }

    @Test(arguments: ["", "Sam Ruiz", "npub1acg6thl5psv62405rljzkj8spesceyfz2c32ud", "🔒", " a", "zebra"])
    func nonHexSeedsFallBackToNeutral(seed: String) {
        #expect(AvatarPalette.accentIndex(for: seed) == nil)
        #expect(AvatarPalette.colors(for: seed).fill == AvatarPalette.neutral.fill)
    }

    @Test func everyAccentIsReachable() {
        let covered = Set("0123456789abcdef".compactMap { AvatarPalette.accentIndex(for: String($0)) })

        #expect(covered.count == AvatarPalette.accentCount)
        #expect(covered == Set(0..<AvatarPalette.accentCount))
    }

    /// Documents an asymmetry inherited from the Flutter client rather than introduced here: a
    /// nibble spans sixteen values but there are twelve accents, so `c`-`f` wrap onto the first
    /// four. Matching the other client's assignment is the point, so this is pinned, not fixed.
    @Test func theFirstFourAccentsAreTwiceAsLikelyAsTheRest() {
        var frequency = [Int: Int]()
        for digit in "0123456789abcdef" {
            frequency[AvatarPalette.accentIndex(for: String(digit))!, default: 0] += 1
        }

        #expect((0..<4).allSatisfy { frequency[$0] == 2 })
        #expect((4..<AvatarPalette.accentCount).allSatisfy { frequency[$0] == 1 })
    }

    @Test func thePaletteCarriesTheTwelveFlutterAccents() {
        #expect(AvatarPalette.accentCount == 12)
    }

    // MARK: - Legibility

    /// The fill and the initials swap ends of the ramp together between appearances, so contrast is
    /// preserved by construction rather than by luck. Both directions are checked because the whole
    /// reason for two token sets is that one translucent color cannot serve both backdrops.
    @Test func initialsClearAAAContrastAgainstTheirFillInBothAppearances() {
        Self.forEachAppearance { appearanceName in
            for set in Self.allColorSets {
                let ratio = Self.contrast(set.content, set.fill)
                #expect(ratio >= 7.0, "\(appearanceName.rawValue): initials over fill was \(ratio)")
            }
        }
    }

    /// The ring is what gives the disc an edge, so it must never collapse into the fill it encloses.
    /// Asserted as channel distance, not luminance contrast: in Aqua the `200` ring differs from the
    /// `50` fill mostly in hue (measured floor 0.18, fuchsia), and a luminance-only check would call
    /// that invisible when the eye reads it fine.
    @Test func theBorderNeverCollapsesIntoTheFill() {
        Self.forEachAppearance { appearanceName in
            for (index, set) in Self.allColorSets.enumerated() {
                let distance = Self.channelDistance(set.border, set.fill)
                #expect(distance > 0.15, "\(appearanceName.rawValue): set \(index) ring/fill was \(distance)")
            }
        }
    }

    /// Identity is carried by the three tokens together, which is the honest invariant for this
    /// palette — the fills alone are nearly identical (blue vs sky is 0.016 apart in Aqua), so a
    /// fill-only assertion would fail on a design that is working as intended.
    @Test func accentsAreDistinguishableAcrossTheirTokensCombined() {
        Self.forEachAppearance { appearanceName in
            let sets = (0..<AvatarPalette.accentCount).map { Self.colorSet(at: $0) }
            for lhs in sets.indices {
                for rhs in sets.indices.dropFirst(lhs + 1) {
                    let distance =
                        Self.channelDistance(sets[lhs].fill, sets[rhs].fill)
                        + Self.channelDistance(sets[lhs].border, sets[rhs].border)
                        + Self.channelDistance(sets[lhs].content, sets[rhs].content)
                    #expect(
                        distance > 0.15,
                        "\(appearanceName.rawValue): accents \(lhs) and \(rhs) are only \(distance) apart")
                }
            }
        }
    }

    /// Aqua fills pale and inks deep; Dark Aqua inverts both. Pins the direction of the treatment,
    /// which is what distinguishes it from a fill that merely brightens with the appearance.
    @Test func fillAndInkInvertBetweenAppearances() {
        var lightFills = [Double]()
        var darkFills = [Double]()
        var lightInks = [Double]()
        var darkInks = [Double]()

        Self.withAppearance(.aqua) {
            lightFills = Self.allColorSets.map { Self.relativeLuminance($0.fill) }
            lightInks = Self.allColorSets.map { Self.relativeLuminance($0.content) }
        }
        Self.withAppearance(.darkAqua) {
            darkFills = Self.allColorSets.map { Self.relativeLuminance($0.fill) }
            darkInks = Self.allColorSets.map { Self.relativeLuminance($0.content) }
        }

        for index in lightFills.indices {
            #expect(lightFills[index] > darkFills[index], "set \(index) fill did not darken")
            #expect(lightInks[index] < darkInks[index], "set \(index) ink did not lighten")
        }
    }

    // MARK: - Helpers

    /// Every set an avatar can draw: the twelve accents plus the non-hex fallback.
    private static var allColorSets: [AvatarColorSet] {
        (0..<AvatarPalette.accentCount).map { colorSet(at: $0) } + [AvatarPalette.neutral]
    }

    /// The accent at `index`, reached the way production does — through a seed. Indices 0-11 are
    /// exactly the hex digits `0`-`9`, `a`, `b`, so the digit is the index in base 16.
    private static func colorSet(at index: Int) -> AvatarColorSet {
        AvatarPalette.colors(for: String(index, radix: 16))
    }

    private static func withAppearance(_ name: NSAppearance.Name, _ body: () -> Void) {
        guard let appearance = NSAppearance(named: name) else {
            Issue.record("no appearance named \(name.rawValue)")
            return
        }
        appearance.performAsCurrentDrawingAppearance(body)
    }

    private static func forEachAppearance(_ body: (NSAppearance.Name) -> Void) {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            withAppearance(name) { body(name) }
        }
    }

    /// A color that will not resolve is a failure to report, not a value to substitute: black is
    /// luminance zero, so falling back to it returns the *highest* contrast this file can compute and
    /// would let an unresolvable ink sail past the AAA floor. The recorded issue fails the enclosing
    /// test; `.nan` additionally makes every downstream comparison false, so there is no pass path.
    private static func sRGBComponents(_ color: Color) -> [Double] {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else {
            Issue.record("could not resolve \(color) in the sRGB color space")
            return [.nan, .nan, .nan]
        }
        return [Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent)]
    }

    /// WCAG 2.1 relative luminance.
    private static func relativeLuminance(_ color: Color) -> Double {
        let linear = sRGBComponents(color).map { channel in
            channel <= 0.039_28 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func contrast(_ lhs: Color, _ rhs: Color) -> Double {
        let (a, b) = (relativeLuminance(lhs), relativeLuminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Summed absolute per-channel difference — catches hue-only differences that a luminance
    /// contrast ratio reports as zero.
    private static func channelDistance(_ lhs: Color, _ rhs: Color) -> Double {
        zip(sRGBComponents(lhs), sRGBComponents(rhs)).reduce(0.0) { $0 + abs($1.0 - $1.1) }
    }
}
