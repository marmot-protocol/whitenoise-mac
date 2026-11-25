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

    /// Native primary text on reading and window surfaces.
    static let textPrimary = NSColor.labelColor
    /// Semantic error / destructive status tint.
    static let statusError = NSColor.systemRed

    /// Scoped on-state tint for native switches and checkboxes.
    ///
    /// Uses near-black in Light appearance and a neutral mid-gray (`neutral500`, `#737373`) in
    /// Dark appearance rather than white (`fillPrimary`), because a white track erases the native
    /// white `NSSwitch` thumb in Dark Mode while `#737373` clears 4.5:1 against the white thumb
    /// and 3.0:1 against dark form surfaces.
    static let switchOnTint = NSColor.wnDynamic(
        "wn.switchOnTint",
        light: WNColorRamp.neutral950,
        dark: WNColorRamp.neutral500
    )

    // MARK: - Message bubbles (F02, T02, T07)
    //
    // A text bubble is a surface with its own foreground set: body, metadata, quote inset and
    // links are chosen for the bubble they sit on, never inherited from the window. The received
    // bubble uses native fills and labels over the transcript. The sent bubble inverts against the
    // surface (`fillPrimary` with `fillContentPrimary`), so its secondary roles cross over the same
    // way: the lighter step on the dark bubble in Light, the darker step on the light bubble in
    // Dark. All of these are system colors or name-keyed dynamic colors, which are safe to resolve
    // from any thread.

    /// The received bubble: a native translucent fill over the transcript surface.
    static let messageReceivedFill = NSColor.secondarySystemFill
    /// Footer metadata and the quoted body on the received bubble.
    static let messageReceivedSecondaryContent = NSColor.secondaryLabelColor
    /// The quoted-reply inset inside the received bubble, one native fill step deeper.
    static let messageReceivedQuoteFill = NSColor.systemFill
    /// Links on the received bubble.
    static let messageReceivedLink = NSColor.linkColor

    /// Footer metadata and the quoted body on the sent bubble. `neutral400` on the near-black
    /// bubble in Light (7.8:1), `neutral650` on the white bubble in Dark (9.0:1). Both stay above
    /// 4.5:1 on `messageSentQuoteFill`, where the quoted body is drawn.
    static let messageSentSecondaryContent = NSColor.wnDynamic(
        "wn.messageSentSecondaryContent", light: WNColorRamp.neutral400, dark: WNColorRamp.neutral650)
    /// The quoted-reply inset inside the sent bubble, one neutral step in from the bubble's own
    /// fill, in the bubble's direction rather than the window's.
    static let messageSentQuoteFill = NSColor.wnDynamic(
        "wn.messageSentQuoteFill", light: WNColorRamp.neutral800, dark: WNColorRamp.neutral150)
    /// Links on the sent bubble. The app's blue is 3.8:1 on the near-black bubble and
    /// 3.7:1 on the white one, so the sent bubble takes a pale blue in Light (13.9:1) and a deeper
    /// blue in Dark (5.2:1).
    static let messageSentLink = NSColor.wnDynamic(
        "wn.messageSentLink", light: WNColorRamp.blue200, dark: WNColorRamp.blue600)

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
    /// Native macOS find-highlight fill behind matched words in bubbles and search snippets
    /// (F07, #1043). Paired with `searchHighlightContent` so matched substrings clear WCAG AA
    /// contrast on both incoming and outgoing bubble polarities in light and dark appearance.
    static let searchHighlightBackground = NSColor.findHighlightColor

    /// Contrast-guaranteed text color on `NSColor.findHighlightColor` across appearances.
    /// Resolves `findHighlightColor` in the drawing appearance and selects whichever monochrome
    /// endpoint (`neutral950` vs `white`) yields higher WCAG contrast against it.
    static let searchHighlightContent = NSColor(name: NSColor.Name("wn.searchHighlightContent")) { appearance in
        var resolvedFill: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedFill = NSColor.findHighlightColor.usingColorSpace(.sRGB)
        }
        guard let fill = resolvedFill else { return WNColorRamp.neutral950 }
        let fillLuminance = relativeLuminance(of: fill)
        let darkLuminance = relativeLuminance(of: WNColorRamp.neutral950)
        let lightLuminance = relativeLuminance(of: WNColorRamp.white)
        let darkContrast = (max(fillLuminance, darkLuminance) + 0.05) / (min(fillLuminance, darkLuminance) + 0.05)
        let lightContrast = (max(fillLuminance, lightLuminance) + 0.05) / (min(fillLuminance, lightLuminance) + 0.05)
        return darkContrast >= lightContrast ? WNColorRamp.neutral950 : WNColorRamp.white
    }

    private static func relativeLuminance(of color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

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
