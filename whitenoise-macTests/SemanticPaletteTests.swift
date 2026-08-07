//
//  SemanticPaletteTests.swift
//  whitenoise-macTests
//
//  Guards on the semantic palette ported from the sibling clients'
//  `lib/theme/semantic_colors.dart`.
//
//  The mistake these exist to catch is a *pairing* one, not a wrong hex: reaching
//  across the background/content and fill/fill-content families, so that content
//  is drawn on a surface it was never meant for. It is invisible in one appearance
//  and unreadable in the other, which is exactly how it survives a visual check —
//  `fillContentPrimary` is white in light appearance, so putting it on
//  `backgroundPrimary` (also white) looks fine in dark and vanishes in light.
//
//  `.serialized` and `@MainActor`: these resolve colors through
//  `performAsCurrentDrawingAppearance`, which tears down the test host when it runs
//  off the main actor and reports the failure against whatever suite happens to be
//  running at the time.
//

import AppKit
import CoreImage
import SwiftUI
import Testing

@testable import whitenoise_mac

@MainActor
@Suite(.serialized)
struct SemanticPaletteTests {
    // MARK: - Ramp fidelity

    /// Spot-checks the ramp against the Dart source. Not exhaustive — the point is to
    /// catch a transcription slip in the steps the semantic layer leans on hardest.
    @Test func colorRampMatchesTheSharedPaletteValues() throws {
        let expected: [(NSColor, String)] = [
            (WNColorRamp.white, "FFFFFF"),
            (WNColorRamp.black, "000000"),
            (WNColorRamp.neutral50, "FAFAFA"),
            (WNColorRamp.neutral100, "F5F5F5"),
            (WNColorRamp.neutral150, "EDEDEE"),
            (WNColorRamp.neutral200, "E5E5E5"),
            (WNColorRamp.neutral400, "A3A3A3"),
            (WNColorRamp.neutral500, "737373"),
            (WNColorRamp.neutral800, "262626"),
            (WNColorRamp.neutral950, "0A0A0A"),
            (WNColorRamp.red600, "DC2626"),
            (WNColorRamp.green600, "16A34A"),
            (WNColorRamp.orange600, "EA580C"),
            (WNColorRamp.blue600, "2563EB"),
            (WNColorRamp.blue500, "3B82F6"),
        ]

        for (color, hex) in expected {
            #expect(Self.hexString(of: try #require(color.usingColorSpace(.sRGB))) == hex)
        }

        // The Dart `transparent` is `0x00FFFFFF` — transparent *white*, not transparent
        // black, which is what an interpolation through it produces.
        let transparent = try #require(WNColorRamp.transparent.usingColorSpace(.sRGB))
        #expect(transparent.alphaComponent == 0)
        #expect(Self.hexString(of: transparent) == "FFFFFF")
    }

    // MARK: - Pairing

