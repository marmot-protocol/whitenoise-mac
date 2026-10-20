import MarmotKit
import SwiftUI

/// The guided account setup that follows Sign In: MarmotKit's durable onboarding checkpoint as a
/// vertical checklist, on the same scaffold as the sign-in pane.
///
/// This is `whitenoise-ios`'s `AccountSetupView`: every step is a named row with its state, and
/// the one step that needs the user — the first unfinished one — is a row with a chevron that
/// opens that step's own screen, as does the pane's Review and Continue button. The screen takes
/// the pane, as Sign In and Sign Up do, rather than opening as a sheet over it, and its header row
/// keeps the way back to this checklist. Each screen offers what the step actually needs rather
/// than a bare retry: the profile step Sign Up's photo, name and description form; the relay steps
/// their defaults, an editor and a search; the single-device step its consent. See
/// `AccountSetupStepScreen`.
///
/// The snapshot is authoritative: every button runs an action the step advertises, and the pane
/// survives termination because no progress is held only in SwiftUI state. See
/// `AccountSetupGuide` for what is derived from it.
struct AccountSetupView: View {
    let model: OnboardingCoordinator
    @State private var acknowledgesRecoveryRisk = false

    private var guide: AccountSetupGuide {
        AccountSetupGuide(snapshot: model.snapshot, recoveryRequired: model.recoveryRequired)
    }

    var body: some View {
        Group {
            if let step = model.reviewingStep {
                AccountSetupStepScreen(model: model, step: step)
            } else {
                AccountSetupChecklistPane(
                    model: model, guide: guide, acknowledgesRecoveryRisk: $acknowledgesRecoveryRisk
                )
            }
        }
        .animation(.smooth(duration: 0.2), value: model.reviewingStep)
        .accessibilityIdentifier("onboarding.account-setup")
    }
}

/// The setup's checklist pane: the header, every step's row, and the pane's one button.
private struct AccountSetupChecklistPane: View {
    let model: OnboardingCoordinator
    let guide: AccountSetupGuide
    @Binding var acknowledgesRecoveryRisk: Bool

    var body: some View {
        OnboardingScaffold(
            // Hidden, not disabled, while a command runs or the cancellation finishes: the header
            // row keeps its height either way, and there is nothing for the control to do.
            exit: model.canStartSessionCommand ? .cancel { Task { await model.cancel() } } : nil,
            minimumEdgeSpacing: OnboardingLayout.signUpEdgePadding,
            maximumHeroToContentSpacing: OnboardingLayout.accountSetupHeroToContentSpacing,
            hero: { WhiteNoiseMarkView(width: OnboardingLayout.accountSetupMarkWidth) },
            content: {
                VStack(spacing: OnboardingLayout.accountSetupSectionSpacing) {
                    AccountSetupHeader(guide: guide)

                    if guide.phase == .recovery {
                        AccountSetupRecoveryCard(
                            acknowledgesRisk: $acknowledgesRecoveryRisk, isEnabled: !model.isBusy
                        )
                    } else if !guide.steps.isEmpty {
                        AccountSetupChecklist(
                            guide: guide,
                            isEnabled: !model.isBusy,
                            review: { model.review($0) }
                        )
                    }

                    if let message = model.error {
                        Text(message)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentDestructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            },
            actions: {
                AccountSetupPaneActions(
                    guide: guide,
                    model: model,
                    acknowledgesRecoveryRisk: acknowledgesRecoveryRisk,
                    review: { model.review($0) }
                )
            }
        )
        .controlSize(.large)
        .wnButtonShape(.capsule)
        .animation(.smooth(duration: 0.2), value: guide)
    }
}

// MARK: - Header

private struct AccountSetupHeader: View {
    @Environment(\.locale) private var locale
    let guide: AccountSetupGuide

    var body: some View {
        VStack(spacing: 6) {
            Text(L10n.string(guide.titleKey, locale: locale))
                .wnFont(.bold24)
                .foregroundStyle(WNColor.backgroundContentPrimary)
            Text(L10n.string(guide.subtitleKey, locale: locale))
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

// MARK: - Checklist

/// Every step, top to bottom, as a named row with its state — iOS's grouped list, drawn as one
/// outlined card. The step to review is the only row that is a button.
struct AccountSetupChecklist: View {
    @Environment(\.locale) private var locale
    let guide: AccountSetupGuide
    var isEnabled = true
    let review: (OnboardingStepFfi) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(guide.steps.enumerated()), id: \.element.step) { index, step in
                if index > 0 {
                    Divider().padding(.leading, 48)
                }
                if guide.reviewStep == step.step {
                    Button {
                        review(step.step)
                    } label: {
                        AccountSetupChecklistRow(step: step, isReviewable: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .accessibilityHint(L10n.string("Show options for this check", locale: locale))
                } else {
                    AccountSetupChecklistRow(step: step, isReviewable: false)
                }
            }
        }
        .modifier(AccountSetupCardChrome(padding: 0))
    }
}

private struct AccountSetupChecklistRow: View {
    @Environment(\.locale) private var locale
    let step: OnboardingStepStateFfi
    let isReviewable: Bool

    private var state: AccountSetupGuide.CheckState { AccountSetupGuide.checkState(step) }

    var body: some View {
        HStack(spacing: 12) {
            AccountSetupCheckIcon(state: state)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(AccountSetupGuide.titleKey(step.step), locale: locale))
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                Text(L10n.string(state.subtitleKey, locale: locale))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            Spacer(minLength: 0)
            if isReviewable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WNColor.backgroundContentTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct AccountSetupCheckIcon: View {
    let state: AccountSetupGuide.CheckState

    var body: some View {
        Group {
            if state == .checking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .passed: WNColor.intentionSuccessContent
        case .optionalReview, .acknowledgment: WNColor.intentionWarningContent
        case .requiredFix: WNColor.intentionErrorContent
        case .pending, .checking, .skipped: WNColor.backgroundContentTertiary
        }
    }
}

/// The card chrome the checklist and the recovery card share: an outlined, softly filled rounded
/// rectangle. The outline is what keeps it visible where `fillSecondary` and the pane's ground
/// land close.
struct AccountSetupCardChrome: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WNColor.borderTertiary))
    }
}

private struct AccountSetupRecoveryCard: View {
    @Environment(\.locale) private var locale
    @Binding var acknowledgesRisk: Bool
    /// Off while the recovery runs, so the acknowledgment cannot be withdrawn under it.
    var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                L10n.string(
                    "Recovery signs this profile out and replaces its unreadable setup checkpoint. Only the latest recovery evidence is retained. It does not undo earlier relay publications. You will need the private key to start a new sign-in; no publication is approved by this action.",
                    locale: locale
                )
            )
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)
            WNToggle(isOn: $acknowledgesRisk) {
                Text(L10n.string("Recover Sign-In Setup?", locale: locale))
                    .wnFont(.semiBold14)
            }
            .disabled(!isEnabled)
        }
        .modifier(AccountSetupCardChrome())
    }
}

