//
//  WNNSColor.swift
//  whitenoise-mac
//
//  The semantic palette, in AppKit form. Ported token-for-token from
//  `SemanticColors.light` / `SemanticColors.dark` in the sibling repository's
//  `lib/theme/semantic_colors.dart`, keeping the Dart names so the two files can
//  be diffed by eye.
//
//  SwiftUI code wants `WNColor` (the `Color` twin of this enum) — this one exists
//  for the handful of places that hand colors to AppKit: the composer's
//  `NSTextView`, and the attributed strings built for message bodies.
//
//  ## Pairing rule
//
//  Tokens come in background/content and fill/fill-content pairs, and the pairs
//  are not interchangeable. Content drawn on `backgroundPrimary` takes
//  `backgroundContent*`; content drawn on `fillSecondary` takes
//  `fillContentSecondary`. Reaching across the two families is how you get white
//  text on a white button — the reason `fillContentPrimary` is white in light
//  appearance but near-black in dark is that it is only ever drawn on
//  `fillPrimary`, which runs the other way.
//

import AppKit

nonisolated enum WNNSColor {
    // MARK: - Native macOS semantic roles (F01–F07)

    /// Window chrome and primary window backdrop.
    static let windowSurface = NSColor.windowBackgroundColor
    /// Primary reading surface for transcripts, lists, and content panes.
    static let readingSurface = NSColor.controlBackgroundColor
    /// Grouped boxes and composer container surface.
    static let groupedSurface = NSColor.quaternarySystemFill
    /// Subtle content wells inside forms.
    static let formContentSurface = NSColor.quinarySystemFill
    /// Hairline dividers and separators.
    static let separator = NSColor.separatorColor

    /// Native text hierarchy on reading and window surfaces.
    static let textPrimary = NSColor.labelColor
    static let textSecondary = NSColor.secondaryLabelColor
    static let textTertiary = NSColor.tertiaryLabelColor
    static let textPlaceholder = NSColor.placeholderTextColor
    static let textDisabled = NSColor.disabledControlTextColor

    /// Native link color on standard reading and received-bubble surfaces.
    static let link = NSColor.linkColor

    /// Native macOS find highlight paired with high-contrast dark ink on both appearances.
    static let findHighlight = NSColor.findHighlightColor
    static let findHighlightContent = WNColorRamp.neutral950

    /// Semantic status colors (symbols and short labels only; no tinted card washes).
    static let statusError = NSColor.systemRed
    static let statusWarning = NSColor.systemOrange
    static let statusSuccess = NSColor.systemGreen
    static let statusInfo = NSColor.systemBlue

    /// Scoped on-state tint for native switches and checkboxes.
    ///
    /// Uses near-black in Light appearance and a neutral mid-gray (`systemGray.pressed` resolved in
    /// Aqua, `#6F6F73`) in Dark appearance rather than white (`fillPrimary`), because a white track
    /// erases the native white `NSSwitch` thumb in Dark Mode while `#6F6F73` clears 4.5:1 against
    /// the white thumb and 3.0:1 against dark form surfaces.
    static let switchOnTint = NSColor.wnDynamic(
        "wn.switchOnTint",
        light: WNColorRamp.neutral950,
        dark: resolvedColor(in: .aqua) { NSColor.systemGray.withSystemEffect(.pressed) }
    )

    // MARK: - Paired message-bubble roles (F02 / T02)

    /// Received bubble fill (`secondarySystemFill` over `readingSurface`) and paired content.
    static let receivedBubbleSurface = NSColor.secondarySystemFill
    static let receivedBubbleContent = NSColor.labelColor
    static let receivedBubbleContentSecondary = NSColor.secondaryLabelColor
    static let receivedBubbleQuoteSurface = NSColor.systemFill
    static let receivedBubbleQuoteBar = NSColor.secondaryLabelColor
    static let receivedBubbleLink = NSColor.linkColor

    /// Sent bubble fill (inverted neutral) and paired content. Every foreground drawn on a sent
    /// bubble derives from `sentBubbleContent` or resolves for the inverted polarity so outgoing
    /// metadata, quotes, and links stay legible in both Light and Dark appearance.
    static let sentBubbleSurface = fillPrimary
    static let sentBubbleContent = fillContentPrimary
    static let sentBubbleContentSecondary = NSColor.wnDynamic(
        "wn.sentBubbleContentSecondary",
        light: WNColorRamp.white.withAlphaComponent(0.72),
        dark: WNColorRamp.neutral950.withAlphaComponent(0.72)
    )
    /// Quote / link-card inset on a sent bubble: `systemFill` resolved in the *opposite* polarity
    /// (dark appearance's translucent white on the dark light-mode bubble; light appearance's
    /// translucent black on the light dark-mode bubble).
    static let sentBubbleQuoteSurface = NSColor.wnDynamic(
        "wn.sentBubbleQuoteSurface",
        light: resolvedColor(in: .darkAqua) { NSColor.systemFill },
        dark: resolvedColor(in: .aqua) { NSColor.systemFill }
    )
    static let sentBubbleQuoteBar = sentBubbleContentSecondary
    /// Readable link hue on the inverted sent bubble: Dark Aqua's bright `linkColor` on the dark
    /// light-mode bubble, and Aqua's deeper `linkColor` on the light dark-mode bubble.
    static let sentBubbleLink = NSColor.wnDynamic(
        "wn.sentBubbleLink",
        light: resolvedColor(in: .darkAqua) { NSColor.linkColor },
        dark: resolvedColor(in: .aqua) { NSColor.linkColor }
    )

    private static func resolvedColor(in appearanceName: NSAppearance.Name, make: () -> NSColor) -> NSColor {
        guard let appearance = NSAppearance(named: appearanceName) else { return make() }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = make().usingColorSpace(.sRGB)
        }
        return resolved ?? make()
    }

    // MARK: - Legacy shared-palette backgrounds (retained for unmigrated callers)

    /// The app's base surface: the transcript, the chat list, a settings pane.
    static let backgroundPrimary = NSColor.wnDynamic(
        "wn.backgroundPrimary", light: WNColorRamp.white, dark: WNColorRamp.black)
    /// One step off the base surface — the sidebar columns, avatar placeholders.
    static let backgroundSecondary = NSColor.wnDynamic(
        "wn.backgroundSecondary", light: WNColorRamp.neutral50, dark: WNColorRamp.neutral950)
    /// Two steps off the base surface.
    static let backgroundTertiary = NSColor.wnDynamic(
        "wn.backgroundTertiary", light: WNColorRamp.neutral100, dark: WNColorRamp.neutral900)
    /// The surface of a sheet or popover lifted above the app ("slate").
    static let backgroundSlate = NSColor.wnDynamic(
        "wn.backgroundSlate", light: WNColorRamp.neutral50, dark: WNColorRamp.neutral900)
    /// The received message bubble.
    static let backgroundMessageIncoming = NSColor.wnDynamic(
        "wn.backgroundMessageIncoming", light: WNColorRamp.neutral100, dark: WNColorRamp.neutral800)

    // MARK: - Background content

    /// Primary text and glyphs on any `background*` surface.
    static let backgroundContentPrimary = NSColor.wnDynamic(
        "wn.backgroundContentPrimary", light: WNColorRamp.neutral950, dark: WNColorRamp.white)
    /// Supporting text: message previews, subtitles, field labels.
    static let backgroundContentSecondary = NSColor.wnDynamic(
        "wn.backgroundContentSecondary", light: WNColorRamp.neutral500, dark: WNColorRamp.neutral400)
    /// De-emphasized text: timestamps, placeholders, disabled glyphs.
    static let backgroundContentTertiary = NSColor.wnDynamic(
        "wn.backgroundContentTertiary", light: WNColorRamp.neutral400, dark: WNColorRamp.neutral500)
    /// Content that has to hold up over an unknown backdrop (media, blur), which
    /// is why it is an alpha of the opposite extreme rather than a ramp step.
    static let backgroundContentQuaternary = NSColor.wnDynamic(
        "wn.backgroundContentQuaternary",
        light: WNColorRamp.blackAlpha600,
        dark: WNColorRamp.whiteAlpha600)
    /// Destructive text and glyphs on a `background*` surface.
    static let backgroundContentDestructive = NSColor.wnDynamic(
        "wn.backgroundContentDestructive", light: WNColorRamp.red600, dark: WNColorRamp.red600)
    static let backgroundContentDestructiveSecondary = NSColor.wnDynamic(
        "wn.backgroundContentDestructiveSecondary",
        light: WNColorRamp.red500,
        dark: WNColorRamp.red500)

    // MARK: - Fills

    /// The primary action: the send button, a confirming push button, and the
    /// sent message bubble. Inverted against the surface — near-black on white,
    /// white on black — which is why White Noise has no accent hue here.
    static let fillPrimary = NSColor.wnDynamic(
        "wn.fillPrimary", light: WNColorRamp.neutral950, dark: WNColorRamp.white)
    static let fillPrimaryHover = NSColor.wnDynamic(
        "wn.fillPrimaryHover", light: WNColorRamp.neutral800, dark: WNColorRamp.neutral200)
    static let fillPrimaryActive = NSColor.wnDynamic(
        "wn.fillPrimaryActive", light: WNColorRamp.neutral800, dark: WNColorRamp.neutral200)

    /// The secondary action: a bordered button, a pill, a circular icon control.
    static let fillSecondary = NSColor.wnDynamic(
        "wn.fillSecondary", light: WNColorRamp.neutral100, dark: WNColorRamp.neutral800)
    static let fillSecondaryHover = NSColor.wnDynamic(
        "wn.fillSecondaryHover", light: WNColorRamp.neutral150, dark: WNColorRamp.neutral750)
    static let fillSecondaryActive = NSColor.wnDynamic(
        "wn.fillSecondaryActive", light: WNColorRamp.neutral150, dark: WNColorRamp.neutral750)

    /// The ghost action: no fill at rest, a wash once pointed at. Note that
    /// `fillTertiary` is deliberately *transparent*, so the hover/active steps
    /// are the only ones that draw.
    static let fillTertiary = NSColor.wnDynamic(
        "wn.fillTertiary", light: WNColorRamp.transparent, dark: WNColorRamp.transparent)
    static let fillTertiaryHover = NSColor.wnDynamic(
        "wn.fillTertiaryHover", light: WNColorRamp.neutral150, dark: WNColorRamp.neutral850)
    static let fillTertiaryActive = NSColor.wnDynamic(
        "wn.fillTertiaryActive", light: WNColorRamp.neutral150, dark: WNColorRamp.neutral850)

    /// Chrome floating over media, where the backdrop is a photo rather than a
    /// surface — hence an alpha wash instead of a ramp step.
    static let fillQuaternary = NSColor.wnDynamic(
        "wn.fillQuaternary", light: WNColorRamp.whiteAlpha900, dark: WNColorRamp.blackAlpha300)
    static let fillQuaternaryHover = NSColor.wnDynamic(
        "wn.fillQuaternaryHover", light: WNColorRamp.whiteAlpha800, dark: WNColorRamp.blackAlpha200)
    static let fillQuaternaryActive = NSColor.wnDynamic(
        "wn.fillQuaternaryActive", light: WNColorRamp.whiteAlpha800, dark: WNColorRamp.blackAlpha200)

    /// A destructive action's fill. Same in both appearances.
    static let fillDestructive = NSColor.wnDynamic(
        "wn.fillDestructive", light: WNColorRamp.red600, dark: WNColorRamp.red600)
    static let fillDestructiveHover = NSColor.wnDynamic(
        "wn.fillDestructiveHover", light: WNColorRamp.red500, dark: WNColorRamp.red500)
    static let fillDestructiveActive = NSColor.wnDynamic(
        "wn.fillDestructiveActive", light: WNColorRamp.red500, dark: WNColorRamp.red500)

    static let fillDisabled = NSColor.wnDynamic(
        "wn.fillDisabled", light: WNColorRamp.neutral300, dark: WNColorRamp.neutral650)
    static let fillContentDisabled = NSColor.wnDynamic(
        "wn.fillContentDisabled", light: WNColorRamp.neutral450, dark: WNColorRamp.neutral400)

    // MARK: - Fill content

    /// Content on `fillPrimary` — and therefore on the sent bubble.
    static let fillContentPrimary = NSColor.wnDynamic(
        "wn.fillContentPrimary", light: WNColorRamp.white, dark: WNColorRamp.neutral950)
    /// Content on `fillSecondary`.
    static let fillContentSecondary = NSColor.wnDynamic(
        "wn.fillContentSecondary", light: WNColorRamp.neutral950, dark: WNColorRamp.white)
    /// Content on `fillTertiary` — the ghost action's label.
    static let fillContentTertiary = NSColor.wnDynamic(
        "wn.fillContentTertiary", light: WNColorRamp.neutral500, dark: WNColorRamp.neutral400)
    /// Content on `fillDestructive`, and on `fillQuaternary` over media. White in
    /// both appearances, because both of those fills are dark in both.
    static let fillContentQuaternary = NSColor.wnDynamic(
        "wn.fillContentQuaternary", light: WNColorRamp.white, dark: WNColorRamp.white)

    // MARK: - Borders

    /// A focused or selected outline.
    static let borderPrimary = NSColor.wnDynamic(
        "wn.borderPrimary", light: WNColorRamp.neutral950, dark: WNColorRamp.white)
    /// A hovered outline, and the resting outline of an editable field.
    static let borderSecondary = NSColor.wnDynamic(
        "wn.borderSecondary", light: WNColorRamp.neutral500, dark: WNColorRamp.neutral400)
    /// The resting hairline: separators, card outlines, list dividers. By far the
    /// most-used border token on the other clients.
    static let borderTertiary = NSColor.wnDynamic(
        "wn.borderTertiary", light: WNColorRamp.neutral200, dark: WNColorRamp.neutral800)
    static let borderDestructivePrimary = NSColor.wnDynamic(
        "wn.borderDestructivePrimary", light: WNColorRamp.red600, dark: WNColorRamp.red600)
    static let borderDestructiveSecondary = NSColor.wnDynamic(
        "wn.borderDestructiveSecondary", light: WNColorRamp.red500, dark: WNColorRamp.red500)

    // MARK: - Intentions

    /// Informational: also the color of a link. Outside the accent sets, the only other blue is
    /// the search highlighter below.
    static let intentionInfoBackground = NSColor.wnDynamic(
        "wn.intentionInfoBackground", light: WNColorRamp.blue50, dark: WNColorRamp.blue950)
    static let intentionInfoContent = NSColor.wnDynamic(
        "wn.intentionInfoContent", light: WNColorRamp.blue600, dark: WNColorRamp.blue500)
    /// The highlighter mark behind the words a search matched, in a message bubble and in a
    /// search result alike. Mac-only: the shared palette colors a hit's text, but a mark drawn
    /// inside a bubble has to read on the sent and the received bubble in both appearances, which
    /// no `50`/`950` wash does — the light one vanishes on the light received bubble. A
    /// mid-saturation step against the opposite end of the ramp for its text keeps the marked
    /// words readable whatever bubble they sit in.
    static let searchHighlightBackground = NSColor.wnDynamic(
        "wn.searchHighlightBackground", light: WNColorRamp.blue200, dark: WNColorRamp.blue900)
    static let searchHighlightContent = NSColor.wnDynamic(
        "wn.searchHighlightContent", light: WNColorRamp.blue950, dark: WNColorRamp.blue50)

    static let intentionSuccessBackground = NSColor.wnDynamic(
        "wn.intentionSuccessBackground", light: WNColorRamp.green50, dark: WNColorRamp.green950)
    static let intentionSuccessContent = NSColor.wnDynamic(
        "wn.intentionSuccessContent", light: WNColorRamp.green600, dark: WNColorRamp.green500)

    static let intentionWarningBackground = NSColor.wnDynamic(
        "wn.intentionWarningBackground", light: WNColorRamp.orange50, dark: WNColorRamp.orange950)
    static let intentionWarningContent = NSColor.wnDynamic(
        "wn.intentionWarningContent", light: WNColorRamp.orange600, dark: WNColorRamp.orange500)
    /// A warning glyph drawn on `fillPrimary` (the sent bubble). Mac-only: the shared palette has
    /// one warning content step, and its dark `orange500` measures 2.80:1 on the white dark-mode
    /// bubble. This crosses over the way `fillContentPrimary` does — the lighter step on the dark
    /// fill, the darker step on the light one — so it clears 3:1 in both appearances.
    static let intentionWarningContentOnFill = NSColor.wnDynamic(
        "wn.intentionWarningContentOnFill", light: WNColorRamp.orange500, dark: WNColorRamp.orange600)

    static let intentionErrorBackground = NSColor.wnDynamic(
        "wn.intentionErrorBackground", light: WNColorRamp.red50, dark: WNColorRamp.red950)
    static let intentionErrorContent = NSColor.wnDynamic(
        "wn.intentionErrorContent", light: WNColorRamp.red600, dark: WNColorRamp.red500)

    // MARK: - Overlays and effects

    /// Drop shadows are drawn from this at low alpha in both appearances.
    static let shadow = NSColor.wnDynamic(
        "wn.shadow", light: WNColorRamp.black, dark: WNColorRamp.black)
    static let overlayPrimary = NSColor.wnDynamic(
        "wn.overlayPrimary", light: WNColorRamp.whiteAlpha500, dark: WNColorRamp.blackAlpha50)
    static let overlaySecondary = NSColor.wnDynamic(
        "wn.overlaySecondary", light: WNColorRamp.whiteAlpha500, dark: WNColorRamp.blackAlpha500)
    /// The scrim behind a full-screen media viewer.
    static let overlayTertiary = NSColor.wnDynamic(
        "wn.overlayTertiary", light: WNColorRamp.blackAlpha500, dark: WNColorRamp.blackAlpha500)
    /// QR modules. Always the opposite of the surface they are drawn on, and
    /// never tinted — a tinted QR code scans poorly.
    static let qrCode = NSColor.wnDynamic(
        "wn.qrCode", light: WNColorRamp.neutral950, dark: WNColorRamp.white)
}
