import Foundation
import MarmotKit

/// What the guided account-setup pane shows for one onboarding snapshot: every step as a named row
/// with its state, which step (if any) the user has to review, and the header copy.
///
/// Derived, never stored. The snapshot is the authority (see `OnboardingCoordinator`), so this is
/// rebuilt from it on every render and cannot drift from what MarmotKit says. The shape follows
/// `whitenoise-ios`'s `AccountSetupPresentation` — same step titles, same header copy, same
/// three-way split of the "needs attention" statuses, same vertical checklist with one reviewable
/// row that opens that step's own screen.
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

    /// One row's state, as iOS's `AccountSetupPresentation.CheckState` names it. The three
    /// "needs attention" cases are the same MarmotKit statuses split by what the user is asked
    /// for: an acknowledgment, an optional review, or a fix that cannot be skipped.
    enum CheckState: Equatable {
        case pending, checking, passed, skipped
        case optionalReview, requiredFix, acknowledgment

        /// A catalog key.
        var subtitleKey: String {
            switch self {
            case .pending: "Waiting"
            case .checking: "Checking…"
            case .passed: "Done"
            case .skipped: "Skipped"
            case .optionalReview: "Review or skip"
            case .requiredFix: "Fix to continue"
            case .acknowledgment: "Review to continue"
            }
        }

        var symbol: String {
            switch self {
            case .pending, .checking: "circle"
            case .passed: "checkmark.circle.fill"
            case .skipped: "minus.circle"
            case .optionalReview, .acknowledgment: "exclamationmark.triangle.fill"
            case .requiredFix: "xmark.circle.fill"
            }
        }

        var needsAttention: Bool {
            switch self {
            case .optionalReview, .requiredFix, .acknowledgment: true
            case .pending, .checking, .passed, .skipped: false
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
            phase = Self.checkState(open).needsAttention ? .attention(open) : .working(open)
        } else {
            phase = .working(nil)
        }
    }

    /// The one step whose row opens its review screen, and which Review and Continue opens: the
    /// first unfinished step, when it needs the user. Later steps cannot be reviewed out of order.
    var reviewStep: OnboardingStepFfi? {
        guard case .attention(let step) = phase else { return nil }
        return step.step
    }

    static func checkState(_ step: OnboardingStepStateFfi) -> CheckState {
        switch step.status {
        case .pending: return .pending
        case .checking: return .checking
        case .passed: return .passed
        case .skipped: return .skipped
        case .needsInput, .retryableFailure, .waitingForSigner:
            if step.step == .singleDevice, step.actions.contains(.continueAnyway) {
                return .acknowledgment
            }
            // Only describe skipping when the snapshot offers an action the pane supports.
            if step.step == .profile || step.step == .follows, step.actions.contains(.continueWithout) {
                return .optionalReview
            }
            return .requiredFix
        }
    }

    static func isComplete(_ status: OnboardingStatusFfi) -> Bool {
        status == .passed || status == .skipped
    }

    // MARK: - Copy (catalog keys)

    var titleKey: String {
        switch phase {
        case .recovery: "Sign-in setup needs recovery"
        case .attention: "A little more to do"
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

    /// What the step is for, shown on its review screen.
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

    /// The single-device step's consent button: plain Continue when nothing else was found.
    static func deviceActionKey(_ discovery: OnboardingDeviceDiscoveryFfi?) -> String {
        discovery == .noneFound ? "Continue" : "Continue anyway"
    }

    static func deviceNoticeKey(_ discovery: OnboardingDeviceDiscoveryFfi) -> String {
        switch discovery {
        case .otherInstallationPossible:
            "We found signs of another installation. This can also happen after reinstalling. Invitations may reach only one installation, and chats will not appear on both."
        case .noneFound:
            "No other installation was found on the sources we checked. This does not guarantee that the profile is unused elsewhere."
        case .unknown:
            "We couldn’t determine whether another installation exists. Invitations may reach only one installation, and chats will not appear on both."
        }
    }

    /// The line a finding prints under its step, or `nil` for one that is not a fault.
    static func issueKey(_ issue: OnboardingIssueFfi) -> String? {
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
        // MDK records only that the relay answered, not that it accepts writes: nothing to report.
        case .inspectionCompleted: nil
        }
    }
}
