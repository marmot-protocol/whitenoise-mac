//
//  OnboardingFixtures.swift
//  whitenoise-macTests
//

import AppKit
import MarmotKit
import SwiftUI

@testable import whitenoise_mac

/// Builders for MarmotKit's onboarding records, shared by the account-setup suites.
enum OnboardingFixtures {
    static func step(
        _ step: OnboardingStepFfi,
        _ status: OnboardingStatusFfi,
        findings: [OnboardingFindingFfi] = [],
        actions: [OnboardingActionFfi] = []
    ) -> OnboardingStepStateFfi {
        OnboardingStepStateFfi(step: step, status: status, findings: findings, actions: actions, checkedAt: nil)
    }

    static func proposal(
        _ step: OnboardingStepFfi,
        revision: UInt64 = 1,
        reads: [String] = [],
        writes: [String] = [],
        profile: UserProfileMetadataFfi? = nil
    ) -> OnboardingRepairProposalFfi {
        OnboardingRepairProposalFfi(
            step: step, revision: revision, previousEventId: nil, readRelays: reads, writeRelays: writes,
            profile: profile, follows: nil, relayRepair: nil
        )
    }

    static func profile(name: String) -> UserProfileMetadataFfi {
        UserProfileMetadataFfi(
            name: name, displayName: name, about: nil, picture: nil, banner: nil, nip05: nil, lud16: nil
        )
    }

    static func snapshot(
        steps: [OnboardingStepStateFfi],
        ready: Bool = false,
        revision: UInt64 = 1
    ) -> OnboardingSnapshotFfi {
        OnboardingSnapshotFfi(
            accountIdHex: "account-id",
            recoveryEpoch: nil,
            revision: revision,
            ready: ready,
            steps: steps,
            proposal: nil,
            singleDeviceNotice: nil,
            cancellationPending: false
        )
    }

    static func notice(_ discovery: OnboardingDeviceDiscoveryFfi) -> OnboardingSingleDeviceNoticeFfi {
        OnboardingSingleDeviceNoticeFfi(
            discovery: discovery, otherPackages: [], discoveryComplete: true, acknowledgedAt: nil
        )
    }

    /// A coordinator over `runtime` that has installed `snapshot`, the way the observation would.
    @MainActor
    static func coordinator(
        _ snapshot: OnboardingSnapshotFfi,
        runtime: FakeMarmotRuntime = FakeMarmotRuntime(accounts: [])
    ) async -> OnboardingCoordinator {
        runtime.onboardingState = snapshot
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        await model.run()
        return model
    }

    /// Lays `view` out in a window-less hosting view and returns the size it settled on. Unlike
    /// `ImageRenderer`, this evaluates the content of a `ScrollView`, which every step sheet has.
    @MainActor
    static func hostedSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.environment(WorkspaceState.preview())))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
