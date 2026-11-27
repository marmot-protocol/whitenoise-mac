import MarmotKit
import SwiftUI

/// The rule over the first live message after chat history copied from another of the account's
/// devices (or restored from a backup): everything above it arrived that way. Matches
/// `whitenoise-ios`'s boundary marker.
struct ImportedHistoryDivider: View {
    let source: MessageImportSource
    /// The device's current name, or nil to say "another device".
    let deviceName: String?

    var body: some View {
        HStack(spacing: 10) {
            ImportedHistoryDividerRule()
            Text(Self.text(source: source, deviceName: deviceName))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ImportedHistoryDividerRule()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    static func text(source: MessageImportSource, deviceName: String?) -> String {
        switch source {
        case .backup:
            L10n.string("Messages above were restored from a backup")
        case .device:
            String(
                format: L10n.string("Messages above came from %@"),
                deviceName ?? L10n.string("another device"))
        }
    }
}

private struct ImportedHistoryDividerRule: View {
    var body: some View {
        Rectangle()
            .fill(WNColor.borderTertiary)
            .frame(height: 1)
    }
}

/// Progress, not a warning: another of the account's devices is sending this chat's earlier
/// messages. Gone once they're imported; it can't be dismissed.
struct ChatHistoryReceivingNotice: View {
    let model: DeviceLinkingViewModel
    let groupIdHex: String

    var body: some View {
        if case .receiving(let retrying) = model.historyImportState(groupIdHex: groupIdHex) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    retrying
                        ? L10n.string("Still trying to bring earlier messages from your other device…")
                        : L10n.string("Bringing earlier messages from your other device…")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

#Preview("Divider") {
    VStack(spacing: 12) {
        Text(verbatim: "Imported message")
        ImportedHistoryDivider(source: .device(slotIdHex: "a", label: ""), deviceName: "iPhone")
        ImportedHistoryDivider(source: .backup, deviceName: nil)
        Text(verbatim: "Live message")
    }
    .padding(28)
    .frame(width: 420)
}

#Preview("Receiving notice") {
    ChatHistoryReceivingNotice(model: .preview(), groupIdHex: "a")
        .padding(16)
        .frame(width: 420)
}
