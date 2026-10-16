import Foundation
import MarmotKit
import Observation

/// Restores and drives MarmotKit's durable onboarding checkpoint for one account. The UI renders
/// this snapshot instead of maintaining a second checklist that can diverge after termination.
@MainActor
@Observable
final class OnboardingCoordinator {
    private(set) var snapshot: OnboardingSnapshotFfi?
    private(set) var recoveryRequired = false
    private(set) var isBusy = false
    private(set) var isObserving = false
    private(set) var error: String?
    /// Set once this coordinator has installed a snapshot that was not ready, i.e. the user has
    /// been walked through at least one check on this launch. Only then does entering the chats
    /// wait for `openChats()`; an account whose checkpoint was already ready goes straight in.
    private(set) var hasShownIncompleteSetup = false
    private(set) var hasConfirmedOpenChats = false
    /// Set by the shell once it has left onboarding for this account's chats. From then on the
    /// checkpoint is history: Settings → Add Account reopens onboarding with this scope still
    /// active, and must land on Welcome rather than on this account's finished checklist.
    private(set) var hasEnteredChats = false

    @ObservationIgnored private let accountRef: String
    /// Nil only for a preview, which renders a fixed snapshot and runs nothing.
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    /// The revision an automatic follows action last ran against, so a core that answers it with
    /// the same snapshot stops the loop instead of spinning on it. Not a staleness token: it never
    /// guards a write, it only refuses to repeat one automatic command on an unchanged snapshot.
    @ObservationIgnored private var lastAutomaticRevision: UInt64?

    init(accountRef: String, runtime: any MarmotRuntime) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    private init(previewSnapshot: OnboardingSnapshotFfi) {
        accountRef = previewSnapshot.accountIdHex
        runtime = nil
        snapshot = previewSnapshot
    }

    /// A coordinator that shows `snapshot` and does nothing when pressed, for `#Preview`. Not
    /// `DEBUG`-only: `#Preview` blocks compile in Release too.
    static func preview(
        steps: [OnboardingStepStateFfi],
        proposal: OnboardingRepairProposalFfi? = nil,
        singleDeviceNotice: OnboardingSingleDeviceNoticeFfi? = nil
    ) -> OnboardingCoordinator {
        OnboardingCoordinator(
            previewSnapshot: OnboardingSnapshotFfi(
                accountIdHex: "preview",
                recoveryEpoch: nil,
                revision: 1,
                ready: false,
                steps: steps,
                proposal: proposal,
                singleDeviceNotice: singleDeviceNotice,
                cancellationPending: false
            )
        )
    }

    func start() {
        stop()
        observationTask = Task { [weak self] in await self?.restoreAndObserve() }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        operationTask?.cancel()
        operationTask = nil
        isBusy = false
        isObserving = false
    }

    var isDurablyReady: Bool {
        snapshot?.ready == true && snapshot?.cancellationPending == false
    }

    /// Whether the shell may leave onboarding for the chat list. A guided setup ends on its own
    /// "You’re ready to chat" step, which the user leaves with Open Chats, instead of the chat list
    /// replacing the checklist the moment the last check passes.
    var canEnterChats: Bool {
        isDurablyReady && (!hasShownIncompleteSetup || hasConfirmedOpenChats)
    }

    func openChats() {
        guard isDurablyReady else { return }
        hasConfirmedOpenChats = true
    }

    /// Records that the shell entered the chats. See `hasEnteredChats`.
    func didEnterChats() {
        guard canEnterChats else { return }
        hasEnteredChats = true
    }

    var currentStep: OnboardingStepStateFfi? {
        snapshot?.steps.first { !AccountSetupGuide.isComplete($0.status) }
    }

    func run() async { await update { try await $0.runOnboarding(accountRef: $1) } }

    func retry(_ step: OnboardingStepFfi) async {
        await update { try await $0.retryOnboardingStep(accountRef: $1, step: step) }
    }

    func skip(_ step: OnboardingStepFfi) async {
        await update { try await $0.continueOnboardingWithout(accountRef: $1, step: step) }
    }

    func proposeRelays(step: OnboardingStepFfi, read: [String], write: [String]) async {
        await update {
            try await $0.proposeOnboardingRelays(
                accountRef: $1, step: step, readRelays: read, writeRelays: write
            )
        }
    }

    func proposeRecommendedRelays(step: OnboardingStepFfi) async {
        await update { try await $0.proposeOnboardingRecommendedRelays(accountRef: $1, step: step) }
    }

    func setDiscoveryRelays(_ relays: [String]) async {
        await update { try await $0.setOnboardingDiscoveryRelays(accountRef: $1, discoveryRelays: relays) }
    }

    func approveRepair() async {
        guard let revision = snapshot?.revision else { return }
        await update { try await $0.approveOnboardingRepair(accountRef: $1, revision: revision) }
    }

