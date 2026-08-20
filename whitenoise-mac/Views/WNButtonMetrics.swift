//
//  WNButtonMetrics.swift
//  whitenoise-mac
//
//  The one radius the two push-button tiers draw at, so a primary button and the
//  secondary one beside it cannot disagree about their shape. The tiers
//  themselves are `WNPrimaryButton` and `WNSecondaryButtonStyle`.
//

import SwiftUI

/// Metrics shared by both push-button tiers.
///
/// The radius lives here rather than in either tier because the tiers are almost always seen
/// *together*: an invite is answered with `Accept` beside `Decline`, and a contact's profile leads
/// with `Follow` beside `Message`. Each tier used to name its own radius, and a primary button
/// written as a bare `Button` on `.nativeGlassProminentButtonStyle()` named none at all — with no
/// `buttonBorderShape` the platform draws a capsule, which is how the invite prompt ended up
/// offering a pill next to an 8pt rounded rectangle in the same row.
///
/// `controlSize` is the key because it is the one thing a pair genuinely shares: it is set on the
/// row, not on either button, so both read the same value out of the environment.
enum WNButtonMetrics {
    /// `WnButton` (`lib/widgets/wn_button.dart`) uses 8 at every size but `xsmall`, which the mac
    /// app has no use for. `.large` opens it up to 12: the radius that reads as an 8 on a 28pt
    /// control reads as a hairline crease on a 44pt one.
    static func cornerRadius(for controlSize: ControlSize) -> CGFloat {
        controlSize == .large ? 12 : 8
    }
}

extension View {
    /// The primary tier's ground *and* its border shape, for a button that builds its own label
    /// rather than reaching for `WNPrimaryButton` — the invite pair's `Accept`, whose label carries
    /// a spinner and has to fill half of its row.
    ///
    /// The shape is the whole point. `.glassProminent` on its own draws a capsule, so a primary
    /// button that skips this will not match the `.wnSecondary` button standing next to it.
    func wnPrimaryButtonStyle() -> some View {
        modifier(WNPrimaryButtonChrome())
    }
}

/// A `ViewModifier` rather than a plain `View` extension so it can read `controlSize`: the radius
/// has to track whatever the row set, and a bare `.buttonBorderShape(…)` call site sees no
/// environment.
private struct WNPrimaryButtonChrome: ViewModifier {
    @Environment(\.controlSize) private var controlSize

    func body(content: Content) -> some View {
        content
            .buttonBorderShape(.roundedRectangle(radius: WNButtonMetrics.cornerRadius(for: controlSize)))
            .nativeGlassProminentButtonStyle()
    }
}
