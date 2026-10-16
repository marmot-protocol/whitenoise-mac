import MarmotKit
import SwiftUI

/// One setup step's own screen, opened from its checklist row or from Review and Continue.
///
/// `whitenoise-ios` opens these as sheets over the sign-in list — `AccountSetupActions` routes to a
/// profile form, a relay screen, a device notice or a secure-messaging retry — and so does the mac:
/// a sheet keeps the checklist behind it as the place the user returns to. It closes itself once
/// the step passes or is skipped.
struct AccountSetupStepSheet: View {
    let model: OnboardingCoordinator
    let step: OnboardingStepFfi
    @Environment(\.dismiss) private var dismiss

    private var stepState: OnboardingStepStateFfi? {
        model.snapshot?.steps.first { $0.step == step }
    }

    var body: some View {
        VStack(spacing: 0) {
            AccountSetupStepSheetHeader(step: step, isEnabled: !model.isBusy) { dismiss() }

            switch step {
            case .profile:
                AccountSetupProfileStep(model: model)
            case .relays, .inboxRelays:
                AccountSetupRelayStep(model: model, step: step)
            case .singleDevice:
                AccountSetupDeviceStep(model: model)
            case .keyPackage:
                AccountSetupSecureMessagingStep(model: model)
            case .follows:
                AccountSetupFollowsStep(model: model)
            }
        }
        .frame(width: AccountSetupStepLayoutMetrics.width, height: AccountSetupStepLayoutMetrics.height)
        .background(WNColor.backgroundPrimary)
        .controlSize(.large)
        .wnButtonShape(.capsule)
        .interactiveDismissDisabled(model.isBusy)
        .onChange(of: model.snapshot) { _, snapshot in
            let finished = stepState.map { AccountSetupGuide.isComplete($0.status) } ?? true
            if finished || snapshot?.cancellationPending == true { dismiss() }
        }
        .accessibilityIdentifier("onboarding.account-setup.step")
    }
}

/// The sheet's title row: the step's name and Close.
struct AccountSetupStepSheetHeader: View {
    @Environment(\.locale) private var locale
    let step: OnboardingStepFfi
    var isEnabled = true
    let close: () -> Void

    var body: some View {
        HStack {
            Text(L10n.string(AccountSetupGuide.titleKey(step), locale: locale))
                .wnFont(.bold18)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            GlassCircleCloseButton(help: "Close", appearance: .outline, action: close)
                .accessibilityLabel(L10n.string("Close", locale: locale))
                .disabled(!isEnabled)
        }
        .padding(.horizontal, AccountSetupStepLayoutMetrics.padding)
        .padding(.top, AccountSetupStepLayoutMetrics.padding)
        .padding(.bottom, 8)
    }
}

enum AccountSetupStepLayoutMetrics {
    static let width: CGFloat = 480
    static let height: CGFloat = 600
    static let padding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
}

/// A step screen's body: scrolling content over a pinned column of actions.
struct AccountSetupStepLayout<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AccountSetupStepLayoutMetrics.sectionSpacing) {
                    content
                }
                .padding(.horizontal, AccountSetupStepLayoutMetrics.padding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AccountSetupActionColumn { actions }
        }
    }
}

/// A step screen's pinned actions, stacked under its scrolling content.
struct AccountSetupActionColumn<Actions: View>: View {
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: OnboardingLayout.actionSpacing) {
            actions
        }
        .padding(AccountSetupStepLayoutMetrics.padding)
    }
}

/// The status box at the top of a step screen — iOS's `AccountSetupRecoveryCallout`: a symbol, a
/// title saying where the step stands, and the lines explaining it.
struct AccountSetupCallout<Lines: View>: View {
    @Environment(\.locale) private var locale
    let titleKey: String
    let symbol: String
    var isError = false
    var isLoading = false
    @ViewBuilder var lines: Lines

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isError ? "exclamationmark.circle" : symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(
                            isError ? WNColor.intentionErrorContent : WNColor.backgroundContentPrimary
                        )
                }
            }
            .frame(width: 20)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(titleKey, locale: locale))
                    .wnFont(.semiBold14)
                    .foregroundStyle(isError ? WNColor.intentionErrorContent : WNColor.backgroundContentPrimary)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 6) {
                    lines
                }
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(AccountSetupCardChrome())
        .accessibilityElement(children: .combine)
    }
}

/// What MarmotKit found wrong with a step, one line each, with the relay it was about — or, for a
/// failed step that names nothing, a generic line.
struct AccountSetupFindingLines: View {
    @Environment(\.locale) private var locale
    let findings: [OnboardingFindingFfi]
    var isFailure = false

