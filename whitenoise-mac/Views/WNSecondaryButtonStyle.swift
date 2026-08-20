import SwiftUI

/// The app's secondary push button: the other clients' `WnButton` in its `outline` form.
///
/// `WnButton` (`lib/widgets/wn_button.dart`) has five types, and `outline` is the one the other
/// clients reach for whenever an action sits *beside* or *under* the primary one — 43 call sites
/// against 6 destructive ones, which makes it the default for everything that is not the main
/// action on a screen. This is that type, token for token:
///
/// | | Flutter `_buildOutlineButton` | here |
/// | --- | --- | --- |
/// | fill | `fillSecondary` | `WNColor.fillSecondary` |
/// | pointed at | `fillSecondaryHover` | `WNColor.fillSecondaryHover` |
/// | pressed | — (Material overlay) | `WNColor.fillSecondaryActive` |
/// | content | `fillContentSecondary` | `WNColor.fillContentSecondary` |
/// | border | `borderTertiary`, hairline | `WNColor.borderSecondary`, 1pt — see below |
/// | disabled | fill and content at `0.25` | fill, content **and border** at `0.25` |
///
/// Three things worth knowing before touching this:
///
/// 1. **The border is the one place this deliberately does not copy Flutter, because copying it
///    produced no border at all.** `_buildOutlineButton` strokes `borderTertiary`, and in Dark Aqua
///    that token and `fillSecondary` are *the same value* — both `neutral800`, `#262626`. Stroking
///    a shape in its own fill color draws nothing, so the dark outline button had no edge
///    whatsoever, and the Aqua pair (`neutral200` on `neutral100`) is only one ramp step apart and
///    nearly as faint. `borderSecondary` is the palette's own answer to this: `WNNSColor` documents
///    it as "a hovered outline, and the resting outline of an editable field", and the other clients
///    stroke their *visibly* outlined controls with it — `wn_filter_chip`, `wn_dropdown_selector`,
///    and `wn_input` once it is pointed at. It is also near-appearance-invariant (`neutral500` /
///    `neutral400`), so it clears both fills by a similar margin.
///
///    This is why the border now fades to a quarter alpha when disabled, where an earlier version of
///    this style held it solid: at `borderTertiary` strength a full-opacity ring was still quieter
///    than the ghosted content it surrounded, but at `borderSecondary` strength a solid ring around
///    ghosted content reads as an enabled button. All three parts fade together.
/// 2. **Padding is keyed to `controlSize`, not to Flutter's `WnButtonSize`.** The Flutter sizes are
///    phone metrics (`large` is 18pt of vertical padding, a thumb-sized full-width CTA). A mac push
///    button that tall next to a `.glassProminent` sibling would tower over it. These values are
///    matched to AppKit's bordered-button heights instead, so a secondary button and a primary one
///    on the same row line up. The *visual language* is what carries over — the continuous radius
///    (`WNButtonMetrics`, shared with the primary tier), the hairline ring, the `fillSecondary`
///    ground — not the phone's spacing.
/// 3. **`isHovering` lives on a nested `View`, not on the style.** `makeBody` is not a `View`, so
///    `@State` declared on the `ButtonStyle` itself has no identity to attach to and will not
///    reliably track. The body is a real view struct for that reason.
///
/// The circular icon controls are the *other* half of this port and already exist: see
/// `MessagesCircleControlBackground`, which is `WnIconButton.outline` drawn on the same four tokens.
struct WNSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WNSecondaryButtonBody(configuration: configuration)
    }
}

/// The rendered body of `WNSecondaryButtonStyle`.
///
/// Separate from the style so it can own `@State` for the pointer and read `\.isEnabled` — a
/// `ButtonStyle` sees neither. `configuration.isPressed` is the only state the style itself carries.
///
/// **This style is deliberately blind to `configuration.role`.** Colouring a `.destructive` button
/// with `backgroundContentDestructive` here would look like an obvious improvement and is not one:
/// every secondary button that carried the role did so while being deliberately *not* red — Remove
/// Account and Clear Cache by explicit request, Decline because the other clients build it as
/// `outline` rather than `destructive`. Reading the role would have silently turned all three red.
/// Those call sites have since dropped the role so the two cannot drift apart again. A genuinely
/// destructive action wants `WnButton.destructive` — a `fillDestructive` ground — not an outline
/// button with red text, so if that is ever needed, add it as its own style.
private struct WNSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(content)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(border, lineWidth: 1)
                    }
            }
            .contentShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    /// `outline`'s ground, stepping one neutral rung per state. The disabled quarter-alpha is
    /// Flutter's `fillSecondary.withValues(alpha: 0.25)`.
    private var fill: Color {
        guard isEnabled else { return WNColor.fillSecondary.opacity(Self.disabledOpacity) }
        if configuration.isPressed { return WNColor.fillSecondaryActive }
        return isHovering ? WNColor.fillSecondaryHover : WNColor.fillSecondary
    }

    /// The ring. Held constant across resting, hover and press — what a pointer changes is the
    /// ground, not the edge — and faded with everything else when disabled.
    private var border: Color {
        isEnabled ? WNColor.borderSecondary : WNColor.borderSecondary.opacity(Self.disabledOpacity)
    }

    /// Paired with `fill` above — both are the `Secondary` half of the palette, so this must never
    /// be swapped for a `backgroundContent*` token or a literal. See the pairing rule in `WNNSColor`.
    private var content: Color {
        isEnabled
            ? WNColor.fillContentSecondary
            : WNColor.fillContentSecondary.opacity(Self.disabledOpacity)
    }

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

    /// Shared with the primary tier so a pair in one row draws one shape — the radius this style
    /// used to hold as a flat 8, which is why an outline button beside a `.large` primary one came
    /// out squarer than its sibling.
    private var cornerRadius: CGFloat {
        WNButtonMetrics.cornerRadius(for: controlSize)
    }
    private static let disabledOpacity: Double = 0.25
}

extension ButtonStyle where Self == WNSecondaryButtonStyle {
    /// The secondary push button — `WnButton.outline` on the other clients.
    ///
    /// Reach for this for any action that is not the primary one on its screen: the alternative in
    /// a pair (`Decline` beside `Accept`), a sheet's `Cancel`, or a standalone lesser action. The
    /// primary action keeps `nativeGlassProminentButtonStyle()`.
    static var wnSecondary: WNSecondaryButtonStyle { WNSecondaryButtonStyle() }
}
