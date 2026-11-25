//
//  WNToggle.swift
//  whitenoise-mac
//
//  The app's switch — the one way a boolean setting is drawn, wherever it is drawn.
//
//  It exists for the same reason `WNPrimaryButton` does, and it fixes the same defect. A bare
//  `Toggle` carries no colour of its own and takes its "on" track from the environment's tint,
//  whose only app-wide source is `ContentView`'s `.tint(WNColor.fillPrimary)`. Settings sits
//  inside that root and so drew correctly; the "Help Improve White Noise" sheet is a separate
//  presentation that inherits none of it — same trap as `\.locale` — so its two switches fell
//  back to the system accent and drew **blue**, the one hue this palette reserves for links and
//  search hits. Naming the tint on the component makes the switch correct wherever it is used
//  rather than only under the root.
//
//  `wn-ios-prototype` is the reference for the *shape* — a switch for every boolean preference —
//  but deliberately not for how one is coloured. It tints only its App Security pair, per view,
//  from a locally computed black/`systemGray`, and leaves its own diagnostics prompt on the
//  platform default; that split is exactly the inconsistency this component exists to remove. The
//  colour comes from this app's palette instead: `fillPrimary`, near-black on Light and white on
//  Dark, the token every other primary surface here already names.
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

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .switch:
            Toggle(isOn: $isOn) {
                label
            }
            .toggleStyle(.switch)
            .tint(WNColor.switchOnTint)
        case .checkbox:
            Toggle(isOn: $isOn) {
                label
            }
            .toggleStyle(.checkbox)
            .tint(WNColor.switchOnTint)
        }
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
