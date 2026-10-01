import SwiftUI

/// The "New messages" rule above the first row that was unread when the conversation opened.
/// It takes no model: where it goes is decided by the transcript, which places it once per open.
struct UnreadMessagesDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            UnreadMessagesDividerRule()
            Text(L10n.string("New messages"))
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.intentionInfoContent)
                .fixedSize()
            UnreadMessagesDividerRule()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct UnreadMessagesDividerRule: View {
    var body: some View {
        Rectangle()
            .fill(WNColor.intentionInfoContent.opacity(0.45))
            .frame(height: 1)
    }
}

#Preview {
    VStack(spacing: 12) {
        Text(verbatim: "Earlier message")
        UnreadMessagesDivider()
        Text(verbatim: "First unread message")
    }
    .padding(28)
    .frame(width: 420)
}
