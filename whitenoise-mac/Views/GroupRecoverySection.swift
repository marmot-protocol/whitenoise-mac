import MarmotKit
import SwiftUI

struct GroupRecoverySection: View {
    let model: GroupSafetyViewModel
    @State private var selection: GroupRejoinSelection?

    var body: some View {
        let historyNoticeIds = model.historyNoticeIds
        if !historyNoticeIds.isEmpty {
            Section {
                HistoryNoticeBanner(
                    message: model.historyNoticeMessage,
                    isDismissing: model.isDismissingHistoryNotice,
                    onDismiss: { Task { await model.dismissHistoryNotice() } }
                )
            }
        }
        if let recovery = model.recovery, recovery.requiresAttention {
            Section(L10n.string("Invitation")) {
                GroupRecoveryStatusRows(status: recovery)

                ForEach(recovery.rejoinInvitations, id: \.welcomeIdHex) { invitation in
                    Button {
                        selection = GroupRejoinSelection(invitation: invitation)
                    } label: {
                        Label(L10n.string("Invitation"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .sheet(item: $selection) { selection in
                GroupRejoinInvitationSheet(
                    invitation: selection.invitation,
                    model: model,
                    dismiss: { self.selection = nil }
                )
            }
        } else if let error = model.error {
            Section {
                SettingsErrorView(error: error)
                Button(L10n.string("Retry")) {
                    Task { await model.load(canModerate: model.canModerate) }
                }
            }
        }
    }
}

private struct GroupRejoinSelection: Identifiable {
    let invitation: GroupRejoinInvitationFfi
    var id: String { invitation.welcomeIdHex }
}

private struct GroupRecoveryStatusRows: View {
    let status: GroupRecoveryStatusFfi

    var body: some View {
        if status.automaticRecoveryFailed {
            Label(L10n.string("Pending commit recovery failed"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if status.pendingReinvites > 0 {
            SettingsValueRow(
                title: L10n.string("Pending"),
                value: String(status.pendingReinvites)
            )
        }
        if status.failedReinvites > 0 {
            SettingsValueRow(
                title: L10n.string("Failed"),
                value: String(status.failedReinvites)
            )
        }
    }
}

private struct GroupRejoinInvitationSheet: View {
    let invitation: GroupRejoinInvitationFfi
    let model: GroupSafetyViewModel
    let dismiss: () -> Void
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("Invitation"))
                .wnFont(.semiBold18)

            SettingsValueRow(
                title: L10n.string("Public Key"),
                value: DisplayText.short(invitation.welcomerAccountIdHex, head: 12, tail: 8),
                isSelectable: true
            )
            SettingsValueRow(
                title: L10n.string("Epoch"),
                value: String(invitation.epoch)
            )

            Text(
                L10n.string(
                    "Accept this invite to confirm membership, or decline it to remove the group from your chat list."
                )
            )
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let actionError {
                SettingsErrorView(error: actionError)
            }

            HStack {
                Button(L10n.string("Cancel"), action: dismiss)
                    .disabled(model.isApplyingRecoveryDecision)
                Spacer()
                Button(L10n.string("Decline"), role: .destructive) {
                    Task { await decide(confirm: false) }
                }
                .disabled(model.isApplyingRecoveryDecision)
                Button(L10n.string("Accept")) {
                    Task { await decide(confirm: true) }
                }
                .nativeGlassProminentButtonStyle()
                .disabled(model.isApplyingRecoveryDecision)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isApplyingRecoveryDecision)
    }

    private func decide(confirm: Bool) async {
        do {
            if confirm {
                try await model.confirm(invitation)
            } else {
                try await model.decline(invitation)
            }
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private extension GroupRecoveryStatusFfi {
    var requiresAttention: Bool {
        automaticRecoveryFailed || pendingReinvites > 0 || failedReinvites > 0 || !rejoinInvitations.isEmpty
    }
}

#Preview {
    Form {
        GroupRecoveryStatusRows(
            status: GroupRecoveryStatusFfi(
                groupIdHex: "group",
                automaticRecoveryFailed: true,
                pendingReinvites: 1,
                failedReinvites: 0,
                rejoinInvitations: []
            )
        )
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 280)
}
