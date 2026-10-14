import Foundation
import MarmotKit

/// What the guided account-setup pane shows for one onboarding snapshot: which step is in focus,
/// how far along the checklist is, and which actions the focused step offers, in the order the
/// pane draws them.
///
/// Derived, never stored. The snapshot is the authority (see `OnboardingCoordinator`), so this is
/// rebuilt from it on every render and cannot drift from what MarmotKit says. The shape follows
/// `whitenoise-ios`'s `AccountSetupPresentation` — same step titles, same header copy, same
/// three-way split of the "needs attention" statuses — but walks the steps one at a time instead of
/// listing them, because the mac pane is the onboarding scaffold, not a grouped list in a sheet.
struct AccountSetupGuide: Equatable {
    enum Phase: Equatable {
        /// The saved checkpoint is unreadable; the only way forward is recovery.
        case recovery
        /// A cancellation was requested and MarmotKit is still finishing it.
        case cancelling
        /// Every check passed or was skipped. The user opens their chats.
        case ready
        /// The focused step needs the user before onboarding can continue.
        case attention(OnboardingStepStateFfi)
        /// MarmotKit is working through the checks; nothing to do but wait.
        case working(OnboardingStepStateFfi?)
    }

    /// One action a step offers, already in the pane's vocabulary.
    enum Action: Equatable, Hashable {
        case approveRepair
        case continueAnyway
        case retry
        case useRecommendedRelays
        case editDiscoveryRelays
        case continueWithout(OnboardingStepFfi)
        case cancelRepair

        /// A catalog key.
        var titleKey: String {
            switch self {
            case .approveRepair: "Continue"
            case .continueAnyway: "Continue anyway"
            case .retry: "Try Again"
            case .useRecommendedRelays: "Use Default Relays"
            case .editDiscoveryRelays: "Look on Another Relay"
            case .continueWithout(.profile): "Not Now"
            case .continueWithout: "Continue"
            case .cancelRepair: "Back"
            }
        }
    }

    let steps: [OnboardingStepStateFfi]
    let phase: Phase

    init(snapshot: OnboardingSnapshotFfi?, recoveryRequired: Bool) {
        steps = snapshot?.steps ?? []
        if recoveryRequired {
            phase = .recovery
        } else if snapshot?.cancellationPending == true {
            phase = .cancelling
        } else if snapshot?.ready == true {
            phase = .ready
        } else if let open = steps.first(where: { !Self.isComplete($0.status) }) {
            phase = Self.needsAttention(open.status) ? .attention(open) : .working(open)
        } else {
            phase = .working(nil)
        }
    }

    /// The step the pane is about, if any.
    var focusedStep: OnboardingStepStateFfi? {
        switch phase {
        case .attention(let step): step
        case .working(let step): step
        case .recovery, .cancelling, .ready: nil
        }
    }

    var completedCount: Int {
        steps.filter { Self.isComplete($0.status) }.count
    }

    /// One-based position of the focused step, for the "3 of 6" caption. A ready checklist reads
    /// as its last step; a checklist with no open step reads as however far it got.
    var position: Int {
        if let focusedStep, let index = steps.firstIndex(of: focusedStep) {
            return index + 1
        }
        return max(completedCount, steps.isEmpty ? 0 : 1)
    }

    /// The focused step's actions, most important first: the pane makes the first one its
    /// primary button and the second its secondary.
    var actions: [Action] {
        guard case .attention(let step) = phase else { return [] }
        return Self.actions(for: step)
    }

    static func actions(for step: OnboardingStepStateFfi) -> [Action] {
        let offered = Set(step.actions)
        var actions: [Action] = []
        if offered.contains(.approveRepair) { actions.append(.approveRepair) }
        if offered.contains(.continueAnyway), step.step == .singleDevice { actions.append(.continueAnyway) }
        if offered.contains(.retry) { actions.append(.retry) }
        if offered.contains(.useRecommendedRelays) { actions.append(.useRecommendedRelays) }
        if offered.contains(.editDiscoveryRelays) { actions.append(.editDiscoveryRelays) }
        if offered.contains(.continueWithout) { actions.append(.continueWithout(step.step)) }
        if offered.contains(.cancelRepair) { actions.append(.cancelRepair) }
        return actions
    }

    static func isComplete(_ status: OnboardingStatusFfi) -> Bool {
        status == .passed || status == .skipped
    }

