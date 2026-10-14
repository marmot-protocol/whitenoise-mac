import MarmotKit
import SwiftUI

/// The guided account setup that follows Sign In: MarmotKit's durable onboarding checkpoint,
/// walked one step at a time on the same scaffold as the sign-in pane.
///
/// `whitenoise-ios` shows this checkpoint as a grouped checklist in the sign-in sheet, with a
/// review sheet per step. A window has no sheet to grow, and the user asked for a screen rather
/// than a modal, so the mac keeps the pane it signed in on — header row, mark, centred column,
/// actions along the bottom — and changes only the column: a tracker of every step, a card for
/// the one in focus, and that step's actions as the pane's buttons. Searching another relay, which
/// iOS opens as a sheet, happens inline in the card for the same reason.
///
/// The snapshot is authoritative: every button runs an action the focused step advertises, and
/// the pane survives termination because no progress is held only in SwiftUI state. See
/// `AccountSetupGuide` for what is derived from it.
struct AccountSetupView: View {
    let model: OnboardingCoordinator
    @State private var acknowledgesRecoveryRisk = false
    @State private var isSearchingRelay = false
    @State private var relay = ""
    @State private var relayValidationError: String?

    private var guide: AccountSetupGuide {
        AccountSetupGuide(snapshot: model.snapshot, recoveryRequired: model.recoveryRequired)
    }

    private var message: String? {
        relayValidationError ?? model.error
    }

    var body: some View {
        let guide = guide

        OnboardingScaffold(
            exit: .cancel { Task { await model.cancel() } },
            minimumEdgeSpacing: OnboardingLayout.signUpEdgePadding,
            maximumHeroToContentSpacing: OnboardingLayout.accountSetupHeroToContentSpacing,
            hero: { WhiteNoiseMarkView(width: OnboardingLayout.accountSetupMarkWidth) },
            content: {
                VStack(spacing: OnboardingLayout.accountSetupSectionSpacing) {
                    AccountSetupHeader(guide: guide)

                    if !guide.steps.isEmpty {
                        AccountSetupStepTracker(guide: guide)
                    }

                    AccountSetupFocusCard(
                        guide: guide,
                        model: model,
                        isSearchingRelay: isSearchingRelay,
                        relay: $relay,
                        acknowledgesRecoveryRisk: $acknowledgesRecoveryRisk,
                        perform: perform
                    )

                    // Not the reserved `OnboardingMessageLine` the other panes use: this column is
                    // already the tallest onboarding has, and its buttons change with every step
                    // anyway, so the reservation would buy no stillness for the height it costs.
                    if let message {
                        Text(message)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentDestructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            },
            actions: {
                AccountSetupActions(
                    guide: guide,
                    model: model,
                    isSearchingRelay: isSearchingRelay,
                    acknowledgesRecoveryRisk: acknowledgesRecoveryRisk,
                    perform: perform,
                    searchRelay: searchRelay,
                    cancelRelaySearch: cancelRelaySearch
                )
            }
        )
        .controlSize(.large)
        .wnButtonShape(.capsule)
        .animation(.smooth(duration: 0.2), value: guide)
        .animation(.smooth(duration: 0.2), value: isSearchingRelay)
        .onChange(of: guide.focusedStep?.step) { _, _ in cancelRelaySearch() }
        .accessibilityIdentifier("onboarding.account-setup")
    }

    private func perform(_ action: AccountSetupGuide.Action) {
        guard let step = guide.focusedStep?.step else { return }
        switch action {
        case .approveRepair: Task { await model.approveRepair() }
        case .continueAnyway: Task { await model.acknowledgeSingleDevice() }
        case .retry: Task { await model.retry(step) }
        case .useRecommendedRelays: Task { await model.proposeRecommendedRelays(step: step) }
        case .continueWithout: Task { await model.skip(step) }
        case .cancelRepair: Task { await model.cancelRepair() }
        case .editDiscoveryRelays:
            relayValidationError = nil
            isSearchingRelay = true
        }
    }

    private func searchRelay() {
        let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "wss", url.host() != nil else {
            relayValidationError = L10n.string("Enter a valid relay URL, like wss://relay.example.com.")
            return
        }
        relayValidationError = nil
        Task {
            await model.setDiscoveryRelays([trimmed])
            if model.error == nil { cancelRelaySearch() }
        }
    }

    private func cancelRelaySearch() {
        isSearchingRelay = false
        relay = ""
        relayValidationError = nil
    }
}

// MARK: - Header

private struct AccountSetupHeader: View {
    let guide: AccountSetupGuide

    var body: some View {
        VStack(spacing: 6) {
            Text(L10n.string(guide.titleKey))
                .wnFont(.bold24)
                .foregroundStyle(WNColor.backgroundContentPrimary)
            Text(L10n.string(guide.subtitleKey))
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Tracker

/// Every step as a dot on a line, so the user can see how far along setup is and what is left —
/// the guided part of the flow. The focused step is ringed; completed ones are filled.
private struct AccountSetupStepTracker: View {
    let guide: AccountSetupGuide

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(guide.steps.enumerated()), id: \.element.step) { index, step in
                    if index > 0 {
                        Capsule()
                            .fill(
                                AccountSetupGuide.isComplete(guide.steps[index - 1].status)
                                    ? WNColor.fillPrimary : WNColor.borderTertiary
                            )
                            .frame(height: 2)
                            .frame(minWidth: 8)
                    }
                    AccountSetupStepDot(
                        step: step,
                        isFocused: guide.focusedStep?.step == step.step
                    )
                }
            }

            Text(
                String(
                    format: L10n.string("%1$lld of %2$lld"),
                    Int64(guide.position),
                    Int64(guide.steps.count)
                )
            )
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentTertiary)
            .monospacedDigit()
            .accessibilityHidden(true)
        }
    }
}

