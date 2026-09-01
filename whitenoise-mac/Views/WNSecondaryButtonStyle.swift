//
//  WNSecondaryButtonStyle.swift
//  whitenoise-mac
//
//  The app's secondary push button, and the only one: a lesser action drawn as
//  a raised surface. Its siblings are `WNPrimaryButton` (glass) and
//  `WNDestructiveButtonStyle`; the shape all three cut to lives in
//  `WNButtonMetrics`.
//

import SwiftUI

/// The secondary push button: a lesser action, **raised rather than ringed**.
///
/// This tier used to be two. A ringed one — the port of Flutter's `WnButton.outline`
/// (`lib/widgets/wn_button.dart`) — drew every secondary action inside the app's own chrome, and a
/// raised one, `WNElevatedButtonStyle`, drew the ones standing on a bare pane: the onboarding
/// actions, then a sheet's `Cancel`, then the profile photo picker. Pepi collapsed the two on
/// 2026-09-01 and kept the raised drawing. There is now one secondary tier, and this is it.
///
/// Why the raised one won, in the order the argument matters:
///
/// 1. **A tier is not a per-screen taste.** Which of the two a call site reached for was decided by
///    which screen it was on, so a *flow* could show both — and one did: the sign-up hero's photo
///    pill was ringed while `Sign In`, one pane back, was lifted, which read as two different kinds
///    of control offered for the same weight of action. `AddRelaySheet`'s `Cancel` beside a capsule
///    `Add` was the same defect a second time. Every fix moved a call site toward the raised tier,
///    never away from it.
/// 2. **The two styles differed by one `stroke`** and otherwise held the same padding table, the
///    same quarter-alpha disabled rule, the same shape lookup and the same hover animation — three
///    copies of one tier's worth of decisions, kept in step by hand.
/// 3. **The ring was the half that never worked as ported.** `_buildOutlineButton` strokes
///    `borderTertiary`, which in Dark Aqua is the same value as its own `fillSecondary` — both
///    `neutral800` — so the dark outline button had no visible edge at all, and the fix was to
///    stroke `borderSecondary` instead, a token the palette hands to *fields* and hovered controls.
///    A tier whose defining feature had to be borrowed from another component's vocabulary was
///    never as settled as it looked.
///
/// The raised look itself comes from `wn-ios-prototype`'s welcome screen, which pairs its primary
/// action with `.buttonStyle(.glass)` rather than a bordered one, and glass is a lifted surface: a
/// shadow separates it from the pane, and there is no ring anywhere. This *reproduces* that rather
/// than calling `.glass`, because the app's deployment target is macOS 15.6 and the pre-26 fallback
/// for glass is `.bordered` — precisely the outlined button this tier exists to not be. A style
/// that changed shape across two OS versions would make "shadowed, not outlined" true on one of
/// them.
///
/// Four things worth knowing before touching this:
///
/// 1. **The ground is `backgroundSlate` at rest and then Flutter's own two `fillSecondary` rungs
///    once the pointer arrives**, so a resting button reads as a raised surface while a pointed-at
///    one steps like every other control in the app. See `fill`.
/// 2. **The shadow is the design system's own recipe, not a taste call.** Flutter's `WnSlate`
///    (`lib/widgets/wn_slate.dart`) — the raised card the other clients' onboarding buttons sit on
///    — draws two layers off `colors.shadow` at 10% alpha: `y+1 blur 2 spread -1`, and
///    `y+1 blur 3`. Both are ported here, and the lift doubles on hover so the pointer gets
///    feedback from the elevation as well as from the ground.
/// 3. **Padding is keyed to `controlSize`, not to Flutter's `WnButtonSize`.** The Flutter sizes are
///    phone metrics (`large` is 18pt of vertical padding, a thumb-sized full-width CTA). A mac push
///    button that tall next to a `.glassProminent` sibling would tower over it. These values are
///    matched to AppKit's bordered-button heights instead, so a secondary button and a primary one
///    on the same row line up. The *visual language* is what carries over — the continuous radius
///    (`WNButtonMetrics`, shared with the primary tier), the raised ground, `WnSlate`'s shadow —
///    not the phone's spacing.
/// 4. **`isHovering` lives on a nested `View`, not on the style.** `makeBody` is not a `View`, so
///    `@State` declared on the `ButtonStyle` itself has no identity to attach to and will not
///    reliably track. The body is a real view struct for that reason.
///
/// The circular icon controls are the *other* half of the `WnButton` port and are deliberately not
/// touched by this: `MessagesCircleControlBackground` is `WnIconButton.outline`, a different
/// component with its own ringed vocabulary in the composer and the account rail. Unifying the push
/// tiers says nothing about the discs.
struct WNSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WNSecondaryButtonBody(configuration: configuration)
    }
}

