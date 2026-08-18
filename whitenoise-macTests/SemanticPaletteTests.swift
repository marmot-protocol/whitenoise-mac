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
            // The reaction chip's two states. It is drawn on a bubble rather than on the app
            // surface, so its resting fill comes from the `background*` family and its selected
            // fill from `fill*` — the pill is a surface at rest and a pressed control when it
            // carries your own reaction. `reactionChipStaysLegibleOnBothBubbles` covers what this
            // table cannot: the pill against the two bubbles underneath it.
            ("reactionChip/resting", WNNSColor.backgroundPrimary, WNNSColor.backgroundContentPrimary, 4.5),
            ("reactionChip/selected", WNNSColor.fillSecondaryActive, WNNSColor.fillContentSecondary, 4.5),
            ("fillDisabled", WNNSColor.fillDisabled, WNNSColor.fillContentDisabled, 1.4),
            // The intentions are background/content pairs like any other, and the app draws them
            // as pairs — an intention's content on its own wash, the way the other clients style
            // every info/success/warning/error surface. Held to the large-text bar rather
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
            // The unread pill against the surfaces it is actually drawn on: the chat-list row
            // (`backgroundSecondary`), the account rail (`backgroundTertiary`) and the selected row
            // (`fillTertiaryHover`). A badge whose capsule matches the row behind it is not a badge.
            //
            // The badge is `fillPrimary` now rather than the blue `fillInfo` it used to be — the
            // prototype and the Flutter client both draw every unread signal in the one inverted
            // accent. That token was only ever the unread badge's, and it went with it; the numbers
            // here are the argument that nothing was lost, since an inverted fill clears all three
            // surfaces by a wider margin than the blue did.
            ("fillPrimary/onSecondary", WNNSColor.backgroundSecondary, WNNSColor.fillPrimary, 4.5),
            ("fillPrimary/onTertiary", WNNSColor.backgroundTertiary, WNNSColor.fillPrimary, 4.5),
            ("fillPrimary/onSelectedRow", WNNSColor.fillTertiaryHover, WNNSColor.fillPrimary, 4.5),
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
    /// The attachment row derives its waveform and its detail text from the row's *own* content at
    /// a reduced opacity, so each has to be measured against the row's own fill — the surface the
    /// rest of the table works from is the window, which is not what these are drawn on.
    ///
    /// Both fills invert between appearances while the content inverts with them, so a single
    /// opacity has to clear four combinations at once. That is what the old values missed: an
    /// unplayed bar at 0.42 measured 4.05 on the outgoing bubble in light appearance and 2.84 on
    /// the incoming one, and the duration label — drawn in the flat *background* token
    /// `backgroundContentTertiary` rather than in the row's content — ran from 7.85 down to 2.31.
    @Test func attachmentRowTonesClearTheRowFillTheyAreDrawnOn() throws {
        // Row fill paired with the content every tone in the row is derived from.
        let rows: [(name: String, fill: NSColor, content: NSColor)] = [
            ("outgoing", WNNSColor.fillPrimary, WNNSColor.fillContentPrimary),
            ("incoming", WNNSColor.backgroundMessageIncoming, WNNSColor.backgroundContentPrimary),
        ]
        // The unplayed waveform is a graphical object, so it takes WCAG's non-text bar; the
        // duration label is small text and takes the body-text one. The disc behind the play
        // control is deliberately absent: it is a locator for a glyph that carries its own
        // contrast, so a threshold on it would be a number invented to be met.
        let tones: [(name: String, opacity: Double, minimum: Double)] = [
            ("waveform bar", AttachmentRowPalette.waveformBarOpacity, 3.0),
            ("played waveform bar", AttachmentRowPalette.waveformPlayedBarOpacity, 4.5),
            ("duration label", AttachmentRowPalette.detailContentOpacity, 4.5),
        ]

        for appearance in try Self.appearances() {
            for row in rows {
                for tone in tones {
                    let drawn = try Self.blended(
                        row.content,
                        opacity: tone.opacity,
                        over: row.fill,
                        in: appearance
                    )
                    let ratio = try Self.contrast(drawn, row.fill, in: appearance)
                    #expect(
                        ratio >= tone.minimum,
                        """
                        \(row.name) \(tone.name) contrast \(ratio) < \(tone.minimum) \
                        in \(appearance.name.rawValue)
                        """
                    )
                }
            }
        }
    }

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

    /// The unread count, the mention pill, the manual-unread dot and the pending-invite `+` are all
    /// one fill, and that fill is the inverted `fillPrimary` — the prototype's single accent, and
    /// the Flutter client's.
    ///
    /// They used to be a blue `fillInfo`, a token that existed for them alone and was deleted with
    /// the decision. What that token bought was separation from the near-black row it sits on; an
    /// inverted neutral buys more of it (the `fillPrimary/onSecondary` rows in
    /// `semanticPairsStayLegibleInBothAppearances` measure it), so the property left to pin here is
    /// that the fill genuinely *crosses over* with the appearance. A badge frozen at one end — the
    /// mistake a literal `.black` would make — would pass every contrast row in one appearance and
    /// disappear in the other.
    @Test func everyUnreadSignalTakesTheInvertedPrimaryFill() throws {
        let fills = try Self.appearances().map { try Self.resolvedHex(WNNSColor.fillPrimary, in: $0) }
        #expect(fills == ["0A0A0A", "FFFFFF"], "fillPrimary should invert between the appearances")

        let contents = try Self.appearances().map {
            try Self.resolvedHex(WNNSColor.fillContentPrimary, in: $0)
        }
        #expect(
            contents == ["FFFFFF", "0A0A0A"],
            "fillContentPrimary should cross over with the fill it is drawn on")
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

    /// A mention is one color for everybody — the app's single blue, shared with a link and a
    /// search hit — so the first half of this pins its two steps. Blue is now confined to text:
    /// the badges that used to carry it are `fillPrimary`, and a blue that stopped stepping
    /// brighter in dark is the regression worth catching.
    ///
    /// The second half is what a per-person accent used to buy: a mention lands on the sent
    /// bubble, the received bubble and the composer without knowing which, and both bubble fills
    /// cross over between the appearances. This token crosses over too, and the right way round —
    /// the darker `600` step falls in Aqua, where the sent bubble is near-black, and the brighter
    /// `500` in Dark Aqua, where it is white. The floor is 3:1, the WCAG threshold for the bold
    /// weight a mention is always drawn at; pinning the token to a single step fails it (`blue600`
    /// everywhere lands at 2.93 on the dark received bubble).
    @Test func mentionColorIsTheAppsOneBlueAndClearsEverySurfaceItLandsOn() throws {
        let surfaces = [
            ("sent bubble", WNNSColor.fillPrimary),
            ("received bubble", WNNSColor.backgroundMessageIncoming),
            ("composer", WNNSColor.backgroundPrimary),
        ]

        let steps = try Self.appearances().map {
            try Self.resolvedHex(MentionTextPalette.nsForeground, in: $0)
        }
        #expect(
            steps == ["2563EB", "3B82F6"],
            "the mention blue should be blue600 in Aqua and the brighter blue500 in Dark Aqua")

        for appearance in try Self.appearances() {
            for (surfaceName, surface) in surfaces {
                let ratio = try Self.contrast(surface, MentionTextPalette.nsForeground, in: appearance)
                #expect(
                    ratio >= 3,
                    "mention on the \(surfaceName) is \(ratio) in \(appearance.name.rawValue)"
                )
            }
        }
    }

    // MARK: - Reactions

    /// A reaction chip hangs off a bubble's bottom edge, so it is drawn on `fillPrimary` or on
    /// `backgroundMessageIncoming` — fills that run in opposite directions. One pill now serves
    /// both, which is only sound because the pill's *fill* and its *border* take turns: whichever
    /// one the bubble happens to match, the other still draws the shape.
    ///
    /// This replaced `WNReactionColors`, a direction-keyed set whose dark incoming fill was
    /// `neutral800` — `backgroundMessageIncoming` exactly — so a chip on a received bubble in Dark
    /// Aqua was drawn in the bubble's own color *and* outlined in it, for a flat 1.0. That is the
    /// case this asserts cannot come back.
    ///
    /// The floor is low on purpose. A resting chip on the received bubble is *meant* to be quiet —
    /// it should read as an emoji, not as a button — and in Aqua that is where the pill is faintest:
    /// white on `neutral100` measures 1.09, its hairline 1.16. Everything else is far clear of the
    /// bar (the sent bubble is the pill's inverse, around 20:1). So the bar is set where it catches
    /// a genuine collapse without claiming a contrast the design does not want.
    @Test func reactionChipStaysLegibleOnBothBubbles() throws {
        let bubbles = [
            ("sent", WNNSColor.fillPrimary),
            ("received", WNNSColor.backgroundMessageIncoming),
        ]
        let states = [
            ("resting", WNNSColor.backgroundPrimary, WNNSColor.borderTertiary),
            ("own", WNNSColor.fillSecondaryActive, WNNSColor.borderPrimary),
        ]

        for appearance in try Self.appearances() {
            for (bubbleName, bubble) in bubbles {
                for (stateName, pill, border) in states {
                    let fillRatio = try Self.contrast(bubble, pill, in: appearance)
                    let borderRatio = try Self.contrast(bubble, border, in: appearance)
                    #expect(
                        max(fillRatio, borderRatio) >= 1.1,
                        """
                        the \(stateName) reaction chip is invisible on the \(bubbleName) bubble in \
                        \(appearance.name.rawValue): fill \(fillRatio), border \(borderRatio)
                        """
                    )
                }
            }
        }
    }

    /// Adding your own reaction has to *read* as a state change.
    ///
    /// The chip carries it on the border rather than the fill, which is the opposite of what the
    /// old direction-keyed set did: `backgroundPrimary` → `fillSecondaryActive` is one neutral rung,
    /// around 1.2:1, so the assertion that matters is on the outline swap. The fill still has to
    /// move — a border-only change on an unchanged pill reads as a rendering artifact — but it is
    /// held to "visibly different" rather than to a text bar it could never clear.
    @Test func selectingAReactionChangesTheChipsOutlineVisibly() throws {
        for appearance in try Self.appearances() {
            let outline = try Self.contrast(
                WNNSColor.borderTertiary, WNNSColor.borderPrimary, in: appearance)
            #expect(
                outline >= 4.5,
                """
                the own-reaction outline is only \(outline) from the resting hairline in \
                \(appearance.name.rawValue)
                """
            )

            let fill = try Self.contrast(
                WNNSColor.backgroundPrimary, WNNSColor.fillSecondaryActive, in: appearance)
            #expect(
                fill >= 1.15,
                """
                the own-reaction fill is only \(fill) from the resting fill in \
                \(appearance.name.rawValue)
                """
            )
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

    /// `color` laid over `background` at `opacity`, resolved in `appearance` — what a
    /// `.opacity()` modifier actually puts on screen, which is the thing worth measuring when a
    /// tone is derived from its own surface's content rather than named outright.
    private static func blended(
        _ color: NSColor,
        opacity: Double,
        over background: NSColor,
        in appearance: NSAppearance
    ) throws -> NSColor {
        var blended: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            guard
                let foreground = color.usingColorSpace(.sRGB),
                let base = background.usingColorSpace(.sRGB)
            else { return }
            blended = NSColor(
                srgbRed: foreground.redComponent * opacity + base.redComponent * (1 - opacity),
                green: foreground.greenComponent * opacity + base.greenComponent * (1 - opacity),
                blue: foreground.blueComponent * opacity + base.blueComponent * (1 - opacity),
                alpha: 1
            )
        }
        return try #require(blended)
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
