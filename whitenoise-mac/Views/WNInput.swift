//
//  WNInput.swift
//  whitenoise-mac
//
//  The app's labelled text input — the other clients' `WnInput`. One control for
//  every form that lays out its own fields, in one shape.
//

import SwiftUI

/// A labelled text input: the label above the box, never beside it.
///
/// This is the merge of two controls that were drawing the same thing twice — `OnboardingFormField`
/// on the sign-up pane and `SettingsLabeledField` on Settings → Profile. They differed only in
/// their ground and their label ramp, and the difference was not a decision anyone had made: the
/// settings one was written first as a form row, the onboarding one was written second because a
/// form row read as borrowed on a bare pane. Once Settings → Profile became the sign-up form with
/// an Edit button on it, there was one look left, and two files drawing it.
///
/// **The shape is read, not named.** `\.wnButtonShape` at `.large` — the same lookup
/// `OnboardingKeyField` does, and for the same reason: the field has to match the button that
/// submits it, so both ask the same source rather than each naming a radius. A pane that asked for
/// pills gets a pill field; the app's default `.rounded` gets a 12pt box.
///
/// The multi-line variant is where the shape stops being literal. A capsule around a three-line box
/// is a lozenge, so `lineLimit` > 1 keeps the *radius* the capsule would have at
/// `WNInputMetrics.singleLineHeight` and applies it to a rounded rectangle: the two fields end up
/// with the same corner, which is the part of the shape that reads as a family.
///
/// `OnboardingKeyField` is deliberately not built on this. It carries no label, its accessory owns
/// two behaviours rather than being decoration, and it states its own `clipShape` to contain an
/// AppKit secure field's editor — three things that would each be a flag here for one caller.
struct WNInput<Accessory: View>: View {
    let label: String
    /// What the field shows when it is empty.
    let prompt: String
    @Binding var text: String
    /// `1` for a single-line field; more for a text area that many lines tall.
    var lineLimit = 1
    /// Whether the field accepts input at all. A busy form turns this off; the field stays a field.
    var isEnabled = true
    /// For address- and identifier-shaped values, where the corrector only ever gets it wrong.
    var disablesAutocorrection = false
    /// Spoken after the value — verification state, a unit, a count. The visual accessory is
    /// usually the same fact drawn, and is expected to be `.accessibilityHidden(true)`.
    var accessibilityValue: String?
    /// A complaint about what is currently typed, under the box. Present means invalid.
    var validationMessage: String?
    /// Drawn inside the box, at its trailing edge.
    @ViewBuilder var accessory: Accessory

    @Environment(\.wnButtonShape) private var buttonShape
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WNInputMetrics.labelSpacing) {
            Text(label)
                .wnFont(.semiBold14)
                .foregroundStyle(WNColor.backgroundContentSecondary)

            HStack(spacing: WNInputMetrics.accessorySpacing) {
                content
                accessory
            }
            .padding(.horizontal, WNInputMetrics.horizontalPadding)
            .padding(.vertical, WNInputMetrics.verticalPadding)
            .frame(minHeight: WNInputMetrics.height(forLineLimit: lineLimit), alignment: .topLeading)
            .background { shape.fill(WNColor.fillSecondary) }
            // The field owns its own edge rather than trusting the one AppKit happens to give a
            // focused field editor. See the long note on `OnboardingKeyField`, which is the case
            // that proved it.
            .clipShape(shape)

            if let validationMessage {
                Text(validationMessage)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var content: some View {
        field
            .textFieldStyle(.plain)
            .wnFont(.medium14)
            .focused($isFocused)
            .autocorrectionDisabled(disablesAutocorrection)
            .accessibilityValue(Text(accessibilityValue ?? text))
            .disabled(!isEnabled)
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

    /// Read through the shared table at `.large` — the size a form sets on the button that submits
    /// its fields — so a column cannot end up with two different corners.
    private var shape: AnyShape {
        guard lineLimit > 1 else {
            return WNButtonMetrics.backgroundShape(buttonShape, for: .large)
        }
        return AnyShape(
            RoundedRectangle(
                cornerRadius: WNInputMetrics.multilineCornerRadius,
                style: .continuous
            )
        )
    }
}

extension WNInput where Accessory == EmptyView {
    /// The common case: a field with nothing in its trailing edge.
    init(
        label: String,
        prompt: String,
        text: Binding<String>,
        lineLimit: Int = 1,
        isEnabled: Bool = true,
        disablesAutocorrection: Bool = false,
        accessibilityValue: String? = nil,
        validationMessage: String? = nil
    ) {
        self.init(
            label: label,
            prompt: prompt,
            text: text,
            lineLimit: lineLimit,
            isEnabled: isEnabled,
            disablesAutocorrection: disablesAutocorrection,
            accessibilityValue: accessibilityValue,
            validationMessage: validationMessage
        ) {
            EmptyView()
        }
    }
}

/// The numbers `WNInput` draws itself with.
///
/// Split out of the view so they can be asserted without standing one up, and so
/// `OnboardingLayout` — which has to reason about whether a whole pane fits a 620pt window — can
/// add a field's height to a sum without reaching into a `View`.
///
/// Not `nonisolated`: these are read alongside `ControlSize` and the rest of the module's
/// MainActor-isolated metrics, and asserting them still needs nothing but the main actor.
enum WNInputMetrics {
    /// Between a field's label and the box under it.
    static let labelSpacing: CGFloat = 6

    /// The box's inset. `OnboardingKeyField`'s, so a name field and a key field line their text up.
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8

    /// Between the field and whatever sits in its trailing edge.
    static let accessorySpacing: CGFloat = 6

    /// A single-line field's height — `OnboardingKeyField.Metrics.height`, restated here because
    /// that one is `private` to a view that owns an accessory this field does not have.
    ///
    /// Pinned rather than computed: a field that submits the same form as the key field beside it
    /// has to be exactly as tall as that field, not approximately.
    static let singleLineHeight: CGFloat = 40

    /// One line of `medium14`, rounded up.
    static let multilineLineHeight: CGFloat = 18

    /// The corner a multi-line field takes: the radius a `singleLineHeight` capsule has, so two
    /// fields in one column share a corner without the taller one becoming a lozenge.
    static let multilineCornerRadius: CGFloat = singleLineHeight / 2

    /// How tall a field with `lineLimit` lines of `medium14` draws, chrome included.
    static func height(forLineLimit lineLimit: Int) -> CGFloat {
        guard lineLimit > 1 else { return singleLineHeight }
        return CGFloat(lineLimit) * multilineLineHeight + 2 * verticalPadding
    }
}
