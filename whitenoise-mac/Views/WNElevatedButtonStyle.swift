//
//  WNElevatedButtonStyle.swift
//  whitenoise-mac
//
//  The third push-button tier: a secondary action that is lifted rather than
//  ringed. Its siblings are `WNPrimaryButton` (glass) and
//  `WNSecondaryButtonStyle` (outlined); the radius all three draw at lives in
//  `WNButtonMetrics`.
//

import SwiftUI

/// A secondary push button that reads as **raised**, not outlined.
///
/// This is the onboarding tier. `wn-ios-prototype`'s welcome screen pairs its primary action
/// with `.buttonStyle(.glass)` rather than a bordered one, and glass is a lifted surface: a
/// shadow separates it from the pane, and there is no ring at all. That is the look this
/// reproduces — and it has to *reproduce* it rather than call `.glass`, because the app's
/// deployment target is macOS 15.6 and the pre-26 fallback for glass is `.bordered`, which is
/// precisely the outlined button this tier exists to not be. A style that changed shape across
/// two OS versions would make "shadowed, not outlined" true on one of them.
///
/// It is a third tier and not a replacement for `WNSecondaryButtonStyle`: the outlined tier is
/// still what a `Decline` beside an `Accept` wants, because that pair sits *inside* chrome that
/// is already layered and one more elevation would fight it. Reach for this one where the button
/// stands on a bare pane — the onboarding actions — **and for a sheet's `Cancel` beside a
/// primary**, which this comment used to send the other way. Pepi changed that on 2026-08-31:
/// paired with a capsule primary, the ringed rect read as a different kind of control rather
/// than the quiet half of one choice. `AddRelaySheet` is the first of these.
///
/// Three notes on the drawing:
///
/// 1. **The ground is `backgroundSlate` at rest and then the outlined tier's own two rungs**, so
///    the two read as one family from the moment they are pointed at while a resting one still
///    reads as a raised surface rather than a grey slab. See `fill`.
/// 2. **The shadow is the design system's own recipe, not a taste call.** Flutter's `WnSlate`
///    (`lib/widgets/wn_slate.dart`) — the raised card the other clients' onboarding buttons sit
///    on — draws two layers off `colors.shadow` at 10% alpha: `y+1 blur 2 spread -1`, and
///    `y+1 blur 3`. Both are ported here, and a lift is added on hover so the pointer gets the
///    same feedback the outlined tier gets from its ground.
/// 3. **Disabled drops the shadow entirely** rather than fading it with everything else. A
///    quarter-alpha shadow under quarter-alpha content still lifts the button off the pane, and
///    a raised-but-ghosted control reads as pressable. Flat is the disabled state.
struct WNElevatedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WNElevatedButtonBody(configuration: configuration)
    }
}

