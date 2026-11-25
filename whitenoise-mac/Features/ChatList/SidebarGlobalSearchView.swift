import SwiftUI

struct SidebarGlobalSearchRow: View {
    @Environment(\.locale) private var locale
    let result: GlobalMessageSearchResult
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.chatTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(
                        DisplayText.dateTimeTimestamp(
                            for: Date(timeIntervalSince1970: TimeInterval(result.timelineAt)),
                            locale: locale
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Text(result.senderName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                SearchMatchHighlightStyle.text(result.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18) : .clear)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(WNColor.borderPrimary, lineWidth: 1)
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message.search.result.\(result.messageId)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    SidebarGlobalSearchRow(
        result: GlobalMessageSearchResult(
            messageId: "hello", groupId: "group", chatTitle: "River Loop", senderName: "Mara", timelineAt: 0,
            snippet: .init(leading: "Meet at the ", match: "north", trailing: " entrance")), isSelected: false,
        onOpen: {}
    )
    .frame(width: 260)
}
