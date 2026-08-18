//
//  WNColor.swift
//  whitenoise-mac
//
//  The SwiftUI face of the semantic palette. Every token is the `Color` twin of
//  the `WNNSColor` of the same name, so there is one set of values and one set of
//  names across both frameworks; see `WNNSColor` for what each token means and
//  for the background/content pairing rule.
//
//  Each of these wraps a dynamic `NSColor`, so it resolves against the drawing
//  appearance on its own. A view does not need to read `\.colorScheme` to pick
//  between a light and a dark value — if you find yourself doing that, the token
//  is missing, not the branch.
//

import SwiftUI

nonisolated enum WNColor {
    // MARK: - Backgrounds

    static let backgroundPrimary = Color(nsColor: WNNSColor.backgroundPrimary)
    static let backgroundSecondary = Color(nsColor: WNNSColor.backgroundSecondary)
    static let backgroundTertiary = Color(nsColor: WNNSColor.backgroundTertiary)
    static let backgroundSlate = Color(nsColor: WNNSColor.backgroundSlate)
    static let backgroundMessageIncoming = Color(nsColor: WNNSColor.backgroundMessageIncoming)

    // MARK: - Background content

    static let backgroundContentPrimary = Color(nsColor: WNNSColor.backgroundContentPrimary)
    static let backgroundContentSecondary = Color(nsColor: WNNSColor.backgroundContentSecondary)
    static let backgroundContentTertiary = Color(nsColor: WNNSColor.backgroundContentTertiary)
    static let backgroundContentQuaternary = Color(nsColor: WNNSColor.backgroundContentQuaternary)
    static let backgroundContentDestructive = Color(nsColor: WNNSColor.backgroundContentDestructive)
    static let backgroundContentDestructiveSecondary = Color(
        nsColor: WNNSColor.backgroundContentDestructiveSecondary)

    // MARK: - Fills

    static let fillPrimary = Color(nsColor: WNNSColor.fillPrimary)
    static let fillPrimaryHover = Color(nsColor: WNNSColor.fillPrimaryHover)
    static let fillPrimaryActive = Color(nsColor: WNNSColor.fillPrimaryActive)

    static let fillSecondary = Color(nsColor: WNNSColor.fillSecondary)
    static let fillSecondaryHover = Color(nsColor: WNNSColor.fillSecondaryHover)
    static let fillSecondaryActive = Color(nsColor: WNNSColor.fillSecondaryActive)

    static let fillTertiary = Color(nsColor: WNNSColor.fillTertiary)
    static let fillTertiaryHover = Color(nsColor: WNNSColor.fillTertiaryHover)
    static let fillTertiaryActive = Color(nsColor: WNNSColor.fillTertiaryActive)

    static let fillQuaternary = Color(nsColor: WNNSColor.fillQuaternary)
    static let fillQuaternaryHover = Color(nsColor: WNNSColor.fillQuaternaryHover)
    static let fillQuaternaryActive = Color(nsColor: WNNSColor.fillQuaternaryActive)

    static let fillDestructive = Color(nsColor: WNNSColor.fillDestructive)
    static let fillDestructiveHover = Color(nsColor: WNNSColor.fillDestructiveHover)
    static let fillDestructiveActive = Color(nsColor: WNNSColor.fillDestructiveActive)

    static let fillDisabled = Color(nsColor: WNNSColor.fillDisabled)
    static let fillContentDisabled = Color(nsColor: WNNSColor.fillContentDisabled)

    // MARK: - Fill content

    static let fillContentPrimary = Color(nsColor: WNNSColor.fillContentPrimary)
    static let fillContentSecondary = Color(nsColor: WNNSColor.fillContentSecondary)
    static let fillContentTertiary = Color(nsColor: WNNSColor.fillContentTertiary)
    static let fillContentQuaternary = Color(nsColor: WNNSColor.fillContentQuaternary)

    // MARK: - Borders

    static let borderPrimary = Color(nsColor: WNNSColor.borderPrimary)
    static let borderSecondary = Color(nsColor: WNNSColor.borderSecondary)
    static let borderTertiary = Color(nsColor: WNNSColor.borderTertiary)
    static let borderDestructivePrimary = Color(nsColor: WNNSColor.borderDestructivePrimary)
    static let borderDestructiveSecondary = Color(nsColor: WNNSColor.borderDestructiveSecondary)

    // MARK: - Intentions

    static let intentionInfoBackground = Color(nsColor: WNNSColor.intentionInfoBackground)
    static let intentionInfoContent = Color(nsColor: WNNSColor.intentionInfoContent)
    static let intentionSuccessBackground = Color(nsColor: WNNSColor.intentionSuccessBackground)
    static let intentionSuccessContent = Color(nsColor: WNNSColor.intentionSuccessContent)
    static let intentionWarningBackground = Color(nsColor: WNNSColor.intentionWarningBackground)
    static let intentionWarningContent = Color(nsColor: WNNSColor.intentionWarningContent)
    static let intentionErrorBackground = Color(nsColor: WNNSColor.intentionErrorBackground)
    static let intentionErrorContent = Color(nsColor: WNNSColor.intentionErrorContent)

    // MARK: - Overlays and effects

    static let shadow = Color(nsColor: WNNSColor.shadow)
    static let overlayPrimary = Color(nsColor: WNNSColor.overlayPrimary)
    static let overlaySecondary = Color(nsColor: WNNSColor.overlaySecondary)
    static let overlayTertiary = Color(nsColor: WNNSColor.overlayTertiary)
    static let qrCode = Color(nsColor: WNNSColor.qrCode)
}
