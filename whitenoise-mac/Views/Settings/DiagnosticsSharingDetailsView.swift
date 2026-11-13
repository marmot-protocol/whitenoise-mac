//
//  DiagnosticsSharingDetailsView.swift
//  whitenoise-mac
//
//  "What’s shared": the full disclosure behind the two data-sharing switches, in the same sections
//  and words as iOS's `DiagnosticsSharingDetailsView`, so the two apps describe one MarmotKit
//  policy identically.
//

import SwiftUI

struct DiagnosticsSharingDetailsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DiagnosticsDisclosureSection(
                    title: L10n.string("Usage and telemetry"),
                    paragraphs: [
                        L10n.string(
                            "Feature activity and telemetry data include feature usage counts and app performance metrics. Usage data uses temporary session identifiers, and telemetry uses a resettable installation identifier. Neither includes account or group identifiers."
                        )
                    ]
                )
                DiagnosticsDisclosureSection(
                    title: L10n.string("Group diagnostic logs"),
                    paragraphs: [
                        L10n.string(
                            "Group diagnostic logs help investigate group reliability and consistency. They include technical identifiers, timestamps, and membership changes, using hashed references instead of member identities. They never contain message contents, profile names, group names, or private keys."
                        ),
                        L10n.string(
                            "Enabling group diagnostic log sharing may upload logs already stored on this device."
                        ),
                    ]
                )
                DiagnosticsDisclosureSection(
                    title: L10n.string("Data retention"),
                    paragraphs: [
                        L10n.string(
                            "Group diagnostic logs are deleted from our servers after 30 days, telemetry after 90 days, and product analytics after 180 days."
                        )
                    ]
                )
                DiagnosticsDisclosureSection(
                    title: L10n.string("Turning sharing off"),
                    paragraphs: [
                        L10n.string(
                            "Turning these off stops new recording and prevents new automatic uploads. An automatic log upload batch already in progress may finish. Turning these off does not delete data already stored on this device or our servers."
                        )
                    ]
                )
                if let privacyPolicyURL = URL(string: "https://www.whitenoise.chat/privacy") {
                    Link(destination: privacyPolicyURL) {
                        Text(L10n.string("Privacy Policy")).underline()
                    }
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One titled block of the disclosure.
private struct DiagnosticsDisclosureSection: View {
    let title: String
    let paragraphs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .wnFont(.semiBold14)
                .accessibilityAddTraits(.isHeader)
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    DiagnosticsSharingDetailsView()
        .frame(width: 480, height: 440)
}