/// The rendered body of `WNElevatedButtonStyle`.
///
/// A real view struct for the same reason `WNSecondaryButtonBody` is one: `makeBody` is not a
/// `View`, so `@State` declared on the style has no identity to attach to, and a `ButtonStyle`
/// cannot read `\.isEnabled` or `\.controlSize` at all.
private struct WNElevatedButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.wnButtonShape) private var buttonShape
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(content)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background {
                // Deliberately no `.stroke` overlay. This is the whole difference between this
                // tier and `WNSecondaryButtonStyle`, so it is worth saying out loud: an edge
                // added here would turn a raised button into a ringed one that also happens to
                // cast a shadow.
                shape
                    .fill(fill)
                    .shadow(color: shadow, radius: innerShadowRadius, y: shadowOffset)
                    .shadow(color: shadow, radius: outerShadowRadius, y: shadowOffset)
            }
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    /// `backgroundSlate` at rest, then the ringed tier's own two rungs once the pointer arrives.
    ///
    /// **At rest this is a surface, not a control**, and that is why the resting rung comes out of
    /// the `background*` family while the interactive ones come out of `fill*`. It is the same
    /// split the reaction chip makes — see the note beside `reactionChip/resting` in
    /// `SemanticPaletteTests` — and here it is what the tier's own shadow already implies: the
    /// shadow is `WnSlate`'s recipe, so the ground should be `WnSlate`'s ground.
    ///
    /// It also fixes what the resting rung looked like. `fillSecondary` is `#F5F5F5` on a
    /// `#FFFFFF` pane and `#262626` on a black one — a wash heavy enough to read as a grey slab
    /// laid *over* the pane rather than a surface raised above it, which is not what
    /// `wn-ios-prototype` shows: its `.buttonStyle(.glass)` is a translucent material that barely
    /// tints what is behind it. `backgroundSlate` is a rung closer to the pane in both appearances
    /// — `#FAFAFA` and `#171717` — which leaves the shadow to do the lifting.
    ///
    /// Translucency is *not* the way to get there, and the attempt is worth recording: an alpha on
    /// the fill lets this style's own two drop shadows show through from underneath, which came out
    /// **darker** than the opaque rung it replaced (`#F0F0F0` against `#F5F5F5`). A `Shape`'s
    /// shadow is drawn behind the shape, so a see-through shape sees it.
    ///
    /// Hover and press are untouched, so the step under the pointer is now larger rather than
    /// smaller. The disabled quarter-alpha is Flutter's `fillSecondary.withValues(alpha: 0.25)`.
    private var fill: Color {
        guard isEnabled else { return WNColor.fillSecondary.opacity(Self.disabledOpacity) }
        if configuration.isPressed { return WNColor.fillSecondaryActive }
        return isHovering ? WNColor.fillSecondaryHover : WNColor.backgroundSlate
    }

    /// Paired with `fill`, which spans two families — so this is the ink that has to be right on
    /// both. It is: `fillContentSecondary` and `backgroundContentPrimary` resolve to the same two
    /// ramp values (`neutral950` light, `white` dark), which is exactly why the resting rung may
    /// come from `background*` without dragging a second ink in behind it. The pairing rule in
    /// `WNNSColor` still applies everywhere it bites — crossing a `fill*` ground with a
    /// `backgroundContent*` ink passes a single-appearance check and is wrong in the other one.
    private var content: Color {
        isEnabled
            ? WNColor.fillContentSecondary
            : WNColor.fillContentSecondary.opacity(Self.disabledOpacity)
    }

    /// Off `WNColor.shadow` at `WnSlate`'s alpha, doubled while pointed at and gone when pressed
    /// or disabled — a button that is being pushed should not be floating.
    private var shadow: Color {
        guard isEnabled, !configuration.isPressed else { return .clear }
        return WNColor.shadow.opacity(isHovering ? Self.hoverShadowAlpha : Self.shadowAlpha)
    }

    /// `WnSlate`'s tighter layer: `blurRadius: 2, spreadRadius: -1`. SwiftUI has no spread, so the
    /// negative one is folded into the radius.
    private var innerShadowRadius: CGFloat { isHovering ? 1.5 : 0.5 }
    /// `WnSlate`'s looser layer: `blurRadius: 3`. SwiftUI's `radius` is roughly half a CSS blur.
    private var outerShadowRadius: CGFloat { isHovering ? 3 : 1.5 }
    private var shadowOffset: CGFloat { isHovering ? 2 : 1 }

    /// Matched to `WNSecondaryButtonStyle` rung for rung: a raised button and a ringed one in the
    /// same row have to be the same height.
    private var verticalPadding: CGFloat {
        switch controlSize {
        case .large: 8
        case .small: 3
        case .mini: 2
        default: 5
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .large: 16
        case .small: 10
        case .mini: 8
        default: 12
        }
    }

    /// From `WNButtonMetrics`, not chosen here — all three tiers draw one shape, and the pane
    /// picks which. Onboarding sets `.capsule`; everything inside the app's chrome leaves it
    /// `.rounded`.
    private var shape: AnyShape {
        WNButtonMetrics.backgroundShape(buttonShape, for: controlSize)
    }

    private static let disabledOpacity: Double = 0.25
    /// `colors.shadow.withValues(alpha: 0.1)`, both layers, from `WnSlate`.
    private static let shadowAlpha: Double = 0.1
    private static let hoverShadowAlpha: Double = 0.2
}

extension ButtonStyle where Self == WNElevatedButtonStyle {
    /// The raised secondary push button — a lesser action standing on a bare pane.
    ///
    /// Use it in onboarding and on the account picker. Elsewhere the secondary action is
    /// `.wnSecondary`, which is ringed rather than lifted.
    static var wnElevated: WNElevatedButtonStyle { WNElevatedButtonStyle() }
}
