//
//  OnboardingFormField.swift
//  whitenoise-mac
//
//  A labelled input on an onboarding pane, in the shape the pane's buttons are
//  already cut to.
//

import SwiftUI

/// A labelled text input for the onboarding column.
///
/// Deliberately not `SettingsLabeledField`. That control belongs to the settings pages and is
/// drawn as a form row would be — an 8pt rounded rectangle on `backgroundPrimary`, ringed, with a
/// hover state. The onboarding column has one shape and one ground for everything in it: whatever
/// `\.wnButtonShape` says (`.capsule` on both panes today) filled with `fillSecondary`, which is
/// what `OnboardingKeyField` draws and what the prototype draws behind its own fields. A settings
/// row dropped into that column reads as a control borrowed from somewhere else.
///
/// The multi-line variant is where the shape stops being literal. A capsule around a three-line
/// box is a lozenge, so `lineLimit` > 1 keeps the *radius* the capsule would have at
/// `OnboardingKeyField`'s height and applies it to a rounded rectangle: the two fields end up
/// with the same corner, which is the part of the shape that reads as a family.
struct OnboardingFormField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    /// `1` for a single-line capsule field; more for a text area that many lines tall.
    var lineLimit = 1
    var isEnabled = true

    @Environment(\.wnButtonShape) private var buttonShape
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingLayout.fieldLabelSpacing) {
            Text(label)
                .wnFont(.semiBold14)
                .foregroundStyle(WNColor.backgroundContentSecondary)

            field
                .textFieldStyle(.plain)
                .wnFont(.medium14)
                .focused($isFocused)
                .padding(.horizontal, OnboardingLayout.fieldHorizontalPadding)
                .padding(.vertical, OnboardingLayout.fieldVerticalPadding)
                .frame(minHeight: minimumHeight, alignment: .topLeading)
                .background { shape.fill(WNColor.fillSecondary) }
                .disabled(!isEnabled)
        }
    }

    @ViewBuilder
    private var field: some View {
        if lineLimit > 1 {
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(lineLimit, reservesSpace: true)
        } else {
            TextField(prompt, text: $text)
                .lineLimit(1)
        }
    }

    private var minimumHeight: CGFloat {
        OnboardingLayout.fieldHeight(forLineLimit: lineLimit)
    }

    /// Read through the shared table at `.large` — the size the pane sets on the button that
    /// submits these fields — so the column cannot end up with two different corners. See
    /// `OnboardingKeyField`, which resolves its shape the same way and for the same reason.
    private var shape: AnyShape {
        guard lineLimit > 1 else {
            return WNButtonMetrics.backgroundShape(buttonShape, for: .large)
        }
        return AnyShape(
            RoundedRectangle(
                cornerRadius: OnboardingLayout.multilineFieldCornerRadius,
                style: .continuous
            )
        )
    }
}
