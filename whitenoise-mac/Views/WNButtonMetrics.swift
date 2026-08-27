//
//  WNButtonMetrics.swift
//  whitenoise-mac
//
//  The one shape the push-button tiers draw, so a primary button and the
//  secondary one beside it cannot disagree about their outline. The tiers
//  themselves are `WNPrimaryButton`, `WNSecondaryButtonStyle` and
//  `WNElevatedButtonStyle`.
//

import SwiftUI

/// The outline a push button's ground is cut to.
///
/// Two shapes rather than a free radius, because the choice is not per-button taste: it is which
/// *screen* a button is standing on. Everything inside the app's chrome draws `rounded` — a
/// sheet's confirm, an invite's `Accept`, a row's action — because that is `WnButton`
/// (`lib/widgets/wn_button.dart`), and those buttons sit among cards and fields that are all cut
/// the same way.
///
/// `capsule` is the onboarding shape, and it comes from `wn-ios-prototype`'s `WelcomeView`, which
/// reaches for `.buttonStyle(.glass)` and `.glassProminent` and then names **no**
/// `buttonBorderShape` at all. That omission is the design: Liquid Glass's own default border
/// shape is a capsule, so the prototype's two welcome actions are pills. The mac pane used to
/// override that back to a 12pt rounded rectangle, which is the whole of the mismatch.
///
/// Not `nonisolated` on purpose — see `WNButtonMetrics` below.
enum WNButtonShape: Sendable {
    /// The app's default: a rounded rectangle at `WNButtonMetrics.cornerRadius(for:)`.
    case rounded
    /// A pill. The onboarding pane, and anywhere else a button stands alone on a bare surface.
    case capsule
}

private struct WNButtonShapeKey: EnvironmentKey {
    static let defaultValue: WNButtonShape = .rounded
}

extension EnvironmentValues {
    /// Which outline the push-button tiers in this subtree draw.
    ///
    /// In the environment rather than passed per button for the same reason `controlSize` is: a
    /// pane sets it once and *every* tier under it reads the same value, so a stacked pair cannot
    /// come out one pill and one rounded rectangle. Setting it on a single button works too and is
    /// what a one-off wants.
    var wnButtonShape: WNButtonShape {
        get { self[WNButtonShapeKey.self] }
        set { self[WNButtonShapeKey.self] = newValue }
    }
}

extension View {
    /// Cuts every push button in this subtree to `shape`.
    ///
    /// Reach for it on the container — the pane, the row, the toolbar — not on one of two buttons
    /// that are meant to match.
    func wnButtonShape(_ shape: WNButtonShape) -> some View {
        environment(\.wnButtonShape, shape)
    }
}

/// Metrics shared by the push-button tiers.
///
/// The shape lives here rather than in any one tier because the tiers are almost always seen
/// *together*: an invite is answered with `Accept` beside `Decline`, a contact's profile leads
/// with `Follow` beside `Message`, and onboarding stacks `Sign In` over `Sign Up`. Each tier used
/// to name its own radius, and a primary button written as a bare `Button` on
/// `.nativeGlassProminentButtonStyle()` named none at all — with no `buttonBorderShape` the
/// platform draws a capsule, which is how the invite prompt ended up offering a pill next to an
/// 8pt rounded rectangle in the same row.
///
/// `controlSize` and `wnButtonShape` are both read from the environment because that is the one
/// place a pair genuinely shares: they are set on the row, not on either button.
///
/// Not `nonisolated`: `ControlSize` inherits the module's MainActor default. Asserting these
/// values still needs nothing but the main actor.
enum WNButtonMetrics {
    /// `WnButton` (`lib/widgets/wn_button.dart`) uses 8 at every size but `xsmall`, which the mac
    /// app has no use for. `.large` opens it up to 12: the radius that reads as an 8 on a 28pt
    /// control reads as a hairline crease on a 44pt one.
    ///
    /// Only consulted for `WNButtonShape.rounded`. A capsule has no radius of its own — it is
    /// always half its own height, which is what keeps a pill a pill as the control grows.
    static func cornerRadius(for controlSize: ControlSize) -> CGFloat {
        controlSize == .large ? 12 : 8
    }

    /// The ground the styles that draw their own background fill, stroke and hit-test against.
    ///
    /// One `AnyShape` for all three uses rather than three literals, because the three have to
    /// agree: a fill cut to a capsule under a hit region cut to a rounded rectangle is a button
    /// with dead corners.
    static func backgroundShape(_ shape: WNButtonShape, for controlSize: ControlSize) -> AnyShape {
        switch shape {
        case .rounded:
            AnyShape(RoundedRectangle(cornerRadius: cornerRadius(for: controlSize), style: .continuous))
        case .capsule:
            AnyShape(Capsule(style: .continuous))
        }
    }

    /// The same outline in the vocabulary the *native* styles speak. `.glassProminent` builds its
    /// own ground, so it cannot be handed a `Shape` — only one of these.
    static func borderShape(_ shape: WNButtonShape, for controlSize: ControlSize) -> ButtonBorderShape {
        switch shape {
        case .rounded: .roundedRectangle(radius: cornerRadius(for: controlSize))
        case .capsule: .capsule
        }
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

/// A `ViewModifier` rather than a plain `View` extension so it can read the environment: the
/// shape has to track whatever the row set, and a bare `.buttonBorderShape(…)` call site sees
/// nothing.
private struct WNPrimaryButtonChrome: ViewModifier {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.wnButtonShape) private var shape

    func body(content: Content) -> some View {
        content
            .buttonBorderShape(WNButtonMetrics.borderShape(shape, for: controlSize))
            .tint(WNColor.fillPrimary)
            .nativeGlassProminentButtonStyle()
    }
}