    /// Saves the profile step's form: uploads the cropped photo first, when there is one, then
    /// proposes the profile and approves that proposal, so a single Save publishes it — as iOS's
    /// `AccountSetupCommand.saveProfile` does. Returns whether the step passed.
    ///
    /// Never offered for an interrupted publication: `AccountSetupProfilePlan` turns editing off
    /// for one, and its screen finishes it with `retry(.profile)` instead.
    @discardableResult
    func saveProfile(displayName: String, about: String, avatar: SignUpProfileImage?) async -> Bool {
        let existing = snapshot?.proposal.flatMap { $0.step == .profile ? $0.profile : nil }
        // Save is disabled on an empty form; this keeps an empty one from reaching the upload.
        let staged = avatar.map { _ in "staged" }
        guard
            AccountSetupProfilePlan.metadata(
                displayName: displayName, about: about, pictureURL: staged, existing: existing
            ) != nil
        else { return false }
        await publish(step: .profile) { runtime, accountRef in
            var pictureURL: String?
            if let avatar {
                pictureURL = try await runtime.uploadProfileImage(
                    accountRef: accountRef, data: avatar.data, mediaType: avatar.mediaType, blossomServer: nil
                )
                try Task.checkCancellation()
            }
            // Checked before the upload above, so only a cancelled save gets here empty.
            guard
                let profile = AccountSetupProfilePlan.metadata(
                    displayName: displayName, about: about, pictureURL: pictureURL, existing: existing
                )
            else { throw CancellationError() }
            return try await runtime.proposeOnboardingProfile(accountRef: accountRef, profile: profile)
        }
        return error == nil && snapshot?.steps.first { $0.step == .profile }?.status == .passed
    }

    /// Use Default Relays: proposes the recommended relays for `step` and approves the proposal in
    /// one press. MDK merges the defaults with the checked record and keeps existing entries.
    func useRecommendedRelays(step: OnboardingStepFfi) async {
        await publish(step: step) { try await $0.proposeOnboardingRecommendedRelays(accountRef: $1, step: step) }
    }

    /// Searches the default relays for the profile's existing settings. Publishes nothing.
    func searchDefaultRelays() async {
        await setDiscoveryRelays(MarmotClient.seedRelays)
    }

    /// Runs `propose`, checks that the snapshot it returns offers exactly that proposal for
    /// approval, and approves it.
    private func publish(
        step: OnboardingStepFfi,
        propose: @escaping (any MarmotRuntime, String) async throws -> OnboardingSnapshotFfi
    ) async {
        await update { runtime, accountRef in
            let proposed = try await propose(runtime, accountRef)
            try Task.checkCancellation()
            guard let proposal = proposed.proposal, proposal.step == step,
                proposal.revision == proposed.revision,
                proposed.steps.first(where: { $0.step == step })?.actions.contains(.approveRepair) == true
            else { throw AccountSetupFailure.settingsChanged }
            return try await runtime.approveOnboardingRepair(accountRef: accountRef, revision: proposed.revision)
        }
    }

    func acknowledgeSingleDevice() async {
        guard let revision = snapshot?.revision else { return }
        await update { try await $0.acknowledgeOnboardingSingleDevice(accountRef: $1, revision: revision) }
    }

    func cancelRepair() async {
        await update { try await $0.cancelOnboardingRepair(accountRef: $1) }
    }

    /// Replaces an unreadable checkpoint and starts over. Refused while another command is in
    /// flight or a cancellation is finishing, like `cancel()`.
    func recover(acknowledgeLatestOnlyEvidence: Bool) async {
        guard canStartSessionCommand, let runtime else { return }
        isBusy = true
        do {
            _ = try await runtime.recoverOnboarding(
                accountRef: accountRef,
                acknowledgeLatestOnlyEvidence: acknowledgeLatestOnlyEvidence
            )
            isBusy = false
            start()
        } catch is CancellationError {
            isBusy = false
        } catch {
            isBusy = false
            self.error = error.localizedDescription
        }
    }

    /// Cancels the sign-in. Refused — returning false — while a command is in flight, since
    /// restarting the observation would only drop the wrapper task and leave MarmotKit working
    /// with every button enabled again, and while a cancellation is already finishing. Holds
    /// `isBusy` for its own call, so a second press during the first is refused too.
    @discardableResult
    func cancel() async -> Bool {
        guard canStartSessionCommand, let runtime else { return false }
        isBusy = true
        do {
            try await runtime.cancelOnboarding(accountRef: accountRef)
            isBusy = false
            start()
            return true
        } catch {
            isBusy = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return false
        }
    }

    /// Whether `cancel()` or `recover` may run: nothing is in flight and no cancellation is
    /// finishing.
    var canStartSessionCommand: Bool {
        !isBusy && snapshot?.cancellationPending != true
    }

