//
//  WNSelect.swift
//  whitenoise-mac
//
//  The app's single-selection list — one row per option, a checkmark on the chosen one.
//
//  It exists for the same reason `WNToggle` does. A bare `Picker(.inline)` has no appearance
//  of its own: on iOS it draws the checkmark rows `wn-ios-prototype` shows, and on macOS the
//  very same code draws a column of **radio buttons**. The prototype's own idiom is a plain
//  `Button` per option with a semibold trailing `checkmark` — the shape it uses everywhere a
//  choice is made from a list, Sent Media Quality and Auto-Download among them — so that shape
//  is what this draws, on the platform whose `Picker` would not have drawn it.
//
//  The unchosen options are set back to `backgroundContentSecondary` rather than left at full
//  strength. A radio column is read by finding the filled dot; this list is read by finding the
//  line that is still dark, which is why the chosen option keeps the primary rung and the
//  checkmark alongside it.
//
//  The mark names `fillPrimary` rather than taking `.tint`. Under `ContentView` the two resolve
//  to the same value — that root is where the app's tint comes from — so inside settings this is
//  a distinction without a difference. It stops being one the moment a choice is offered in a
//  sheet, which inherits no tint and would fall back to the system accent: blue, the one hue this
//  palette reserves for links and search hits. That is the defect `WNToggle` was written to fix,
//  and a component meant to be usable off this surface should not re-open it.
//

import SwiftUI

/// A choice made from a short list of alternatives, drawn as the alternatives themselves.
///
/// Emits one row per option, so it goes directly inside a `Section` — `SettingsSection` in
/// settings — rather than carrying a group of its own. A pop-up hides every option but the
/// chosen one, which is the wrong trade for a setting whose options *are* the explanation:
/// what Light and Dark mean is only clear next to System, and how much of a message a
/// notification may repeat is only clear next to what it would withhold. Keep it to a handful;
/// a long list wants the menu back.
struct WNSelect<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        ForEach(options, id: \.self) { option in
            WNSelectRow(title: label(option), isSelected: option == selection) {
                selection = option
            }
        }
    }
}

/// One option, and whether it is the chosen one.
///
/// The whole row is the target, not just its text: without `contentShape` the row is clickable
/// only where the label's glyphs are, and the empty middle of a `Form` row is most of it.
///
/// The checkmark keeps its place in the layout when this is not the chosen row — hidden with
/// `opacity` rather than an `if` — so the labels do not shift sideways as the selection moves,
/// and every row reserves the same trailing column.
///
/// `isEnabled` is read rather than inherited because naming the colours costs the automatic
/// dimming a `.plain` button would otherwise get — a disabled group would have gone on drawing
/// its selection at full strength.
struct WNSelectRow: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(titleColor)

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(checkmarkColor)
                    .opacity(isSelected ? 1 : 0)
                    // The row already carries `.isSelected`; a second announcement of the same
                    // fact is noise, and the glyph has no name of its own worth reading.
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var titleColor: Color {
        guard isEnabled else { return WNColor.backgroundContentTertiary }
        return isSelected ? WNColor.backgroundContentPrimary : WNColor.backgroundContentSecondary
    }

    private var checkmarkColor: Color {
        isEnabled ? WNColor.fillPrimary : WNColor.backgroundContentTertiary
    }
}

#Preview {
    @Previewable @State var theme = "System"

    Form {
        Section {
            WNSelect(options: ["System", "Light", "Dark"], selection: $theme) { $0 }
        } header: {
            Text(verbatim: "Theme")
        }
    }
    .formStyle(.grouped)
    .frame(width: 420)
}
