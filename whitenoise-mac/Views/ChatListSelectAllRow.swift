import SwiftUI

/// The row at the top of the chat list in selection mode, under the search field and in the same
/// column as the rows' checkmarks. Its checkbox selects every chat (or clears them once all are
/// selected), its box says how many are selected, the chevron offers Select All and Deselect All
/// outright, and Done ends selection mode. Escape is Done.
struct ChatListSelectAllRow: View {
    @Environment(\.locale) private var locale
    let model: ChatListSelectionViewModel

    var body: some View {
        let state = model.selectAllState
        let count = model.orderedSelection.count
        let title =
            state == .empty
            ? L10n.string("Select All", locale: locale)
            : L10n.plural("%lld selected", Int64(count), locale: locale)

        HStack(spacing: 6) {
            Button {
                model.toggleAll()
            } label: {
                ChatListSelectionMark(isSelected: state == .all, isPartial: state == .partial)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            // The same control as the box beside it, so it is off whenever the box is.
            .disabled(!model.canToggleAll)
            // The box beside it is the same control, named; reading both would announce it twice.
            .accessibilityHidden(true)

            HStack(spacing: 4) {
                Button {
                    model.toggleAll()
                } label: {
                    HStack(spacing: 6) {
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .animation(.default, value: count)
                .accessibilityIdentifier("chat.selection.selectAll")

                ChatListSelectAllOptionsButton(model: model)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background {
                ChatListSelectAllBoxBackground(isFilled: state != .empty)
            }
            // Off until MDK has listed the whole view: selecting only the loaded window would act
            // on fewer chats than "all".
            .disabled(!model.canToggleAll)

            Button(L10n.string("Done", locale: locale)) {
                model.end()
            }
            .wnSecondaryButtonStyle()
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("chat.selection.done")
        }
        .disabled(model.isBusy)
    }
}

/// The box drawn like a chat row: filled the way the open chat's row is once something is
/// selected, outlined while nothing is, since a row's resting fill is transparent.
private struct ChatListSelectAllBoxBackground: View {
    let isFilled: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isFilled ? WNColor.fillTertiaryHover : WNColor.fillTertiary)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
            }
    }
}

/// Native menu in the Select All box offering Select All and Deselect All.
private struct ChatListSelectAllOptionsButton: View {
    @Environment(\.locale) private var locale
    let model: ChatListSelectionViewModel

    var body: some View {
        Menu {
            Button {
                model.selectAll()
            } label: {
                Label(L10n.string("Select All", locale: locale), systemImage: "checkmark.circle")
            }
            .disabled(model.selectAllState == .all)
            .accessibilityIdentifier("chat.selection.options.selectAll")

            Button {
                model.deselectAll()
            } label: {
                Label(L10n.string("Deselect All", locale: locale), systemImage: "circle")
            }
            .disabled(model.selectAllState == .empty)
            .accessibilityIdentifier("chat.selection.options.deselectAll")
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("Options", locale: locale))
        .accessibilityLabel(L10n.string("Options", locale: locale))
        .accessibilityIdentifier("chat.selection.options")
    }
}

#Preview("ChatListSelectAllRow — none selected") {
    let model = ChatListSelectionViewModel(accountRef: "preview", runtime: nil)
    model.updateVisibleChats(["a", "b", "c"])
    model.extend(to: "a")
    model.deselectAll()
    return ChatListSelectAllRow(model: model)
        .padding()
        .frame(width: 300)
}

#Preview("ChatListSelectAllRow — some selected") {
    let model = ChatListSelectionViewModel(accountRef: "preview", runtime: nil)
    model.updateVisibleChats(["a", "b", "c"])
    model.begin(with: "a")
    model.toggle("b")
    return ChatListSelectAllRow(model: model)
        .padding()
        .frame(width: 300)
}