/// The rendered body of `WNSecondaryButtonStyle`.
///
/// Separate from the style so it can own `@State` for the pointer and read `\.isEnabled` and
/// `\.controlSize` — a `ButtonStyle` sees none of the three. `configuration.isPressed` is the only
/// state the style itself carries.
///
/// **This style is deliberately blind to `configuration.role`.** Colouring a `.destructive` button
/// with `backgroundContentDestructive` here would look like an obvious improvement and is not one:
/// every secondary button that carried the role did so while being deliberately *not* red — Remove
/// Account and Clear Cache by explicit request, Decline because the other clients build it as
/// `outline` rather than `destructive`. Reading the role would have silently turned all three red.
/// Those call sites have since dropped the role so the two cannot drift apart again. A genuinely
/// destructive action wants `WnButton.destructive` — a `fillDestructive` ground, which is
/// `WNDestructiveButtonStyle` — not a quiet button with red text.
private struct WNSecondaryButtonBody: View {
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
                // Deliberately no `.stroke` overlay. This is what the tier *is*, so it is worth
                // saying out loud: an edge added here would turn a raised button back into the
                // ringed one this style replaced, and it would be a ringed one that also casts a
                // shadow.
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

    /// `backgroundSlate` at rest, then Flutter's two `fillSecondary` rungs once the pointer arrives.
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
    /// The disabled quarter-alpha is Flutter's `fillSecondary.withValues(alpha: 0.25)`.
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

    /// Off `WNColor.shadow` at `WnSlate`'s alpha, doubled while pointed at and gone when pressed or
    /// disabled — a button that is being pushed should not be floating, and a quarter-alpha shadow
    /// under quarter-alpha content still lifts the button off the pane, which reads as pressable.
    /// Flat is the disabled state.
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

    /// AppKit's bordered-button rungs, shared verbatim with `WNDestructiveButtonStyle` so a
    /// destructive action under a secondary `Cancel` is the same height.
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

    /// From `WNButtonMetrics`, not chosen here — every tier draws one shape, and the pane picks
    /// which. Onboarding sets `.capsule`; everything inside the app's chrome leaves it `.rounded`.
    private var shape: AnyShape {
        WNButtonMetrics.backgroundShape(buttonShape, for: controlSize)
    }

    private static let disabledOpacity: Double = 0.25
    /// `colors.shadow.withValues(alpha: 0.1)`, both layers, from `WnSlate`.
    private static let shadowAlpha: Double = 0.1
    private static let hoverShadowAlpha: Double = 0.2
}

extension ButtonStyle where Self == WNSecondaryButtonStyle {
    /// The secondary push button — raised, not ringed.
    ///
    /// Reach for this for any action that is not the primary one on its screen and does not destroy
    /// anything: the alternative in a pair (`Decline` beside `Accept`), a sheet's `Cancel`, a
    /// standalone lesser action, an onboarding `Sign In`. The primary action keeps
    /// `wnPrimaryButtonStyle()`; a confirmed irreversible one takes `.wnDestructive`.
    static var wnSecondary: WNSecondaryButtonStyle { WNSecondaryButtonStyle() }
}
