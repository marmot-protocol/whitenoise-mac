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

/// Persistent sidebar banner surfacing account security and device-sync warnings with a direct
/// Review route to Settings → Devices. Never auto-dismisses or auto-acknowledges warnings.
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !summary.compromiseMessages.isEmpty {
                WNCallout(
                    title: L10n.string("Someone Else May Have Your Private Key", locale: locale),
                    message: summary.compromiseMessages.joined(separator: "\n"),
                    intent: .error
                )
            }

            if summary.isDeviceGroupStalled {
                WNCallout(
                    title: L10n.string("This Mac Can’t Catch Up With Your Other Devices", locale: locale),
                    message: L10n.string(
                        "Reset this Mac’s copy of your device list, then link it again. Your chats and messages stay on this Mac.",
                        locale: locale
                    ),
                    intent: .warning
                )
            }

            if summary.isKeyPackageRefreshOverdue {
                WNCallout(
                    title: L10n.string("Key Package Refresh Overdue", locale: locale),
                    message: L10n.string(
                        "Your devices couldn’t sync this Mac’s new key package. After 30 days, people may not be able to add this Mac to chats.",
                        locale: locale
                    ),
                    intent: .warning
                )
            }

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