    static func needsAttention(_ status: OnboardingStatusFfi) -> Bool {
        switch status {
        case .needsInput, .retryableFailure, .waitingForSigner: true
        case .pending, .checking, .passed, .skipped: false
        }
    }

    // MARK: - Copy (catalog keys)

    var titleKey: String {
        switch phase {
        case .recovery, .attention: "A little more to do"
        case .cancelling: "Closing sign-in"
        case .ready: "You’re ready to chat"
        case .working: "Getting ready to chat"
        }
    }

    var subtitleKey: String {
        switch phase {
        case .recovery: "This profile’s saved sign-in setup needs recovery."
        case .cancelling: "Finishing cancellation. Your saved identity and completed changes will be kept."
        case .ready: "Open Chats to start messaging."
        case .attention: "Review the item below to continue."
        case .working: "We’re checking your profile and connection."
        }
    }

    static func titleKey(_ step: OnboardingStepFfi) -> String {
        switch step {
        case .profile: "Your profile"
        case .follows: "People you follow"
        case .relays: "Your relays"
        case .inboxRelays: "Message inbox"
        case .singleDevice: "Using one device"
        case .keyPackage: "Secure messaging"
        }
    }

    static func symbol(_ step: OnboardingStepFfi) -> String {
        switch step {
        case .profile: "person.crop.circle"
        case .follows: "person.2"
        case .relays: "antenna.radiowaves.left.and.right"
        case .inboxRelays: "tray"
        case .singleDevice: "laptopcomputer"
        case .keyPackage: "lock.shield"
        }
    }

    /// What the step is for, shown under its title while nothing has gone wrong with it.
    static func descriptionKey(_ step: OnboardingStepFfi) -> String {
        switch step {
        case .profile:
            "A name and photo help people recognize you. You can add them now or later in Settings."
        case .follows: "You can continue without changing the people you follow."
        case .relays:
            "Read relays find public information. Write relays publish your public information. A relay can do both."
        case .inboxRelays: "Inbox relays receive invitations to new chats and groups."
        case .singleDevice:
            "White Noise does not yet sync conversations across devices. We recommend using this profile on one device."
        case .keyPackage: "Secure messaging must be ready before you can open Chats."
        }
    }

    /// The status line under a step's title. The "needs attention" statuses split three ways, as
    /// on iOS: an acknowledgment, an optional review, or a fix the user cannot skip.
    static func statusKey(_ step: OnboardingStepStateFfi) -> String {
        switch step.status {
        case .pending: return "Waiting"
        case .checking: return "Checking…"
        case .passed: return "Done"
        case .skipped: return "Skipped"
        case .waitingForSigner: return "Couldn’t access your private key"
        case .needsInput, .retryableFailure:
            if step.step == .singleDevice, step.actions.contains(.continueAnyway) {
                return "Review to continue"
            }
            if step.step == .profile || step.step == .follows, step.actions.contains(.continueWithout) {
                return "Review or skip"
            }
            return "Fix to continue"
        }
    }

    static func issueKey(_ issue: OnboardingIssueFfi) -> String {
        switch issue {
        case .missing: "No published settings were found."
        case .malformed: "The published settings could not be read."
        case .futureDated: "The published settings have a future date. Check your device clock and retry."
        case .invalidRelay: "A relay address is invalid."
        case .retiredRelay: "A relay is no longer supported."
        case .unsafeRelay: "A relay address is not safe to connect to."
        case .unreachable: "A relay could not be reached."
        case .timedOut: "A relay did not respond in time. Your existing settings have not been replaced."
        case .authenticationRequired: "A relay requires authentication."
        case .paymentRequired: "A relay requires payment."
        case .accessRestricted: "A relay restricted access."
        case .noUsableRoute: "No usable relay route was found."
        case .publicationFailed: "Publishing did not finish. Retry to continue from the saved progress."
        case .signerUnavailable: "Your signer is unavailable."
        case .signerRejected: "Your signer declined the request."
        case .recordChanged: "The published settings changed. Check again before approving a repair."
        case .interrupted: "This check was interrupted. Your progress is saved."
        case .tooManyRelays: "The relay list is too large."
        case .multiDeviceUnsupported: "Conversations do not sync across devices yet."
        case .otherInstallationPossible: "Another installation may exist."
        case .discoveryIncomplete: "Some discovery sources could not be checked."
        }
    }
}
