//
//  WNToggle.swift
//  whitenoise-mac
//
//  Native macOS toggle (switch or checkbox) with a scoped dark-safe monochrome
//  tint (`WNColor.switchOnTint`) so switches and checkboxes stay consistent in
//  windows, sheets, and popovers without tinting the whole window.
//

import SwiftUI

/// Native presentation style for `WNToggle` (C06).
///
/// Use `.switch` for immediate independent on/off rows inside grouped forms, and `.checkbox` for
/// grouped options or subordinate choices.
enum WNTogglePresentation: Sendable {
    case `switch`
    case checkbox
}

/// A native macOS boolean control with a scoped dark-safe monochrome tint (`WNColor.switchOnTint`).
///
/// Using `switchOnTint` rather than `fillPrimary` keeps the native white `NSSwitch` thumb clearly
/// visible in Dark appearance, and scoping the tint on the control itself keeps sheets and
/// popovers neutral without tinting the entire window.
struct WNToggle<Label: View>: View {
    @Binding var isOn: Bool
    var presentation: WNTogglePresentation = .switch
    @ViewBuilder let label: Label

    var body: some View {
        Group {
            switch presentation {
            case .switch:
                Toggle(isOn: $isOn) { label }.toggleStyle(.switch)
            case .checkbox:
                Toggle(isOn: $isOn) { label }.toggleStyle(.checkbox)
            }
        }
        .tint(WNColor.switchOnTint)
    }
}

extension WNToggle where Label == SwiftUI.Label<Text, Image> {
    /// A title and its leading SF Symbol, used in grouped settings rows.
    init(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        presentation: WNTogglePresentation = .switch
    ) {
        self.init(isOn: isOn, presentation: presentation) {
            SwiftUI.Label(title, systemImage: systemImage)
        }
    }
}

extension WNToggle where Label == Text {
    /// A toggle with a plain text label.
    init(
        _ title: String,
        isOn: Binding<Bool>,
        presentation: WNTogglePresentation = .switch
    ) {
        self.init(isOn: isOn, presentation: presentation) {
            Text(title)
        }
    }
}

#Preview {
    @Previewable @State var withGlyph = true
    @Previewable @State var withoutGlyph = false
    @Previewable @State var checked = true

    Form {
        Section {
            WNToggle("Anonymous Telemetry", systemImage: "waveform.path.ecg", isOn: $withGlyph)
            WNToggle("Audit Logging", isOn: $withoutGlyph)
            WNToggle("Subordinate option", isOn: $checked, presentation: .checkbox)
        }
    }
    .formStyle(.grouped)
    .frame(width: 420)
}
