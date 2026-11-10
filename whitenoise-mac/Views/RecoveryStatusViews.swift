import SwiftUI

/// A small spinner and a line of text, for history MDK is still fetching.
struct CatchingUpLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
            Text(text)
        }
        .foregroundStyle(WNColor.backgroundContentSecondary)
        .accessibilityElement(children: .combine)
    }
}

/// Under the chat list header while the account's inbox or any of its chats is still catching up
/// after time offline, so a quiet list does not read as an up-to-date one. Each chat's own header
/// says so too (`ConversationHeader`).
struct AccountCatchingUpRow: View {
    let model: AccountRecoveryStatusViewModel

    var body: some View {
        if model.isCatchingUp {
            CatchingUpLabel(text: L10n.string("Catching up on messages…"))
                .wnFont(.medium12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .help(L10n.string("White Noise is fetching messages from while this device was offline."))
        }
    }
}

#Preview("Catching up") {
    AccountCatchingUpRow(model: .preview(inboxCatchingUp: true))
        .frame(width: 320)
}

#Preview("Header label") {
    CatchingUpLabel(text: L10n.string("Catching up…"))
        .wnFont(.medium10)
        .padding()
}
