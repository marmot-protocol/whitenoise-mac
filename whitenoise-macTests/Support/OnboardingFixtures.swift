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
    /// `ImageRenderer`, this evaluates the content of a `ScrollView`, which every step screen has.
    @MainActor
    static func hostedSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.environment(WorkspaceState.preview())))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// What the scroll view inside `view` shows when `view` is laid out at exactly `size`.
    struct ScrollGeometry {
        /// The height of the visible area.
        let viewportHeight: CGFloat
        /// The height of everything the scroll view can show — the column, all of it.
        let documentHeight: CGFloat
        /// Where the visible area starts, from the top of the document.
        let visibleTop: CGFloat
        /// Where the visible area ends once scrolled all the way down.
        let maximumVisibleBottom: CGFloat
    }

    /// Hosts `view` in an offscreen window at `size` and reads the first `NSScrollView` AppKit
    /// built for it — SwiftUI's `ScrollView` is one on macOS. `nil` when there is none, which is
    /// the failure a test of "this pane scrolls" exists to catch: without a scroll view the column
    /// is clipped by the window and whatever is past the edge cannot be reached at all.
    ///
    /// Scrolling to the bottom is done here too, so a test can ask whether the end of the document
    /// — where the primary button is — comes into view, rather than only whether it exists.
    @MainActor
    static func scrollGeometry(_ view: some View, size: CGSize) -> ScrollGeometry? {
        let host = NSHostingView(rootView: AnyView(view.environment(WorkspaceState.preview())))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let scrollView = firstScrollView(in: host), let document = scrollView.documentView else {
            return nil
        }
        let clip = scrollView.contentView
        let visibleTop = document.isFlipped ? clip.bounds.minY : document.frame.height - clip.bounds.maxY

        let bottomOrigin = document.isFlipped ? max(0, document.frame.height - clip.bounds.height) : 0
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: bottomOrigin))
        scrollView.reflectScrolledClipView(clip)
        let maximumVisibleBottom =
            document.isFlipped ? clip.bounds.maxY : document.frame.height - clip.bounds.minY

        return ScrollGeometry(
            viewportHeight: clip.bounds.height,
            documentHeight: document.frame.height,
            visibleTop: visibleTop,
            maximumVisibleBottom: maximumVisibleBottom
        )
    }

    @MainActor
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
