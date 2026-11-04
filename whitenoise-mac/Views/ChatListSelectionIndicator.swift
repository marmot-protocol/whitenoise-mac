import SwiftUI

/// The checkmark a chat row shows in selection mode. Its own view so that toggling one chat
/// re-renders only these indicators — the row around it observes nothing but `isActive`.
struct ChatListSelectionIndicator: View {
    let model: ChatListSelectionViewModel
    let groupIdHex: String

    var body: some View {
        ChatListSelectionMark(isSelected: model.isSelected(groupIdHex))
    }
}

/// The mark itself, separated from the model so it can be previewed and measured on its own.
struct ChatListSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Group {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(WNColor.fillContentPrimary, WNColor.fillPrimary)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }
        }
        .wnFont(.medium16)
        .frame(width: 20)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
    }
}

#Preview("ChatListSelectionMark") {
    HStack(spacing: 12) {
        ChatListSelectionMark(isSelected: false)
        ChatListSelectionMark(isSelected: true)
    }
    .padding()
}
