//
//  GroupDisbandStatusSection.swift
//  whitenoise-mac
//
//  Where a group stands once someone set out to end it: ending, ended, or an attempt of this
//  account's that stopped and is waiting to be dismissed.
//

import MarmotKit
import SwiftUI

struct GroupDisbandStatusSection: View {
    let status: GroupDisbandStatus
    var isDismissing = false
    let onDismiss: () -> Void

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case .pending:
            Section(L10n.string("Group Status")) {
                GroupDisbandStatusRow(
                    title: L10n.string("Ending group…"),
                    detail: L10n.string(
                        "Everyone is being removed. Messaging and group changes are disabled while the final update is processed."
                    )
                ) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .failed(let reason):
            Section(L10n.string("Group Status")) {
                GroupDisbandStatusRow(title: GroupDisbandPresentation.failureMessage(reason)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(WNColor.intentionWarningContent)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.string("Dismiss"), action: onDismiss)
                        .buttonStyle(.wnSecondary)
                        .disabled(isDismissing)
                }
            }
        case .disbanded:
            Section(L10n.string("Group Status")) {
                GroupDisbandStatusRow(
                    title: L10n.string("Group ended"),
                    detail: L10n.string(
                        "This group was permanently disbanded. No one can send new messages or make group changes."
                    )
                ) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
        }
    }
}

/// One status line: a leading mark, a title, and an optional explanation beneath it — the shape
/// `GroupMembershipStatusSections` gives an ended membership.
private struct GroupDisbandStatusRow<Icon: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let icon: Icon

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .wnFont(.semiBold12)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            icon
        }
    }
}

#Preview {
    Form {
        GroupDisbandStatusSection(status: .pending, onDismiss: {})
        GroupDisbandStatusSection(status: .failed(.noLongerAdmin), onDismiss: {})
        GroupDisbandStatusSection(status: .disbanded, onDismiss: {})
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 420)
}
