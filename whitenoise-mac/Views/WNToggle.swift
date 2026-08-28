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

/// A boolean setting, drawn as a switch tinted `fillPrimary`.
///
/// `.switch` is named rather than inherited. Inside a grouped `Form` macOS already resolves the
/// default toggle style to a switch, which is why settings looked right, but outside one it
/// resolves to a checkbox — so a `WNToggle` placed on a bare pane or in a sheet's own layout
/// would have changed shape depending on what happened to enclose it. The prototype draws one
/// switch everywhere; naming the style is what makes that true here too.
///
/// The label is whatever the call site passes. Settings pairs a title with its SF Symbol — the
/// glyph is what makes a scanned column of switches legible, the same argument the sidebar row
/// makes one level up — and `init(_:systemImage:isOn:)` is that shape. Nothing here explains the
/// setting: that is the enclosing `SettingsSection`'s footer, or the sheet's own copy.
struct WNToggle<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let label: Label

    var body: some View {
        Toggle(isOn: $isOn) {
            label
        }
        .toggleStyle(.switch)
        .tint(WNColor.fillPrimary)
    }
}

extension WNToggle where Label == SwiftUI.Label<Text, Image> {
    /// The common case: a title and its leading SF Symbol, the shape every switch in settings
    /// takes.
    init(_ title: String, systemImage: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) {
            SwiftUI.Label(title, systemImage: systemImage)
        }
    }
}

extension WNToggle where Label == Text {
    /// A switch with no glyph, for a row that is not part of a scanned column.
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) {
            Text(title)
        }
    }
}

#Preview {
    @Previewable @State var withGlyph = true
    @Previewable @State var withoutGlyph = false

    Form {
        Section {
            WNToggle("Anonymous Telemetry", systemImage: "waveform.path.ecg", isOn: $withGlyph)
            WNToggle("Audit Logging", isOn: $withoutGlyph)
        }
    }
    .formStyle(.grouped)
    .frame(width: 420)
}
