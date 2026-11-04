import SwiftUI

/// Takes the place of the chat list's title row in selection mode: Select All / Deselect All on the
/// leading edge, Done on the trailing one — where iOS puts them in its toolbar. Escape is Done.
struct ChatListSelectionHeaderRow: View {
    @Environment(\.locale) private var locale
    let model: ChatListSelectionViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button(
                L10n.string(model.allVisibleSelected ? "Deselect All" : "Select All", locale: locale)
            ) {
                model.toggleAll()
            }
            .buttonStyle(.wnSecondary)
            .accessibilityIdentifier("chat.selection.selectAll")

            Spacer(minLength: 8)

            Button(L10n.string("Done", locale: locale)) {
                model.end()
            }
            .buttonStyle(.wnSecondary)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("chat.selection.done")
        }
        .disabled(model.isBusy)
        .frame(minHeight: 34)
    }
}

#Preview("ChatListSelectionHeaderRow") {
    ChatListSelectionHeaderRow(model: ChatListSelectionViewModel(accountRef: "preview", runtime: nil))
        .padding()
        .frame(width: 280)
}