    var body: some View {
        if isFailure, findings.isEmpty {
            Text(L10n.string("Couldn’t finish this step. Try again.", locale: locale))
        }
        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(AccountSetupGuide.issueKey(finding.issue), locale: locale))
                if let endpoint = finding.endpoint {
                    Text(String(endpoint.prefix(200)))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// The error the last action pressed on a step screen ended with.
struct AccountSetupErrorLine: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentDestructive)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What a step screen says when MarmotKit offers no action the Mac supports — only, say,
/// reconnecting a signer or editing follows, as after an npub sign-in, which cannot sign. Without
/// it the screen is a callout over a lone Close, under a checklist row that says "Fix to continue".
struct AccountSetupNoActionLines: View {
    @Environment(\.locale) private var locale
    let step: OnboardingStepFfi
    let snapshot: OnboardingSnapshotFfi?

    var body: some View {
        let keys = Self.messageKeys(step, in: snapshot)
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(keys, id: \.self) { Text(L10n.string($0, locale: locale)) }
            }
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentDestructive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let unsupportedKey = "This step can’t be finished on this Mac yet. Cancel sign-in and try again."
    static let signerKey = "Couldn’t access your private key"

    /// The lines, as catalog keys, or none while the step offers something to press — or is not
    /// waiting on the user at all, as while it is being checked again.
    static func messageKeys(_ step: OnboardingStepFfi, in snapshot: OnboardingSnapshotFfi?) -> [String] {
        guard let state = snapshot?.steps.first(where: { $0.step == step }),
            [.needsInput, .retryableFailure, .waitingForSigner].contains(state.status),
            offersNoAction(step, in: snapshot)
        else { return [] }
        return state.status == .waitingForSigner ? [signerKey, unsupportedKey] : [unsupportedKey]
    }

    /// Whether `step`'s screen would draw no action button: the same conditions each screen
    /// uses to draw its buttons.
    static func offersNoAction(_ step: OnboardingStepFfi, in snapshot: OnboardingSnapshotFfi?) -> Bool {
        let actions = snapshot?.steps.first { $0.step == step }?.actions ?? []
        switch step {
        case .profile:
            return AccountSetupProfilePlan(snapshot: snapshot).offersNoAction
        case .relays, .inboxRelays:
            return AccountSetupRelayPlan(snapshot: snapshot, step: step).offersNoAction
        case .singleDevice:
            return !actions.contains(.continueAnyway) && !actions.contains(.retry)
        case .keyPackage:
            return !actions.contains(.retry)
        case .follows:
            return !actions.contains(.retry) && !actions.contains(.continueWithout) && !actions.contains(.cancelRepair)
        }
    }
}

/// One of a step screen's actions. Spins while its own action runs, and every action on the
/// screen is disabled while any MarmotKit call is in flight.
struct AccountSetupStepButton: View {
    @Environment(\.locale) private var locale
    let titleKey: String
    var tier: OnboardingActionTier = .primary
    let model: OnboardingCoordinator
    @Binding var active: String?
    var isEnabled = true
    let action: () async -> Void

    var body: some View {
        OnboardingActionButton(
            title: L10n.string(titleKey, locale: locale), tier: tier, isLoading: active == titleKey
        ) {
            guard active == nil else { return }
            active = titleKey
            Task {
                await action()
                active = nil
            }
        }
        .disabled(!isEnabled || model.isBusy || active != nil)
    }
}

// MARK: - Single device

/// iOS's `AccountSetupDeviceView`: the single-device notice and its consent.
struct AccountSetupDeviceStep: View {
    @Environment(\.locale) private var locale
    let model: OnboardingCoordinator
    @State private var active: String?

    private var step: OnboardingStepStateFfi? {
        model.snapshot?.steps.first { $0.step == .singleDevice }
    }

    private var failureFindings: [OnboardingFindingFfi]? {
        guard let step, step.status == .retryableFailure else { return nil }
        return step.findings
    }

    var body: some View {
        let notice = model.snapshot?.singleDeviceNotice
        let hasFailure = failureFindings != nil
        let showsNotice = notice != nil && (!hasFailure || step?.actions.contains(.continueAnyway) == true)

        AccountSetupStepLayout {
            AccountSetupCallout(
                titleKey: hasFailure ? "Couldn’t check for other devices" : "Using one device",
                symbol: "laptopcomputer",
                isError: hasFailure,
                isLoading: model.isBusy && active == nil
            ) {
                if let failureFindings {
                    AccountSetupFindingLines(findings: failureFindings, isFailure: true)
                }
                if showsNotice, let notice {
                    Text(L10n.string(AccountSetupGuide.deviceNoticeKey(notice.discovery), locale: locale))
                }
                if hasFailure || showsNotice { Divider() }
                Text(L10n.string(AccountSetupGuide.descriptionKey(.singleDevice), locale: locale))
            }
            AccountSetupNoActionLines(step: .singleDevice, snapshot: model.snapshot)
            AccountSetupErrorLine(message: model.error)
        } actions: {
            if let step {
                if step.actions.contains(.continueAnyway) {
                    AccountSetupStepButton(
                        titleKey: AccountSetupGuide.deviceActionKey(notice?.discovery),
                        model: model,
                        active: $active
                    ) { await model.acknowledgeSingleDevice() }
                } else if step.actions.contains(.retry) {
                    AccountSetupStepButton(titleKey: "Try Again", model: model, active: $active) {
                        await model.retry(.singleDevice)
                    }
                }
            }
        }
    }
}

// MARK: - Secure messaging

/// iOS's `AccountSetupSecureMessagingView`: the key package has to be published before chats open.
struct AccountSetupSecureMessagingStep: View {
    @Environment(\.locale) private var locale
    let model: OnboardingCoordinator
    @State private var active: String?