private struct AccountSetupStepDot: View {
    let step: OnboardingStepStateFfi
    let isFocused: Bool

    private static let size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(stroke, lineWidth: isFocused ? 2 : 1)
            AccountSetupStepDotGlyph(step: step)
        }
        .frame(width: Self.size, height: Self.size)
        .help(L10n.string(AccountSetupGuide.titleKey(step.step)))
        .accessibilityElement()
        .accessibilityLabel(L10n.string(AccountSetupGuide.titleKey(step.step)))
        .accessibilityValue(L10n.string(AccountSetupGuide.statusKey(step)))
    }

    private var fill: Color {
        switch step.status {
        case .passed: WNColor.fillPrimary
        case .needsInput, .retryableFailure, .waitingForSigner: WNColor.intentionWarningBackground
        case .pending, .checking, .skipped: WNColor.backgroundPrimary
        }
    }

    private var stroke: Color {
        if step.status == .passed { return WNColor.fillPrimary }
        if AccountSetupGuide.needsAttention(step.status) { return WNColor.intentionWarningContent }
        return isFocused ? WNColor.backgroundContentPrimary : WNColor.borderTertiary
    }
}

private struct AccountSetupStepDotGlyph: View {
    let step: OnboardingStepStateFfi

    var body: some View {
        switch step.status {
        case .checking:
            ProgressView()
                .controlSize(.mini)
        case .passed:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WNColor.fillContentPrimary)
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WNColor.backgroundContentTertiary)
        case .needsInput, .retryableFailure, .waitingForSigner:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WNColor.intentionWarningContent)
        case .pending:
            Image(systemName: AccountSetupGuide.symbol(step.step))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WNColor.backgroundContentTertiary)
        }
    }
}

// MARK: - Focus card

/// The one card under the tracker: what the focused step is, or the recovery explanation, the
/// relay search, or — once everything is done — the finished checklist.
private struct AccountSetupFocusCard: View {
    let guide: AccountSetupGuide
    let model: OnboardingCoordinator
    let isSearchingRelay: Bool
    @Binding var relay: String
    @Binding var acknowledgesRecoveryRisk: Bool
    let perform: (AccountSetupGuide.Action) -> Void

    var body: some View {
        Group {
            if guide.phase == .recovery {
                AccountSetupRecoveryCard(acknowledgesRisk: $acknowledgesRecoveryRisk)
            } else if isSearchingRelay {
                AccountSetupRelaySearchCard(relay: $relay, isEnabled: !model.isBusy)
            } else if guide.phase == .ready {
                AccountSetupSummaryCard(steps: guide.steps)
            } else if let step = guide.focusedStep {
                AccountSetupStepCard(
                    step: step,
                    extraActions: Array(guide.actions.dropFirst(2)),
                    isEnabled: !model.isBusy,
                    perform: perform
                )
            }
        }
        .transition(.opacity)
    }
}

