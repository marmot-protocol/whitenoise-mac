//
//  OnboardingFindingFfi+Preview.swift
//  whitenoise-mac
//

import MarmotKit

extension OnboardingFindingFfi {
    /// A finding that carries only what the account-setup screens read — the issue and its relay —
    /// with MDK 0.14's diagnostic fields left neutral, for `#Preview` and test fixtures. Not
    /// `DEBUG`-only: `#Preview` blocks compile in Release too.
    nonisolated static func preview(issue: OnboardingIssueFfi, endpoint: String?) -> OnboardingFindingFfi {
        OnboardingFindingFfi(
            issue: issue,
            endpoint: endpoint,
            context: .unknown,
            purpose: .unknown,
            outcome: .unknown,
            declaredCapability: .none,
            actions: [],
            observedRevision: nil
        )
    }
}
