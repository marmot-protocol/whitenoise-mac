//
//  WNPrimaryButton.swift
//  whitenoise-mac
//
//  The app's primary push button — native `.borderedProminent` with scoped
//  monochrome tint (`WNColor.fillPrimary`). Its companion is
//  `.wnSecondaryButtonStyle()` (`.bordered`). The sizes it draws at live in
//  `WNPrimaryButtonSize.swift`.
//

import SwiftUI

/// The primary push button: native `.borderedProminent` with scoped monochrome tint.
///
/// `.controlSize` is applied *outside* `.wnPrimaryButtonStyle()` so the style's
/// `@Environment(\.controlSize)` reads `size.controlSize` rather than an outer container's size.
struct WNPrimaryButton<Label: View>: View {
    var size: WNPrimaryButtonSize = .medium
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .wnFont(size.font)
                .padding(.vertical, size.verticalPadding)
                .padding(.horizontal, size.horizontalPadding)
        }
        .wnPrimaryButtonStyle()
        .controlSize(size.controlSize)
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