/// The card chrome every focus card shares: an outlined, softly filled rounded rectangle. The
/// outline is what keeps it visible where `fillSecondary` and the pane's ground land close.
private struct AccountSetupCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WNColor.borderTertiary))
    }
}

private struct AccountSetupStepCard: View {
    let step: OnboardingStepStateFfi
    let extraActions: [AccountSetupGuide.Action]
    let isEnabled: Bool
    let perform: (AccountSetupGuide.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AccountSetupStepIcon(step: step)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(AccountSetupGuide.titleKey(step.step)))
                        .wnFont(.semiBold14)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                    Text(L10n.string(AccountSetupGuide.statusKey(step)))
                        .wnFont(.medium12)
                        .foregroundStyle(
                            AccountSetupGuide.needsAttention(step.status)
                                ? WNColor.intentionWarningContent : WNColor.backgroundContentSecondary
                        )
                }
                Spacer(minLength: 0)
            }

            // What went wrong replaces what the step is for: once there are findings, the general
            // description is the less useful of the two, and both do not fit the smallest window.
            if step.findings.isEmpty {
                Text(L10n.string(AccountSetupGuide.descriptionKey(step.step)))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                AccountSetupFindingList(findings: step.findings)
            }

            if !extraActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(extraActions, id: \.self) { action in
                        Button(L10n.string(action.titleKey)) { perform(action) }
                            .buttonStyle(.wnSecondary)
                            .controlSize(.small)
                    }
                }
                .disabled(!isEnabled)
            }
        }
        .modifier(AccountSetupCardChrome())
    }
}

private struct AccountSetupStepIcon: View {
    let step: OnboardingStepStateFfi

    var body: some View {
        Image(systemName: AccountSetupGuide.symbol(step.step))
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(
                AccountSetupGuide.needsAttention(step.status)
                    ? WNColor.intentionWarningContent : WNColor.backgroundContentPrimary
            )
            .frame(width: 36, height: 36)
            .background(
                AccountSetupGuide.needsAttention(step.status)
                    ? WNColor.intentionWarningBackground : WNColor.backgroundPrimary,
                in: Circle()
            )
            .accessibilityHidden(true)
    }
}

private struct AccountSetupFindingList: View {
    let findings: [OnboardingFindingFfi]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(WNColor.intentionWarningContent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string(AccountSetupGuide.issueKey(finding.issue)))
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                            .fixedSize(horizontal: false, vertical: true)
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
    }
}

private struct AccountSetupRelaySearchCard: View {
    @Binding var relay: String
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Find Your Settings"))
                .wnFont(.semiBold14)
                .foregroundStyle(WNColor.backgroundContentPrimary)
            Text(
                L10n.string(
                    "Choose a relay you’ve used with this profile. We’ll look there for your existing settings without publishing anything."
                )
            )
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)
            WNInput(
                label: L10n.string("Relay"),
                prompt: "wss://relay.example.com",
                text: $relay,
                isEnabled: isEnabled,
                disablesAutocorrection: true,
                focusOnAppear: true
            )
        }
        .modifier(AccountSetupCardChrome())
    }
}

private struct AccountSetupRecoveryCard: View {
    @Binding var acknowledgesRisk: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                L10n.string(
                    "Recovery signs this profile out and replaces its unreadable setup checkpoint. Only the latest recovery evidence is retained. It does not undo earlier relay publications. You will need the private key to start a new sign-in; no publication is approved by this action."
                )
            )
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)
            WNToggle(isOn: $acknowledgesRisk) {
                Text(L10n.string("Recover Sign-In Setup?"))
                    .wnFont(.semiBold14)
            }
        }
        .modifier(AccountSetupCardChrome())
    }
}

/// The finished checklist, on the last step: what was set up and what was skipped, so Open
/// Chats is pressed knowing what it is opening onto.
private struct AccountSetupSummaryCard: View {
    let steps: [OnboardingStepStateFfi]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps, id: \.step) { step in
                HStack(spacing: 10) {
                    Image(systemName: step.status == .skipped ? "minus.circle" : "checkmark.circle.fill")
                        .foregroundStyle(
                            step.status == .skipped
                                ? WNColor.backgroundContentTertiary : WNColor.intentionSuccessContent
                        )
                        .accessibilityHidden(true)
                    Text(L10n.string(AccountSetupGuide.titleKey(step.step)))
                        .wnFont(.medium14)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                    Spacer(minLength: 0)
                    Text(L10n.string(AccountSetupGuide.statusKey(step)))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .modifier(AccountSetupCardChrome())
    }
}

