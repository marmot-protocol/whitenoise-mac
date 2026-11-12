import MarmotKit
import SwiftUI

struct QuarantinedGroupsSettingsView: View {
    let model: QuarantinedGroupsViewModel

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Quarantined Groups"),
            back: .developerMode
        ) {
            SettingsSection(
                footer: L10n.string(
                    "Marmot quarantines a stored group when it cannot safely hydrate its MLS state. Retrying is non-destructive: it does not delete history, bypass validation, or rejoin the group."
                )
            ) {
                if model.groups.isEmpty {
                    Label(L10n.string("No Quarantined Groups"), systemImage: "checkmark.shield")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                } else {
                    ForEach(model.groups, id: \.groupIdHex) { group in
                        QuarantinedGroupSettingsRow(
                            group: group,
                            isRetrying: model.retryingGroupIDs.contains(group.groupIdHex),
                            onRetry: {
                                Task { await model.retry(group.groupIdHex) }
                            }
                        )
                    }
                }
            }

            if let error = model.error {
                SettingsSection(title: L10n.string("Load Failed")) {
                    SettingsErrorView(error: error.message)
                    Button(L10n.string("Retry Loading")) {
                        Task { await model.load() }
                    }
                }
            }
        }
        .task {
            await model.load()
        }
    }
}

private struct QuarantinedGroupSettingsRow: View {
    let group: AppQuarantinedGroupFfi
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsValueRow(
                title: L10n.string("Group ID"),
                value: DisplayText.short(group.groupIdHex, head: 12, tail: 8),
                isSelectable: true
            )

            Label(QuarantinedGroupReason.title(group.reason), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            if QuarantinedGroupReason.canRetry(group.reason) {
                Button(action: onRetry) {
                    SettingsBusyLabel(
                        title: L10n.string("Retry Recovery"),
                        systemImage: "arrow.clockwise",
                        isBusy: isRetrying
                    )
                }
                .buttonStyle(.wnSecondary)
                .disabled(isRetrying)
            } else {
                Text(L10n.string("Quit and reopen White Noise to restore this group."))
                    .font(.callout)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

nonisolated enum QuarantinedGroupReason {
    static func title(_ reason: AppGroupHydrationQuarantineReasonFfi) -> String {
        switch reason {
        case .openMlsLoadFailed: L10n.string("OpenMLS load failed")
        case .openMlsGroupMissing: L10n.string("OpenMLS group missing")
        case .memberValidationFailed: L10n.string("Member validation failed")
        case .groupRecordLoadFailed: L10n.string("Group record load failed")
        case .pendingCommitRecoveryFailed: L10n.string("Pending commit recovery failed")
        case .rewindRestoreFailed: L10n.string("Rewind restore failed")
        }
    }

    /// MarmotKit 0.16.0: a group whose rewind could not be restored is retried only by the next
    /// account open. `retryHydrateQuarantinedGroup` always answers `false` for it, so a Retry
    /// button would do nothing.
    static func canRetry(_ reason: AppGroupHydrationQuarantineReasonFfi) -> Bool {
        reason != .rewindRestoreFailed
    }
}

#Preview {
    QuarantinedGroupsSettingsView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 640)
}
