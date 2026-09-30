//
//  DisappearingTimerPopover.swift
//  whitenoise-mac
//
//  Choosing a group's disappearing-message timer: the presets, and a custom count + unit.
//  The macOS counterpart of the iOS client's `GroupRetentionEditorSheet`.
//

import SwiftUI

/// The disappearing-message timer chooser that group info opens from both its quick action and
/// its Settings row, so the two can never offer different choices.
///
/// Presets commit on click. "Custom…" swaps the list for a count and a unit in place, rather than
/// opening a second popover over the first.
struct DisappearingTimerPopover: View {
    let currentSeconds: UInt64
    let onSelect: (UInt64) -> Void

    /// `nil` while the presets are showing.
    @State private var custom: DisappearingCustomDuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string(custom == nil ? "Disappearing messages" : "Custom duration"))
                .wnFont(.semiBold14)

            if let custom = Binding($custom) {
                DisappearingCustomDurationEditor(duration: custom) {
                    if let seconds = custom.wrappedValue.seconds { onSelect(seconds) }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(DisappearingMessageOption.options(for: currentSeconds)) { option in
                        WNSelectRow(title: option.label, isSelected: option.seconds == currentSeconds) {
                            onSelect(option.seconds)
                        }
                    }
                    WNSelectRow(title: L10n.string("Custom…"), isSelected: false) {
                        custom = DisappearingCustomDuration(seconds: currentSeconds)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// A count and a unit, and the Set button that commits them.
private struct DisappearingCustomDurationEditor: View {
    @Binding var duration: DisappearingCustomDuration
    let onSet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                // Closure-based stepper: no range, so no stride arithmetic to trap on.
                Stepper {
                    TextField("", text: $duration.text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .accessibilityLabel(L10n.string("Duration value"))
                } onIncrement: {
                    duration.increment()
                } onDecrement: {
                    duration.decrement()
                }
                // Real label for VoiceOver, hidden from the visual layout.
                Picker(L10n.string("Duration unit"), selection: $duration.unit) {
                    ForEach(DisappearingMessageDurationUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            HStack {
                Spacer()
                Button(L10n.string("Set"), action: onSet)
                    .keyboardShortcut(.defaultAction)
                    .nativeGlassProminentButtonStyle()
                    .disabled(duration.seconds == nil)
            }
        }
    }
}

#Preview("Presets") {
    DisappearingTimerPopover(currentSeconds: 86_400) { _ in }
}

#Preview("Custom current value") {
    DisappearingTimerPopover(currentSeconds: 4 * 604_800) { _ in }
}
