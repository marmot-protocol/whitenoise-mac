//
//  WNDestructiveButtonStyle.swift
//  whitenoise-mac
//
//  The push-button tier for an action that destroys something.
//

import SwiftUI

/// The app's destructive push button: the other clients' `WnButton` in its `destructive` form.
///
/// `WNSecondaryButtonStyle` is deliberately blind to `configuration.role`, and its own
/// documentation says why: the secondary buttons that carried `.destructive` were the ones asked
/// to be *not* red — Remove Account, Clear Cache, Decline — so reading the role there would have
/// turned all three red at once. The note ends by naming what a genuinely destructive action wants
/// instead: `WnButton.destructive`, a `fillDestructive` ground rather than a quiet button with
/// red text. This is that tier, token for token with `_buildDestructiveButton`
/// (`lib/widgets/wn_button.dart`):
///
/// | | Flutter `_buildDestructiveButton` | here |
/// | --- | --- | --- |
/// | fill | `fillDestructive` | `WNColor.fillDestructive` |
/// | pointed at | `fillDestructiveHover` | `WNColor.fillDestructiveHover` |
/// | pressed | — (Material overlay) | `WNColor.fillDestructiveActive` |
/// | content | `fillContentQuaternary` | `WNColor.fillContentQuaternary` |
/// | disabled fill | `fillDisabled` | `WNColor.fillDisabled` |
/// | disabled content | `fillContentDisabled` | `WNColor.fillContentDisabled` |
/// | border | none | none |
///
/// The disabled pair is the one place this differs in *kind* from the outline tier, and it is
/// Flutter's own choice: `outline` ghosts its own colours to a quarter alpha, while `destructive`
/// swaps to the neutral disabled pair outright. That matters here — a red ground at a quarter
/// alpha still reads as a live destructive button, which is exactly what a type-to-confirm gate
/// must not look like before the confirmation is typed.
///
/// Reach for this only where the action is irreversible *and* already gated by a confirmation the
/// reader has to complete. An anonymous red button is a trap; a red button at the end of a sheet
/// that spells out what it destroys is the point of the sheet.
struct WNDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WNDestructiveButtonBody(configuration: configuration)
    }
}

/// The rendered body of `WNDestructiveButtonStyle`.
///
/// A real view struct for the same reason `WNSecondaryButtonBody` is one: `makeBody` is not a
/// `View`, so `@State` on the style itself has no identity to attach to, and neither
/// `\.isEnabled` nor `\.controlSize` is visible from a `ButtonStyle`.
private struct WNDestructiveButtonBody: View {
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
                shape.fill(fill)
            }
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var fill: Color {
        guard isEnabled else { return WNColor.fillDisabled }
        if configuration.isPressed { return WNColor.fillDestructiveActive }
        return isHovering ? WNColor.fillDestructiveHover : WNColor.fillDestructive
    }

    /// Paired with `fill` — `fillContentQuaternary` is the light-on-saturated content colour the
    /// palette pairs with a `fillDestructive` ground. See the pairing rule in `WNNSColor`.
    private var content: Color {
        isEnabled ? WNColor.fillContentQuaternary : WNColor.fillContentDisabled
    }

    /// The same table `WNSecondaryButtonStyle` reads, so a destructive button under a
    /// `.wnSecondary` Cancel draws at the same height.
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

    private var shape: AnyShape {
        WNButtonMetrics.backgroundShape(buttonShape, for: controlSize)
    }
}

extension ButtonStyle where Self == WNDestructiveButtonStyle {
    /// The destructive push button — `WnButton.destructive` on the other clients.
    ///
    /// For the confirmed, irreversible action at the end of a flow that has already said what it
    /// destroys. Everything lesser is `.wnSecondary`.
    static var wnDestructive: WNDestructiveButtonStyle { WNDestructiveButtonStyle() }
}