    private func restoreAndObserve() async {
        guard let runtime else { return }
        do {
            let restored = try await FFIExecutor.run { [runtime, accountRef] in
                (
                    try runtime.onboardingSnapshot(accountRef: accountRef),
                    try runtime.onboardingRecoveryRequired(accountRef: accountRef)
                )
            }
            try Task.checkCancellation()
            guard let restoredSnapshot = restored.0 else {
                snapshot = nil
                recoveryRequired = restored.1
                return
            }
            // Through `install`, like every other checkpoint, so the restored one also counts
            // toward `hasShownIncompleteSetup` — not only the subscription snapshot after it.
            install(restoredSnapshot, restoring: true)
            recoveryRequired = restored.1

            let subscription = try await FFIExecutor.run { [runtime, accountRef] in
                try runtime.subscribeOnboarding(accountRef: accountRef)
            }
            install(runtime.onboardingSubscriptionSnapshot(subscription: subscription))
            isObserving = true
            runAutomaticallyIfNeeded()
            while let replacement = try await runtime.nextOnboardingSnapshot(subscription: subscription) {
                try Task.checkCancellation()
                install(replacement)
                runAutomaticallyIfNeeded()
            }
            isObserving = false
        } catch is CancellationError {
            return
        } catch {
            isObserving = false
            self.error = error.localizedDescription
        }
    }

    private func update(
        _ operation: (any MarmotRuntime, String) async throws -> OnboardingSnapshotFfi
    ) async {
        guard !isBusy, let runtime else { return }
        isBusy = true
        do {
            install(try await operation(runtime, accountRef))
        } catch is CancellationError {
            isBusy = false
            return
        } catch {
            self.error = error.localizedDescription
        }
        isBusy = false
        runAutomaticallyIfNeeded()
    }

    /// Installs `replacement` unless it is older than the checkpoint on screen. A restore skips
    /// that comparison: it starts a new session, and the checkpoint after a cancellation or a
    /// recovery may carry a lower revision than the one it replaces.
    private func install(_ replacement: OnboardingSnapshotFfi, restoring: Bool = false) {
        if !restoring, let snapshot, replacement.revision < snapshot.revision { return }
        snapshot = replacement
        if !replacement.ready { hasShownIncompleteSetup = true }
        recoveryRequired = replacement.recoveryEpoch != nil
        error = nil
    }

    /// Runs a pending check, and settles the follows step the way iOS does: nobody is asked to
    /// review the people they follow during sign-in, so the step is skipped (or a follows proposal
    /// withdrawn) without a screen.
    private func runAutomaticallyIfNeeded() {
        guard !isDurablyReady, !isBusy,
            let snapshot, !snapshot.cancellationPending,
            operationTask == nil
        else { return }
        let operation: @MainActor (OnboardingCoordinator) async -> Void
        // Not after an error: a run that throws rather than returning a failed step would
        // otherwise be retried at once, forever. Try Again (`start()`) clears it.
        if error == nil, currentStep?.status == .pending {
            operation = { await $0.run() }
        } else if error == nil, let followsAction = Self.automaticFollowsAction(snapshot),
            lastAutomaticRevision != snapshot.revision
        {
            lastAutomaticRevision = snapshot.revision
            switch followsAction {
            case .skip: operation = { await $0.skip(.follows) }
            case .cancelRepair: operation = { await $0.cancelRepair() }
            }
        } else {
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            self.operationTask = nil
            self.runAutomaticallyIfNeeded()
        }
    }

    /// The automatic command in flight, if any, for a test to await rather than poll for.
    var automaticOperation: Task<Void, Never>? { operationTask }

    enum AutomaticFollowsAction: Equatable { case skip, cancelRepair }

    /// Ported from `whitenoise-ios`'s `AccountSetupPolicy.automaticAction`.
    static func automaticFollowsAction(_ snapshot: OnboardingSnapshotFfi) -> AutomaticFollowsAction? {
        guard !snapshot.cancellationPending else { return nil }
        if let proposal = snapshot.proposal {
            guard proposal.step == .follows,
                snapshot.steps.first(where: { $0.step == .follows })?.actions.contains(.cancelRepair) == true
            else { return nil }
            return .cancelRepair
        }
        guard let step = snapshot.steps.first(where: { !AccountSetupGuide.isComplete($0.status) }),
            step.step == .follows, step.actions.contains(.continueWithout)
        else { return nil }
        return .skip
    }
}

/// A setup action the coordinator refused before reaching MarmotKit.
enum AccountSetupFailure: LocalizedError, Equatable {
    /// The snapshot no longer offers what the user reviewed.
    case settingsChanged

    var errorDescription: String? {
        switch self {
        case .settingsChanged: L10n.string("Setup changed. Try again to review the latest options.")
        }
    }
}
