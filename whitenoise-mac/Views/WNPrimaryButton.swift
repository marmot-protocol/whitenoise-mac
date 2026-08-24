//
//  WNPrimaryButton.swift
//  whitenoise-mac
//
//  The app's primary push button — the other clients' `WnButton.primary`. Its
//  companion is `WNSecondaryButtonStyle` (`.wnSecondary`), the port of
//  `WnButton.outline`; between them they cover the two push-button tiers. The
//  sizes it draws at live in `WNPrimaryButtonSize.swift`.
//

import SwiftUI

/// The primary push button: one per screen, on the app's liquid glass.
///
/// **The glass is deliberate and is not this component's to change.** Only the secondary tier went
/// flat when the palette was ported; the primary action stays on `.glassProminent`, so what a size
/// controls here is the type ramp, the interior padding and the border shape — never the ground.
///
/// Because the style is native, the label has to carry its own padding: the chrome is drawn around
/// the label's frame, so padding *outside* the `Button` would leave the glass its original size and
/// merely hold its neighbours further off.
struct WNPrimaryButton<Label: View>: View {
    var size: WNPrimaryButtonSize = .medium
    let action: () -> Void
    @ViewBuilder let label: Label

    /// Read even though this component names its own `controlSize`: the shape and the size are
    /// different questions. A pane that asked for pills gets pills here too, rather than one
    /// rounded rectangle among them.
    @Environment(\.wnButtonShape) private var buttonShape

    var body: some View {
        Button(action: action) {
            label
                .wnFont(size.font)
                .padding(.vertical, size.verticalPadding)
                .padding(.horizontal, size.horizontalPadding)
        }
        .buttonBorderShape(WNButtonMetrics.borderShape(buttonShape, for: size.controlSize))
        .controlSize(size.controlSize)
        .nativeGlassProminentButtonStyle()
    }
}

extension WNPrimaryButton where Label == SwiftUI.Label<Text, Image> {
    /// The common case: a title and a leading SF Symbol, the shape `WnButton` takes with a
    /// `leadingIcon`.
    init(
        _ title: String,
        systemImage: String,
        size: WNPrimaryButtonSize = .medium,
        action: @escaping () -> Void
    ) {
        self.init(size: size, action: action) {
            SwiftUI.Label(title, systemImage: systemImage)
        }
    }
}
