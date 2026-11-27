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
    @Previewable @State var choice = "Off"

    Form {
        Section {
            WNSelectRow(title: "Off", isSelected: choice == "Off") { choice = "Off" }
            WNSelectRow(title: "24 hours", isSelected: choice == "24 hours") { choice = "24 hours" }
            WNSelectRow(title: "7 days", isSelected: choice == "7 days") { choice = "7 days" }
        } header: {
            Text(verbatim: "Disappearing messages")
        }
    }
    .formStyle(.grouped)
    .frame(width: 420)
}
