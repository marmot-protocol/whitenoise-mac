import MarmotKit
import SwiftUI

/// Reports one message: to the group's members, privately to the White Noise team, or both.
/// What goes where is `ReportMessageViewModel`'s; this view only lays it out.
struct ReportMessageSheet: View {
    let model: ReportMessageViewModel
    let dismiss: () -> Void
    @State private var operation: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("Report Message"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WNColor.textPrimary)

                ReportReasonPicker(reason: $model.reason)
                    .disabled(model.isLocked)

                TextField(
                    L10n.string("Explanation (optional)"),
                    text: $model.explanation,
                    axis: .vertical
                )
                .font(.body)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .disabled(model.isLocked)

                if model.reportsToGroup {
                    ReportSheetFootnote(
                        text: L10n.string(
                            "Reports are shared inside this encrypted group. Group members can read your report and explanation."
                        )
                    )
                }

                if model.canReportToTeam {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.reportsToGroup {
                            WNToggle(
                                L10n.string("Send to White Noise"),
                                isOn: $model.sendsToTeam,
                                presentation: .checkbox
                            )
                            .disabled(model.isLocked)
                        }
                        if model.reportsToTeam {
                            ReportSheetFootnote(
                                text: L10n.string(
                                    "Your report and the sender’s public key are sent privately to the White Noise team. The message itself isn’t shared, and the sender isn’t notified."
                                )
                            )
                        }
                    }
                }

                if let error = model.error {
                    ReportSheetErrorText(message: error)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button(L10n.string("Cancel"), action: dismiss)
                    .wnSecondaryButtonStyle()
                    .disabled(model.isSending)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(L10n.string("Report")) {
                    operation = Task {
                        await model.submit()
                        if model.isSubmitted { dismiss() }
                    }
                }
                .wnPrimaryButtonStyle()
                .disabled(!model.canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .interactiveDismissDisabled(model.isSending)
        .onDisappear {
            operation?.cancel()
            operation = nil
        }
    }
}

private struct ReportReasonPicker: View {
    @Binding var reason: ReportReasonFfi

    var body: some View {
        Picker(L10n.string("Reason"), selection: $reason) {
            ForEach(ReportPresentation.reasons, id: \.self) { reason in
                Text(ReportPresentation.title(reason)).tag(reason)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct ReportSheetFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(WNColor.messageReceivedSecondaryContent)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReportSheetErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(WNColor.intentionErrorContent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Group and White Noise") {
    ReportMessageSheet(
        model: ReportMessageViewModel(
            eligibility: MessageModerationEligibility(
                reportsToGroup: true,
                reportsToTeam: true,
                canBlockAuthor: true,
                authorAccountIdHex: String(repeating: "a", count: 64)
            ),
            dependencies: .inert
        ),
        dismiss: {}
    )
}

#Preview("Direct chat") {
    ReportMessageSheet(
        model: ReportMessageViewModel(
            eligibility: MessageModerationEligibility(
                reportsToGroup: false,
                reportsToTeam: true,
                canBlockAuthor: true,
                authorAccountIdHex: String(repeating: "a", count: 64)
            ),
            dependencies: .inert
        ),
        dismiss: {}
    )
}