// MARK: - Actions

/// The pane's bottom buttons. The focused step's most important action is the primary, its next
/// the secondary; anything further sits in the card as a small button. While MarmotKit is working
/// the primary stays in place, disabled and spinning, so the column does not jump when a check
/// finishes.
private struct AccountSetupActions: View {
    let guide: AccountSetupGuide
    let model: OnboardingCoordinator
    let isSearchingRelay: Bool
    let acknowledgesRecoveryRisk: Bool
    let perform: (AccountSetupGuide.Action) -> Void
    let searchRelay: () -> Void
    let cancelRelaySearch: () -> Void

    var body: some View {
        if guide.phase == .recovery {
            OnboardingActionButton(
                title: L10n.string("Recover Sign-In Setup"),
                isLoading: model.isBusy
            ) {
                Task { await model.recover(acknowledgeLatestOnlyEvidence: true) }
            }
            .disabled(!acknowledgesRecoveryRisk || model.isBusy)
        } else if isSearchingRelay {
            OnboardingActionButton(
                title: L10n.string("Look for My Settings"),
                isLoading: model.isBusy,
                action: searchRelay
            )
            .disabled(model.isBusy)
            OnboardingActionButton(
                title: L10n.string("Cancel"),
                tier: .secondary,
                action: cancelRelaySearch
            )
            .disabled(model.isBusy)
        } else if guide.phase == .ready {
            OnboardingActionButton(
                title: L10n.string(model.hasConfirmedOpenChats ? "Opening your chats…" : "Open Chats"),
                isLoading: model.hasConfirmedOpenChats
            ) {
                model.openChats()
            }
            .disabled(model.hasConfirmedOpenChats)
            .accessibilityIdentifier("onboarding.open-chats")
        } else if let primary = guide.actions.first {
            OnboardingActionButton(
                title: L10n.string(primary.titleKey),
                isLoading: model.isBusy
            ) {
                perform(primary)
            }
            .disabled(model.isBusy)
            if guide.actions.count > 1 {
                let secondary = guide.actions[1]
                OnboardingActionButton(
                    title: L10n.string(secondary.titleKey),
                    tier: .secondary
                ) {
                    perform(secondary)
                }
                .disabled(model.isBusy)
            }
        } else if model.error != nil, guide.phase != .cancelling {
            OnboardingActionButton(title: L10n.string("Try Again")) {
                model.start()
            }
        } else {
            OnboardingActionButton(
                title: L10n.string(guide.phase == .cancelling ? "Closing sign-in" : "Checking…"),
                isLoading: true
            ) {}
            .disabled(true)
        }
    }
}

#Preview("Needs attention") {
    let snapshot = OnboardingSnapshotFfi(
        accountIdHex: "preview",
        recoveryEpoch: nil,
        revision: 1,
        ready: false,
        steps: [
            OnboardingStepStateFfi(step: .profile, status: .passed, findings: [], actions: [], checkedAt: nil),
            OnboardingStepStateFfi(step: .follows, status: .skipped, findings: [], actions: [], checkedAt: nil),
            OnboardingStepStateFfi(
                step: .relays,
                status: .retryableFailure,
                findings: [.init(issue: .unreachable, endpoint: "wss://relay.example.com")],
                actions: [.retry, .useRecommendedRelays, .editDiscoveryRelays],
                checkedAt: nil
            ),
            OnboardingStepStateFfi(step: .inboxRelays, status: .pending, findings: [], actions: [], checkedAt: nil),
            OnboardingStepStateFfi(step: .singleDevice, status: .pending, findings: [], actions: [], checkedAt: nil),
            OnboardingStepStateFfi(step: .keyPackage, status: .pending, findings: [], actions: [], checkedAt: nil),
        ],
        proposal: nil,
        singleDeviceNotice: nil,
        cancellationPending: false
    )
    let guide = AccountSetupGuide(snapshot: snapshot, recoveryRequired: false)
    VStack(spacing: 16) {
        AccountSetupHeader(guide: guide)
        AccountSetupStepTracker(guide: guide)
        if let step = guide.focusedStep {
            AccountSetupStepCard(
                step: step,
                extraActions: Array(guide.actions.dropFirst(2)),
                isEnabled: true,
                perform: { _ in }
            )
        }
    }
    .padding(40)
    .frame(width: 440)
}
