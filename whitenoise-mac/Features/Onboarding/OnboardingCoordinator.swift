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

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    init(accountRef: String, runtime: any MarmotRuntime) {
        self.accountRef = accountRef
        self.runtime = runtime
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

    var currentStep: OnboardingStepStateFfi? {
        snapshot?.steps.first { $0.status != .passed && $0.status != .skipped }
    }

    var offeredActions: Set<OnboardingActionFfi> {
        Set(snapshot?.steps.flatMap(\.actions) ?? [])
    }

    func run() async { await update { try await $0.runOnboarding(accountRef: $1) } }

    func retry(_ step: OnboardingStepFfi) async {
        await update { try await $0.retryOnboardingStep(accountRef: $1, step: step) }
    }

    func skip(_ step: OnboardingStepFfi) async {
        await update { try await $0.continueOnboardingWithout(accountRef: $1, step: step) }
    }

    func proposeProfile(_ profile: UserProfileMetadataFfi) async {
        await update { try await $0.proposeOnboardingProfile(accountRef: $1, profile: profile) }
    }

    func proposeFollows(_ follows: [String]) async {
        await update { try await $0.proposeOnboardingFollows(accountRef: $1, follows: follows) }
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

    func acknowledgeSingleDevice() async {
        guard let revision = snapshot?.revision else { return }
        await update { try await $0.acknowledgeOnboardingSingleDevice(accountRef: $1, revision: revision) }
    }

    func cancelRepair() async {
        await update { try await $0.cancelOnboardingRepair(accountRef: $1) }
    }

    func recover(acknowledgeLatestOnlyEvidence: Bool) async {
        do {
            _ = try await runtime.recoverOnboarding(
                accountRef: accountRef,
                acknowledgeLatestOnlyEvidence: acknowledgeLatestOnlyEvidence
            )
            start()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func cancel() async -> Bool {
        do {
            try await runtime.cancelOnboarding(accountRef: accountRef)
            start()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func restoreAndObserve() async {
        do {
            let restored = try await FFIExecutor.run { [runtime, accountRef] in
                (
                    try runtime.onboardingSnapshot(accountRef: accountRef),
                    try runtime.onboardingRecoveryRequired(accountRef: accountRef)
                )
            }
            try Task.checkCancellation()
            snapshot = restored.0
            recoveryRequired = restored.1
            guard restored.0 != nil else { return }

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
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            install(try await operation(runtime, accountRef))
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func install(_ replacement: OnboardingSnapshotFfi) {
        guard snapshot == nil || replacement.revision >= snapshot!.revision else { return }
        snapshot = replacement
        if !replacement.ready { hasShownIncompleteSetup = true }
        recoveryRequired = replacement.recoveryEpoch != nil
        error = nil
    }

    private func runAutomaticallyIfNeeded() {
        guard !isDurablyReady,
            snapshot?.cancellationPending == false,
            currentStep?.status == .pending,
            operationTask == nil
        else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.operationTask = nil
            self.runAutomaticallyIfNeeded()
        }
    }
}
