//
//  PickerSearchField.swift
//  whitenoise-mac
//
//  Shared search bar for composer pickers (emoji, GIFs, emoji sets, and sticker packs).
//

import SwiftUI

/// Rounded-border search field with an inline clear button and optional focus-on-appear.
///
/// Escape handling intentionally lives on the enclosing picker or browser page rather than on this
/// text field so pressing Escape still clears a non-empty query first even after keyboard focus
/// moves to a result or button (C13).
struct PickerSearchField: View {
    let prompt: String
    @Binding var text: String
    var showsSearchIcon = true
    var focusOnAppear = false
    var accessibilityIdentifier: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: showsSearchIcon ? 8 : 6) {
            if showsSearchIcon {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Clear search"))
                .accessibilityLabel(L10n.string("Clear search"))
            }
        }
        .onAppear {
            if focusOnAppear {
                isFocused = true
            }
        }
    }
}

extension View {
    /// Handles Escape anywhere inside a picker popover or sub-page regardless of which control
    /// currently holds keyboard focus (C13). Safe inside popover windows because the shortcut is
    /// scoped to the popover's own window rather than the main conversation window.
    func pickerEscapeHandler(_ action: @escaping () -> Void) -> some View {
        background {
            Button(action: action) { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

#Preview("PickerSearchField") {
    @Previewable @State var query = "wave"
    PickerSearchField(prompt: L10n.string("Search emoji"), text: $query)
        .padding()
        .frame(width: 360)
}
