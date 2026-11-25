//
//  HelpImproveWhiteNoiseSheet.swift
//  whitenoise-mac
//
//  The one-time data-sharing choice, offered over Chats the first time an identity gets there on
//  a Mac that has not answered it yet.
//
//  Worded and behaving as iOS's `DiagnosticsConsentSheet` does: the two switches first, each saying
//  what it shares, then a footer that says the choice covers every account on this device and where
//  to change it, with a "What’s shared" link to the full disclosure. The choices apply the moment
//  they are flipped, so there is no Save and no Cancel — only closing, which records "leave both
//  off" as a decline when nothing was chosen, so MarmotKit's receipt stops being pending and a
//  second account signed up on this Mac is not asked again. Done stays up if that write fails;
//  ✕ closes regardless, leaving the receipt pending, so the sheet can always be dismissed.
//
//  The two switches are `DataSharingToggleRows`, the same rows Privacy & Security shows, so this
//  offers exactly the settings it claims to and cannot drift from them.
//

import SwiftUI

struct HelpImproveWhiteNoiseSheet: View {
    let model: DiagnosticsSettingsViewModel
    let onClose: () -> Void

    @State private var showsSharingDetails = false
    @State private var isFinishing = false

    var body: some View {
        VStack(spacing: 0) {
            HelpImproveWhiteNoiseHeader(
                showsSharingDetails: showsSharingDetails,
                isCloseDisabled: isFinishing || !model.canFinishPrompt,
                onBack: { showsSharingDetails = false },
                onClose: { finish(using: model.dismissPrompt) }
            )
            Divider()
            if showsSharingDetails {
                DiagnosticsSharingDetailsView()
            } else {
                HelpImproveWhiteNoiseChoices(
                    model: model,
                    onShowSharingDetails: { showsSharingDetails = true }
                )
            }
            Divider()
            HelpImproveWhiteNoiseFooter(
                isDisabled: isFinishing || !model.canFinishPrompt,
                onDone: { finish(using: model.finishPrompt) }
            )
        }
        .frame(width: 480, height: 460)
        .task {
            if model.settings == nil { await model.load() }
        }
    }

    /// Done closes only once a pending receipt has been written as declined; a failed write leaves
    /// the sheet up with its error showing. ✕ closes even then, so a failing write cannot trap it.
    private func finish(using attempt: @escaping @MainActor () async -> Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            let canClose = await attempt()
            isFinishing = false
            if canClose { onClose() }
        }
    }
}

/// The title — or "What’s shared" with a Back chevron while the disclosure is up — and the ✕.
///
/// `.outline` rather than the glass disc, which reads as a primary action and would compete with
/// `Done` below. `help:` takes the catalog *key* — `GlassCircleCloseButton` localizes it itself.
private struct HelpImproveWhiteNoiseHeader: View {
    let showsSharingDetails: Bool
    /// Only the ✕: while a write is in flight it could not close anyway, and Back is just
    /// navigation inside the sheet.
    let isCloseDisabled: Bool
    let onBack: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsSharingDetails {
                GlassCircleCloseButton(symbol: "chevron.left", help: "Back", appearance: .outline, action: onBack)
                Text(L10n.string("What’s shared"))
                    .font(.headline)
            } else {
                Text(L10n.string("Help Improve White Noise"))
                    .font(.headline)
            }
            Spacer()
            GlassCircleCloseButton(appearance: .outline, action: onClose)
                .disabled(isCloseDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct HelpImproveWhiteNoiseChoices: View {
    let model: DiagnosticsSettingsViewModel
    let onShowSharingDetails: () -> Void

    var body: some View {
        Form {
            Section {
                DataSharingToggleRows(model: model)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = model.promptExplanation {
                        Text(explanation)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(
                        L10n.string(
                            "These choices apply to all accounts on this device. You can change them anytime in Settings → Privacy & Security → Diagnostics & Improvements."
                        )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Button(action: onShowSharingDetails) {
                        Text(L10n.string("What’s shared")).underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                }
                .font(.caption)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A build with no telemetry or audit credentials refuses the write and reports why.
            // Without this the switch would spring back under the pointer with no explanation.
            SettingsErrorView(error: model.error?.message)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct HelpImproveWhiteNoiseFooter: View {
    let isDisabled: Bool
    let onDone: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onDone) {
                Text(L10n.string("Done"))
            }
            .wnPrimaryButtonStyle()
            .keyboardShortcut(.defaultAction)
            .disabled(isDisabled)
        }
        .wnSheetFooterButtons()
        .padding(16)
    }
}

#Preview {
    HelpImproveWhiteNoiseSheet(model: .preview(), onClose: {})
}
