//
//  SettingsFormControls.swift
//  whitenoise-mac
//
//  Form controls for settings pages that lay out their own fields instead of
//  using native grouped `Form` rows. Mirrors `WnInput` on the other clients, so
//  a page built from these reads the same here as it does there.
//

import SwiftUI

/// A labelled, outlined text field: the label sits above the box, never beside it.
///
/// The box is the composer's field recipe at a form's corner radius — `backgroundPrimary`
/// inside a hairline that follows interaction the way `WnInput` does on the other clients:
/// `borderPrimary` while focused, `borderSecondary` on hover, `borderTertiary` at rest.
struct SettingsLabeledField<Field: View>: View {
    let label: String
    var minHeight: CGFloat = 36
    @ViewBuilder let field: Field

    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentPrimary)

            field
                .textFieldStyle(.plain)
                .wnFont(.medium14)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: minHeight, alignment: .topLeading)
                .background(WNColor.backgroundPrimary, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
                .onHover { isHovering = $0 }
        }
    }

    private var borderColor: Color {
        if isFocused { return WNColor.borderPrimary }
        if isHovering { return WNColor.borderSecondary }
        return WNColor.borderTertiary
    }
}
