import MarmotKit
import SwiftUI

struct GroupModerationSection: View {
    let model: GroupSafetyViewModel
    let canModerate: Bool
    let onForgotten: () -> Void
    @State private var isPresented = false

    var body: some View {
        if canModerate {
            Section(L10n.string("Moderation")) {
                Button {
                    isPresented = true
                } label: {
                    HStack {
                        Label(L10n.string("Reports"), systemImage: "exclamationmark.bubble")
                        Spacer()
                        if !model.reports.isEmpty {
                            Text(String(model.reports.count))
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresented) {
                GroupModerationSheet(
                    model: model,
                    dismiss: { isPresented = false },
                    onForgotten: {
                        isPresented = false
                        onForgotten()
                    }
                )
            }
        }
    }
}

private struct GroupModerationSheet: View {
    let model: GroupSafetyViewModel
    let dismiss: () -> Void
    let onForgotten: () -> Void
    @State private var dismissingReport: ContentReportFfi?
    @State private var showsForgetConfirmation = false
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Moderation"))
                    .wnFont(.semiBold18)
                Spacer()
                GlassCircleCloseButton(symbol: "xmark", help: "Close", appearance: .outline, action: dismiss)
            }
            .padding(20)

            GlassSeparator(axis: .horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.reports.isEmpty, !model.isLoadingReports {
                        Text(L10n.string("No reports to review."))
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }

                    ForEach(model.reports.filter { !$0.dismissed }, id: \.reportIdHex) { report in
                        GroupModerationReportCard(
                            report: report,
                            dismiss: { dismissingReport = report }
                        )
                    }

                    if model.nextReportCursor != nil {
                        Button(L10n.string("Load more")) {
                            Task { await model.loadMoreReports() }
                        }
                        .disabled(model.isLoadingReports || model.isModerating)
                    }

                    if model.isLoadingReports {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }

                    if let actionError {
                        SettingsErrorView(error: actionError)
                    }

                    Divider()
                        .padding(.top, 8)

                    Button(L10n.string("Delete Local Group"), role: .destructive) {
                        showsForgetConfirmation = true
                    }
                    .disabled(model.isModerating)
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 640)
        .interactiveDismissDisabled(model.isModerating)
        .confirmationDialog(
            L10n.string("Dismiss Report"),
            isPresented: Binding(
                get: { dismissingReport != nil },
                set: { if !$0 { dismissingReport = nil } }
            ),
            titleVisibility: .visible,
            presenting: dismissingReport
        ) { report in
            Button(L10n.string("Dismiss")) {
                dismissingReport = nil
                Task { await dismiss(report) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.string("Delete local group?"),
            isPresented: $showsForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Delete Local Group"), role: .destructive) {
                Task { await forgetGroup() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "This deletes this group’s local history and state without leaving or ending the group for other members. Downloaded media caches on this device are also cleared. Old invitations cannot restore it; ask a member to send a fresh invitation after the reset."
                )
            )
        }
    }

    private func dismiss(_ report: ContentReportFfi) async {
        do {
            try await model.dismiss(reportIDs: [report.reportIdHex], explanation: "")
            actionError = nil
        } catch {
            actionError = UserFacingError.message(for: error)
        }
    }

    private func forgetGroup() async {
        do {
            if try await model.forgetLocally() {
                onForgotten()
            }
        } catch {
            actionError = UserFacingError.message(for: error)
        }
    }
}

private struct GroupModerationReportCard: View {
    let report: ContentReportFfi
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(ReportPresentation.title(report.reason), systemImage: "exclamationmark.bubble")
                    .wnFont(.semiBold14)
                Spacer()
                Text(Date(timeIntervalSince1970: TimeInterval(report.reportedAt)), style: .date)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            Text(
                String(
                    format: L10n.string("Reported by %@"),
                    DisplayText.short(report.reporter, head: 12, tail: 8)
                )
            )
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            if !report.explanation.isEmpty {
                Text(String(report.explanation.prefix(1_000)))
                    .textSelection(.enabled)
            }
            SettingsValueRow(
                title: L10n.string("Message ID"),
                value: DisplayText.short(report.messageIdHex, head: 12, tail: 8),
                isSelectable: true
            )
            HStack {
                Spacer()
                Button(L10n.string("Dismiss Report"), action: dismiss)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    GroupModerationReportCard(
        report: ContentReportFfi(
            reportIdHex: "report",
            messageIdHex: "message-id",
            messageAuthor: "author",
            reporter: "reporter",
            reason: .spam,
            explanation: "Repeated unsolicited messages",
            reportedAt: 1_700_000_000,
            dismissed: false
        ),
        dismiss: {}
    )
    .padding()
    .frame(width: 620)
}