    /// Every background/content and fill/fill-content pair the app draws, checked in both
    /// appearances. A swapped or crossed pair collapses the contrast here.
    @Test func semanticPairsStayLegibleInBothAppearances() throws {
        // Thresholds are per emphasis level, not one number: the palette deliberately runs
        // `backgroundContentTertiary` close to its surface, because that token is for
        // timestamps and placeholders that are *meant* to recede. Primary content is held to
        // WCAG AA for body text.
        let pairs: [(name: String, surface: NSColor, content: NSColor, minimum: Double)] = [
            ("primary/primary", WNNSColor.backgroundPrimary, WNNSColor.backgroundContentPrimary, 4.5),
            ("primary/secondary", WNNSColor.backgroundPrimary, WNNSColor.backgroundContentSecondary, 3.0),
            ("primary/tertiary", WNNSColor.backgroundPrimary, WNNSColor.backgroundContentTertiary, 2.0),
            ("secondary/primary", WNNSColor.backgroundSecondary, WNNSColor.backgroundContentPrimary, 4.5),
            ("secondary/secondary", WNNSColor.backgroundSecondary, WNNSColor.backgroundContentSecondary, 3.0),
            ("tertiary/primary", WNNSColor.backgroundTertiary, WNNSColor.backgroundContentPrimary, 4.5),
            ("tertiary/secondary", WNNSColor.backgroundTertiary, WNNSColor.backgroundContentSecondary, 3.0),
            ("tertiary/tertiary", WNNSColor.backgroundTertiary, WNNSColor.backgroundContentTertiary, 2.0),
            ("slate/primary", WNNSColor.backgroundSlate, WNNSColor.backgroundContentPrimary, 4.5),
            ("slate/secondary", WNNSColor.backgroundSlate, WNNSColor.backgroundContentSecondary, 3.0),
            // The received bubble, and the de-emphasized metadata drawn inside it.
            ("incoming/primary", WNNSColor.backgroundMessageIncoming, WNNSColor.backgroundContentPrimary, 4.5),
            ("incoming/secondary", WNNSColor.backgroundMessageIncoming, WNNSColor.backgroundContentSecondary, 3.0),
            ("incoming/tertiary", WNNSColor.backgroundMessageIncoming, WNNSColor.backgroundContentTertiary, 2.0),
            // The sent bubble and the primary button are the same pair.
            ("fillPrimary", WNNSColor.fillPrimary, WNNSColor.fillContentPrimary, 4.5),
            ("fillPrimaryHover", WNNSColor.fillPrimaryHover, WNNSColor.fillContentPrimary, 4.5),
            ("fillSecondary", WNNSColor.fillSecondary, WNNSColor.fillContentSecondary, 4.5),
            ("fillSecondaryHover", WNNSColor.fillSecondaryHover, WNNSColor.fillContentSecondary, 4.5),
            ("fillSecondary/tertiary", WNNSColor.fillSecondary, WNNSColor.fillContentTertiary, 2.0),
            ("fillDestructive", WNNSColor.fillDestructive, WNNSColor.fillContentQuaternary, 4.5),
            ("fillDisabled", WNNSColor.fillDisabled, WNNSColor.fillContentDisabled, 1.4),
            // The intentions are background/content pairs like any other, and are used as pairs:
            // the pending-invite badge draws `intentionInfoContent` on `intentionInfoBackground`,
            // the way the other clients style every info surface. Held to the large-text bar rather
            // than the body-text one, because that is where the reference palette actually sits —
            // a `600` step on a `50` wash of the same hue measures 3.15 (success, Aqua) to 5.6, and
            // these surfaces carry short bold labels and glyphs, never running text. The bar still
            // catches the mistake worth catching: an intention's content drawn on another
            // intention's background, or on a neutral surface it was not built for.
            ("intentionInfo", WNNSColor.intentionInfoBackground, WNNSColor.intentionInfoContent, 3.0),
            ("intentionSuccess", WNNSColor.intentionSuccessBackground, WNNSColor.intentionSuccessContent, 3.0),
            ("intentionWarning", WNNSColor.intentionWarningBackground, WNNSColor.intentionWarningContent, 3.0),
            ("intentionError", WNNSColor.intentionErrorBackground, WNNSColor.intentionErrorContent, 3.0),
            // An intention wash is laid over the app's own surfaces, so it has to be told apart
            // from them too — a badge whose capsule matches the row behind it is not a badge.
            ("intentionInfo/onPrimary", WNNSColor.backgroundPrimary, WNNSColor.intentionInfoContent, 4.5),
            // The scrim over media, and the chrome drawn on it.
            ("overlayTertiary", WNNSColor.overlayTertiary, WNNSColor.fillContentQuaternary, 4.5),
        ]

        for appearance in try Self.appearances() {
            for pair in pairs {
                let ratio = try Self.contrast(pair.surface, pair.content, in: appearance)
                #expect(
                    ratio >= pair.minimum,
                    """
                    \(pair.name) contrast \(ratio) < \(pair.minimum) \
                    in \(appearance.name.rawValue)
                    """
                )
            }
        }
    }

    /// `fillPrimary` and `backgroundPrimary` run in opposite directions, and so do their
    /// content tokens. That inversion is the reason the two families cannot be mixed, so it
    /// is asserted directly rather than left implicit in the contrast table.
    @Test func fillAndBackgroundFamiliesInvertRelativeToEachOther() throws {
        for appearance in try Self.appearances() {
            // The fill is the *opposite* of the surface it sits on…
            let fillOnSurface = try Self.contrast(
                WNNSColor.backgroundPrimary, WNNSColor.fillPrimary, in: appearance)
            #expect(fillOnSurface >= 4.5, "fillPrimary must stand out on backgroundPrimary")

            // …so content meant for the fill is invisible on the surface, and vice versa.
            // These are the two mistakes the pairing rule exists to prevent.
            let fillContentOnSurface = try Self.contrast(
                WNNSColor.backgroundPrimary, WNNSColor.fillContentPrimary, in: appearance)
            #expect(
                fillContentOnSurface < 1.2,
                """
                fillContentPrimary is legible on backgroundPrimary in \
                \(appearance.name.rawValue) (\(fillContentOnSurface)) — the two families no \
                longer invert, so crossing them would stop being caught
                """
            )
        }
    }

    // MARK: - Accents

    @Test func accentSetsPairTheirOwnFillAndContent() throws {
        let accents = Self.allAccents
        // A zero `accentCount` would make every loop below vacuous, so the suite would report full
        // coverage of the accents while asserting nothing about any of them.
        #expect(!accents.isEmpty, "AvatarPalette exposes no accents")

        for appearance in try Self.appearances() {
            for (name, accent) in accents {
                let ratio = try Self.contrast(
                    accent.nsFill, accent.nsContentPrimary, in: appearance)
                #expect(
                    ratio >= 4.5,
                    "accent \(name) contrast \(ratio) in \(appearance.name.rawValue)")
            }
        }
    }

    /// `contentSecondary` is the `500` step, and a mention is drawn in it on top of whichever
    /// bubble it lands in. The property that makes that possible is that `500` is
    /// **appearance-invariant** — the same value in Aqua and Dark Aqua — while `fill` and
    /// `contentPrimary` both cross over between them. A mention therefore needs to know neither
    /// which bubble it is on nor which appearance is current, which is what let the
    /// fill-dependent chip go away.
    ///
    /// Note what is *not* claimed: that `500` maximizes contrast. It does not. Against the light
    /// received bubble a bright ramp like lime lands at 1.81, and `lime900` would in fact do
    /// better there — the other clients draw the `500` step anyway, and this port follows them.
    /// The floor below is the inherited one, and it is asserted so that reaching for `50` or
    /// `950` here (which collapses to ~1.05 against one bubble or the other) still fails.
    @Test func accentContentSecondaryIsAppearanceInvariantAndClearsBothBubbles() throws {
        let bubbles = [
            ("sent", WNNSColor.fillPrimary),
            ("received", WNNSColor.backgroundMessageIncoming),
        ]
        let accents = Self.allAccents
        // A zero `accentCount` would make every loop below vacuous, so the suite would report full
        // coverage of the accents while asserting nothing about any of them.
        #expect(!accents.isEmpty, "AvatarPalette exposes no accents")

        for (name, accent) in accents {
            let resolved = try Self.appearances().map { appearance in
                try Self.resolvedHex(accent.nsContentSecondary, in: appearance)
            }
            #expect(
                resolved[0] == resolved[1],
                """
                accent \(name).contentSecondary differs between appearances \
                (\(resolved[0]) / \(resolved[1])) — a mention would need to know which \
                appearance it is drawn in, which is the coupling this token exists to avoid
                """
            )
            // The two steps it must not be replaced with do cross over, which is why they
            // cannot serve here.
            let fillHexes = try Self.appearances().map {
                try Self.resolvedHex(accent.nsFill, in: $0)
            }
            #expect(fillHexes[0] != fillHexes[1], "accent \(name).fill should invert")
        }

        for appearance in try Self.appearances() {
            for (bubbleName, bubble) in bubbles {
                for (name, accent) in accents {
                    let ratio = try Self.contrast(
                        bubble, accent.nsContentSecondary, in: appearance)
                    #expect(
                        ratio >= 1.6,
                        """
                        mention accent \(name) on the \(bubbleName) bubble is \(ratio) \
                        in \(appearance.name.rawValue)
                        """
                    )
                }
            }
        }
    }

    // MARK: - Avatar keying

    /// A mention carries the bech32, not the hex, so its accent is recovered from the first bech32
    /// data character. It has to agree with what the seed mapping would have said about the decoded
    /// key — `AvatarPaletteTests` covers that mapping itself; this covers only the bech32 shortcut.
    @Test func npubAccentAgreesWithTheDecodedHexAccent() throws {
        // The all-zero key: every data character is `q` (5-bit value 0), and the hex is `0000…`,
        // so both paths must land on the same accent.
        let zeroKeyNpub = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        #expect(
            AvatarPalette.accentIndex(forNpub: zeroKeyNpub)
                == AvatarPalette.accentIndex(for: String(repeating: "0", count: 64)))

        // The derivation is `first 5-bit value >> 1`, so each pair of adjacent bech32 characters
        // collapses onto one hex digit. `q`/`p` are values 0 and 1 → digit 0; `z`/`r` are 2 and 3 →
        // digit 1; `l` is the last character in the set, value 31 → digit 15.
        #expect(AvatarPalette.accentIndex(forNpub: "npub1q") == AvatarPalette.accentIndex(for: "0"))
        #expect(AvatarPalette.accentIndex(forNpub: "npub1p") == AvatarPalette.accentIndex(for: "0"))
        #expect(AvatarPalette.accentIndex(forNpub: "npub1z") == AvatarPalette.accentIndex(for: "1"))
        #expect(AvatarPalette.accentIndex(forNpub: "npub1r") == AvatarPalette.accentIndex(for: "1"))
        #expect(AvatarPalette.accentIndex(forNpub: "npub1l") == AvatarPalette.accentIndex(for: "f"))

        // Only a bare public key. `nprofile` is TLV-encoded, so its first data character is a record
        // tag rather than the top of a key, and guessing from it would produce a color that
        // disagrees with every other client.
        #expect(AvatarPalette.accentIndex(forNpub: "nprofile1qqqqqq") == nil)
        #expect(AvatarPalette.accentIndex(forNpub: "note1qqqqqq") == nil)
        #expect(AvatarPalette.accentIndex(forNpub: "npub1") == nil)
        #expect(AvatarPalette.accentIndex(forNpub: "") == nil)
        // `b` is not in the bech32 set (it excludes `1`, `b`, `i`, and `o`).
        #expect(AvatarPalette.accentIndex(forNpub: "npub1b") == nil)

        // And a mention actually resolves to that accent's `contentSecondary`. `try` rather than
        // `try?`: with an optional index a missing accent would compare `nil == nil` and pass,
        // which is the one outcome this assertion exists to catch.
        let index = try #require(AvatarPalette.accentIndex(forNpub: zeroKeyNpub))
        #expect(
            MentionTextPalette.foreground(forNpub: zeroKeyNpub)
                == AvatarPalette.accent(at: index).contentSecondary)
    }

    // MARK: - Reactions

    /// The two reaction sets cross over between appearances, because in both the crossed
    /// cases the chip is sitting on a dark bubble. A set that stopped crossing would read as
    /// a chip that vanishes into one of the two bubbles.
    @Test func reactionSetsPairEachStateWithItsContent() throws {
        let states: [(String, KeyPath<WNReactionColorSet, NSColor>, KeyPath<WNReactionColorSet, NSColor>)] = [
            ("rest", \.nsFill, \.nsContent),
            ("hover", \.nsFillHover, \.nsContent),
            ("selected", \.nsFillSelected, \.nsContentSelected),
        ]

        for appearance in try Self.appearances() {
            for isOutgoing in [true, false] {
                let set = WNReactionColors.set(isOutgoing: isOutgoing)
                for (stateName, fill, content) in states {
                    let ratio = try Self.contrast(
                        set[keyPath: fill], set[keyPath: content], in: appearance)
                    #expect(
                        ratio >= 3.0,
                        """
                        reaction \(isOutgoing ? "outgoing" : "incoming").\(stateName) contrast \
                        \(ratio) in \(appearance.name.rawValue)
                        """
                    )
                }
            }
        }
    }

    /// Adding your own reaction has to *read* as a state change, which is the one thing a chip's
    /// fill is load-bearing for.
    ///
    /// Deliberately not asserted against the bubble or the surface behind the chip: the other
    /// clients let a resting chip's fill match the surface outright — light `incoming` is plain
    /// white on a white surface — because a resting reaction is meant to read as an emoji rather
    /// than as a button. The emoji and its count carry it, and `reactionSetsPairEachStateWithItsContent`
    /// is what guards those.
    @Test func selectingAReactionChangesItsFillVisibly() throws {
        for appearance in try Self.appearances() {
            for isOutgoing in [true, false] {
                let set = WNReactionColors.set(isOutgoing: isOutgoing)
                let ratio = try Self.contrast(set.nsFill, set.nsFillSelected, in: appearance)
                #expect(
                    ratio >= 4.5,
                    """
                    reaction \(isOutgoing ? "outgoing" : "incoming"): selected fill is only \
                    \(ratio) from the resting fill in \(appearance.name.rawValue)
                    """
                )
            }
        }
    }

    // MARK: - Markdown code blocks

    /// A fenced code block (and a math block, which shares the view) has to *name* its foreground
    /// rather than inherit one, and this is what says so in both appearances.
    ///
    /// Two failures hide behind one inheritance. A code block nested in a block quote inherits the
    /// quote's `backgroundContentSecondary` tint, which is the code block's own fill — so the code
    /// was drawn in exactly the color behind it and vanished, in both appearances. Everywhere else
    /// it inherits the app-wide `backgroundContentPrimary`, which clears that mid-gray fill in light
    /// appearance and only reaches 2.52:1 in dark. The named pair fixes both at once, which is why
    /// the nested case is covered here rather than by rendering a quote: what went wrong was the
    /// token, and the token is the same one whatever the block is nested in.
    @Test func markdownCodeBlockNamesAForegroundThatClearsItsFillInBothAppearances() throws {
        for appearance in try Self.appearances() {
            let inherited = try Self.resolvedHex(WNNSColor.backgroundContentSecondary, in: appearance)
            let named = try Self.resolvedHex(MarkdownCodeBlockPalette.nsContent, in: appearance)
            #expect(
                named != inherited,
                """
                a code block nested in a block quote would inherit \(inherited) in \
                \(appearance.name.rawValue), which is its own fill
                """
            )

            let ratio = try Self.contrast(
                MarkdownCodeBlockPalette.nsFill, MarkdownCodeBlockPalette.nsContent, in: appearance)
            #expect(
                ratio >= 4.5,
                "code block contrast \(ratio) in \(appearance.name.rawValue)")
        }
    }

    // MARK: - QR codes

    /// The QR pair inverts with the appearance — near-black modules on white in Aqua, white on
    /// near-black in Dark Aqua — so the question is not contrast but whether a decoder still reads
    /// the reversed polarity. `CIDetector` is asked directly rather than trusted.
    @Test func qrCodeDecodesInBothAppearancePolarities() throws {
        let payload = "marmot:npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let context = CIContext()
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: context,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))

        for scheme in [ColorScheme.light, .dark] {
            let palette = QRCodePalette.resolved(for: scheme)
            let image = try #require(QRCodeImageView.ciImage(for: payload, palette: palette))
            let decoded = detector.features(in: image).compactMap {
                ($0 as? CIQRCodeFeature)?.messageString
            }
            #expect(decoded == [payload], "\(scheme) code did not decode: \(decoded)")

            let ratio = try Self.contrast(
                palette.modules.nsColor, palette.background.nsColor, in: try #require(NSAppearance(named: .aqua)))
            #expect(ratio >= 4.5, "\(scheme) modules are only \(ratio) from their quiet zone")
        }

        // And the two polarities really are different — a palette that resolved the same both ways
        // would pass every assertion above while defeating the point of the pair.
        #expect(QRCodePalette.resolved(for: .light) != QRCodePalette.resolved(for: .dark))
    }

    // MARK: - Helpers

    /// Every accent, read through `AvatarPalette`'s list so these tests cover the same twelve sets
    /// the app actually assigns rather than a second copy that could drift from it.
    private static var allAccents: [(String, WNAccentColorSet)] {
        (0..<AvatarPalette.accentCount).map { ("accent \($0)", AvatarPalette.accent(at: $0)) }
    }

    private static func appearances() throws -> [NSAppearance] {
        try [NSAppearance.Name.aqua, .darkAqua].map { try #require(NSAppearance(named: $0)) }
    }

    /// WCAG 2.x contrast ratio, resolved in `appearance` so a dynamic token reports the value
    /// it will actually draw with.
    private static func contrast(
        _ first: NSColor,
        _ second: NSColor,
        in appearance: NSAppearance
    ) throws -> Double {
        var resolved: (NSColor, NSColor)?
        appearance.performAsCurrentDrawingAppearance {
            guard
                let a = first.usingColorSpace(.sRGB),
                let b = second.usingColorSpace(.sRGB)
            else { return }
            resolved = (a, b)
        }
        let (a, b) = try #require(resolved)
        let first = relativeLuminance(of: a)
        let second = relativeLuminance(of: b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The sRGB hex a token resolves to under `appearance`, for asserting that a token does —
    /// or deliberately does not — change between them.
    private static func resolvedHex(_ color: NSColor, in appearance: NSAppearance) throws -> String {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return hexString(of: try #require(resolved))
    }

    private static func relativeLuminance(of color: NSColor) -> Double {
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private static func hexString(of color: NSColor) -> String {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        return channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}
