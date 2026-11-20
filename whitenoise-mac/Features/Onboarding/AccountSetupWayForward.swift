import Foundation
import MarmotKit

/// Keeps every blocking setup state actionable. Ported from `whitenoise-ios`'s
/// `AccountSetupWayForward`.
///
/// Two states used to leave the user with nothing to press. A step whose actions are all ones the
/// Mac does not render (`reconnectSigner` — sign-in imports a key, there is no external signer —
/// or `editFollows`, since setup never publishes a follow list) now offers Cancel Sign-In on its
/// screen; see `AccountSetupNoActionLines`. And a run that returned with the current step still
/// waiting or checking, which a spinner would otherwise wait on forever, offers Check Again on the
/// checklist; see `OnboardingCoordinator.needsCheckAgain`.
nonisolated enum AccountSetupWayForward {
    /// The step a finished run left waiting or checking: the first unfinished one, when MarmotKit
    /// is neither done nor cancelling and that step is not asking the user for anything.
    static func stalledStep(_ snapshot: OnboardingSnapshotFfi?) -> OnboardingStepStateFfi? {
        guard let snapshot, !snapshot.ready, !snapshot.cancellationPending,
            let step = snapshot.steps.first(where: { !AccountSetupGuide.isComplete($0.status) }),
            step.status == .pending || step.status == .checking
        else { return nil }
        return step
    }

    /// Said on a step screen that can only cancel the sign-in. A catalog key.
    static let cannotContinueKey =
        "This sign-in can’t continue from here. Cancel sign-in, then sign in again. Changes that were already published are kept."

    static let checkAgainTitleKey = "Checks didn’t finish"
    static let checkAgainSubtitleKey = "Check again to continue signing in."
    static let checkAgainActionKey = "Check Again"
}