    private var step: OnboardingStepStateFfi? {
        model.snapshot?.steps.first { $0.step == .keyPackage }
    }

    var body: some View {
        let failed = step.map { $0.status == .retryableFailure || $0.status == .waitingForSigner } ?? false

        AccountSetupStepLayout {
            AccountSetupCallout(
                titleKey: failed && !model.isBusy ? "Couldn’t prepare secure messaging" : "Secure messaging",
                symbol: "lock.shield",
                isError: failed && !model.isBusy,
                isLoading: model.isBusy
            ) {
                if model.isBusy {
                    Text(L10n.string("Preparing secure messaging…", locale: locale))
                } else if failed, let step {
                    AccountSetupFindingLines(findings: step.findings, isFailure: true)
                }
                Divider()
                Text(L10n.string(AccountSetupGuide.descriptionKey(.keyPackage), locale: locale))
            }
            AccountSetupNoActionLines(step: .keyPackage, snapshot: model.snapshot)
            AccountSetupErrorLine(message: model.error)
        } actions: {
            if step?.actions.contains(.retry) == true {
                AccountSetupStepButton(titleKey: "Try Again", model: model, active: $active) {
                    await model.retry(.keyPackage)
                }
            }
        }
    }
}

// MARK: - Follows

/// The follows step, which the coordinator normally settles on its own (see
/// `OnboardingCoordinator.automaticFollowsAction`). Shown only when that could not happen.
struct AccountSetupFollowsStep: View {
    @Environment(\.locale) private var locale
    let model: OnboardingCoordinator
    @State private var active: String?

    private var step: OnboardingStepStateFfi? {
        model.snapshot?.steps.first { $0.step == .follows }
    }

    var body: some View {
        AccountSetupStepLayout {
            AccountSetupCallout(
                titleKey: AccountSetupGuide.titleKey(.follows),
                symbol: "person.2",
                isLoading: model.isBusy
            ) {
                Text(L10n.string(AccountSetupGuide.descriptionKey(.follows), locale: locale))
                AccountSetupFindingLines(findings: step?.findings ?? [])
            }
            AccountSetupNoActionLines(step: .follows, snapshot: model.snapshot)
            AccountSetupErrorLine(message: model.error)
        } actions: {
            if let step {
                if step.actions.contains(.retry) {
                    AccountSetupStepButton(titleKey: "Try Again", model: model, active: $active) {
                        await model.retry(.follows)
                    }
                }
                if step.actions.contains(.continueWithout) {
                    AccountSetupStepButton(
                        titleKey: "Continue",
                        tier: step.actions.contains(.retry) ? .secondary : .primary,
                        model: model,
                        active: $active
                    ) { await model.skip(.follows) }
                }
                if step.actions.contains(.cancelRepair) {
                    AccountSetupStepButton(titleKey: "Back", tier: .secondary, model: model, active: $active) {
                        await model.cancelRepair()
                    }
                }
            }
        }
    }
}

#Preview("Single device") {
    let model = OnboardingCoordinator.preview(
        steps: [
            OnboardingStepStateFfi(
                step: .singleDevice, status: .needsInput, findings: [], actions: [.continueAnyway], checkedAt: nil
            )
        ],
        singleDeviceNotice: OnboardingSingleDeviceNoticeFfi(
            discovery: .otherInstallationPossible, otherPackages: [], discoveryComplete: true, acknowledgedAt: nil
        )
    )
    AccountSetupStepSheet(model: model, step: .singleDevice)
}

#Preview("Secure messaging") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .keyPackage, status: .retryableFailure,
            findings: [.init(issue: .publicationFailed, endpoint: nil)], actions: [.retry], checkedAt: nil
        )
    ])
    AccountSetupStepSheet(model: model, step: .keyPackage)
}

#Preview("Follows") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .follows, status: .retryableFailure,
            findings: [.init(issue: .unreachable, endpoint: "wss://relay.example.com")],
            actions: [.retry, .continueWithout], checkedAt: nil
        )
    ])
    AccountSetupStepSheet(model: model, step: .follows)
}