// MARK: - Actions

/// The pane's one button, as on iOS: Review and Continue while a step needs the user, Open Chats
/// once setup is done, Try Again after the checkpoint stopped answering — and a disabled spinner
/// while MarmotKit works, held in place so the column does not jump when a check finishes.
private struct AccountSetupPaneActions: View {
    @Environment(\.locale) private var locale
    let guide: AccountSetupGuide
    let model: OnboardingCoordinator
    let acknowledgesRecoveryRisk: Bool
    let review: (OnboardingStepFfi) -> Void

    var body: some View {
        if guide.phase == .recovery {
            OnboardingActionButton(
                title: L10n.string("Recover Sign-In Setup", locale: locale),
                isLoading: model.isBusy
            ) {
                Task { await model.recover(acknowledgeLatestOnlyEvidence: true) }
            }
            .disabled(!acknowledgesRecoveryRisk || model.isBusy)
        } else if guide.phase == .ready {
            OnboardingActionButton(
                title: L10n.string(model.hasConfirmedOpenChats ? "Opening your chats…" : "Open Chats", locale: locale),
                isLoading: model.hasConfirmedOpenChats
            ) {
                model.openChats()
            }
            .disabled(model.hasConfirmedOpenChats)
            .accessibilityIdentifier("onboarding.open-chats")
        } else if let step = guide.reviewStep {
            OnboardingActionButton(title: L10n.string("Review and Continue", locale: locale)) {
                review(step)
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("onboarding.review-step")
        } else if model.error != nil, guide.phase != .cancelling {
            OnboardingActionButton(title: L10n.string("Try Again", locale: locale)) {
                model.start()
            }
            .disabled(model.isBusy)
        } else {
            OnboardingActionButton(
                title: L10n.string(guide.phase == .cancelling ? "Closing sign-in" : "Checking…", locale: locale),
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
            OnboardingStepStateFfi(step: .inboxRelays, status: .checking, findings: [], actions: [], checkedAt: nil),
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
        AccountSetupChecklist(guide: guide, review: { _ in })
    }
    .padding(40)
    .frame(width: 440)
}

#Preview("Recovery") {
    AccountSetupRecoveryCard(acknowledgesRisk: .constant(false))
        .padding(40)
        .frame(width: 440)
}
