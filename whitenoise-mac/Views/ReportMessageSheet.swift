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
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("Report Message"))
                .wnFont(.semiBold18)

            ReportReasonPicker(reason: $model.reason)
                .disabled(model.isLocked)

            TextField(
                L10n.string("Explanation (optional)"),
                text: $model.explanation,
                axis: .vertical
            )
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
                        Toggle(L10n.string("Send to White Noise"), isOn: $model.sendsToTeam)
                            .toggleStyle(.checkbox)
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
                SettingsErrorView(error: error)
            }

            HStack {
                Button(L10n.string("Cancel"), action: dismiss)
                    .disabled(model.isSending)
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
                .nativeGlassProminentButtonStyle()
                .disabled(!model.canSubmit)
            }
        }
        .padding(24)
        .frame(width: 520)
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
    }
}

private struct ReportSheetFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentSecondary)
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
