import MarmotKit
import SwiftUI

/// Summarizes persistent account-level security and device-group warnings from
/// `DeviceLinkingViewModel` so they remain reachable in the main window sidebar rather than only
/// inside Settings → Devices (E07, #1112).
///
/// Presenting these notices never acknowledges or dismisses them; dismissal stays an explicit user
/// action on the Devices page.
nonisolated struct AccountDeviceWarningSummary: Equatable, Sendable {
    let compromiseMessages: [String]
    let isDeviceGroupStalled: Bool
    let isKeyPackageRefreshOverdue: Bool

    var hasWarnings: Bool {
        !compromiseMessages.isEmpty || isDeviceGroupStalled || isKeyPackageRefreshOverdue
    }

    var warningCount: Int {
        (compromiseMessages.isEmpty ? 0 : 1)
            + (isDeviceGroupStalled ? 1 : 0)
            + (isKeyPackageRefreshOverdue ? 1 : 0)
    }

    static func from(
        compromiseItems: [CompromiseWarningItemFfi],
        deviceGroupStalled: Bool,
        keyPackageRefreshOverdue: Bool
    ) -> Self {
        Self(
            compromiseMessages: compromiseItems.map { DeviceLinkPresentation.message(for: $0) },
            isDeviceGroupStalled: deviceGroupStalled,
            isKeyPackageRefreshOverdue: keyPackageRefreshOverdue
        )
    }
}

/// Compact persistent sidebar banner surfacing account security and device-sync warnings with a
/// direct Review route to Settings → Devices. Keeps the sidebar bounded so multiple compromise
/// records never crowd out the chat list; full records and repair actions live on Settings → Devices.
struct AccountDeviceWarningsBanner: View {
    let model: DeviceLinkingViewModel
    let onOpenDevicesSettings: () -> Void

    var body: some View {
        let summary = AccountDeviceWarningSummary.from(
            compromiseItems: model.compromiseItems,
            deviceGroupStalled: model.snapshot.deviceGroupStalled,
            keyPackageRefreshOverdue: model.keyPackageRefreshOverdue
        )
        if summary.hasWarnings {
            AccountDeviceWarningsBannerContent(
                summary: summary,
                onReview: onOpenDevicesSettings
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct AccountDeviceWarningsBannerContent: View {
    @Environment(\.locale) private var locale
    let summary: AccountDeviceWarningSummary
    let onReview: () -> Void

    private var primaryIntent: WNCalloutIntent {
        summary.compromiseMessages.isEmpty ? .warning : .error
    }

    private var primaryTitle: String {
        if !summary.compromiseMessages.isEmpty {
            return L10n.string("Someone Else May Have Your Private Key", locale: locale)
        }
        if summary.isDeviceGroupStalled {
            return L10n.string("This Mac Can’t Catch Up With Your Other Devices", locale: locale)
        }
        return L10n.string("Key Package Refresh Overdue", locale: locale)
    }

    private var primaryMessage: String {
        if let first = summary.compromiseMessages.first {
            return first
        }
        if summary.isDeviceGroupStalled {
            return L10n.string(
                "Reset this Mac’s copy of your device list, then link it again. Your chats and messages stay on this Mac.",
                locale: locale
            )
        }
        return L10n.string(
            "Your devices couldn’t sync this Mac’s new key package. After 30 days, people may not be able to add this Mac to chats.",
            locale: locale
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            WNCallout(
                title: primaryTitle,
                message: primaryMessage,
                intent: primaryIntent
            )
            .lineLimit(2)

            Button(L10n.string("Review", locale: locale), action: onReview)
                .wnSecondaryButtonStyle()
                .controlSize(.small)
                .accessibilityIdentifier("sidebar.securityWarning.review")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.securityWarning")
    }
}

#Preview("Security warnings") {
    VStack(spacing: 12) {
        AccountDeviceWarningsBannerContent(
            summary: AccountDeviceWarningSummary(
                compromiseMessages: ["An unrecognized sign-in appeared on another device."],
                isDeviceGroupStalled: false,
                isKeyPackageRefreshOverdue: false
            ),
            onReview: {}
        )
        AccountDeviceWarningsBannerContent(
            summary: AccountDeviceWarningSummary(
                compromiseMessages: [],
                isDeviceGroupStalled: true,
                isKeyPackageRefreshOverdue: true
            ),
            onReview: {}
        )
    }
    .padding()
    .frame(width: 320)
}
