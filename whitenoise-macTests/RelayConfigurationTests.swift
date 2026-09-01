//
//  RelayConfigurationTests.swift
//  whitenoise-macTests
//

import Foundation
import Testing

@testable import whitenoise_mac

/// What the Relays page derives from one `RelaySettingsSnapshot`: the union list, each relay's
/// roles and publish state, the coverage the recovery callout reads, and the two rules that make
/// a role's last relay unremovable.
///
/// Pure values throughout — no runtime, no account — so these run in their own suite rather than
/// inside the runtime-backed file.
@MainActor struct RelayConfigurationTests {
    private func snapshot(
        nip65: [String],
        inbox: [String],
        publishedNip65: [String]? = nil,
        publishedInbox: [String]? = nil
    ) -> RelaySettingsSnapshot {
        RelaySettingsSnapshot(
            nip65: nip65,
            inbox: inbox,
            defaultRelays: MarmotClient.seedRelays,
            bootstrapRelays: MarmotClient.seedRelays,
            publishedNip65: publishedNip65 ?? nip65,
            publishedInbox: publishedInbox ?? inbox,
            missing: [],
            isComplete: true
        )
    }

    // MARK: - The union list

    @Test func endpointsUnionBothListsInListOrder() {
        let endpoints = snapshot(
            nip65: ["wss://a.example", "wss://shared.example"],
            inbox: ["wss://shared.example", "wss://b.example"]
        ).endpoints

        #expect(endpoints.map(\.url) == ["wss://a.example", "wss://shared.example", "wss://b.example"])
        #expect(endpoints.map(\.roles) == [[.profile], [.profile, .inbox], [.inbox]])
    }

    @Test func endpointsDedupeOnRelayIdentityRatherThanOnTheString() {
        let endpoints = snapshot(
            nip65: ["wss://A.example/"],
            inbox: ["wss://a.example"]
        ).endpoints

        #expect(endpoints.count == 1)
        #expect(endpoints[0].roles == [.profile, .inbox])
    }

    @Test func endpointsNameTheSeedRelaysAndHostEverythingElse() {
        let endpoints = snapshot(
            nip65: ["wss://relay.eu.whitenoise.chat", "wss://relay.damus.io"],
            inbox: []
        ).endpoints

        #expect(endpoints[0].displayName == "White Noise EU")
        #expect(endpoints[1].displayName == "relay.damus.io")
    }

    @Test func endpointsFlagCleartextRelays() {
        let endpoints = snapshot(nip65: ["wss://a.example", "ws://127.0.0.1:7000"], inbox: []).endpoints

        #expect(endpoints.map(\.isInsecure) == [false, true])
    }

    // MARK: - Publish state

    @Test func aRelayMissingFromOneOfItsPublishedListsIsNotPublished() {
        let snapshot = snapshot(
            nip65: ["wss://shared.example"],
            inbox: ["wss://shared.example"],
            publishedNip65: ["wss://shared.example"],
            publishedInbox: []
        )

        #expect(snapshot.endpoints.map(\.publishState) == [.notPublished])
    }

    @Test func aRelayInEveryPublishedListItServesIsPublished() {
        #expect(
            snapshot(nip65: ["wss://a.example"], inbox: ["wss://a.example"]).endpoints
                .map(\.publishState) == [.published])
    }

    // MARK: - Coverage and the recovery summary

    @Test func coverageReportsWhatEachRoleIsMissing() {
        let unpublished = snapshot(
            nip65: ["wss://a.example"],
            inbox: ["wss://a.example"],
            publishedNip65: ["wss://a.example"],
            publishedInbox: []
        )

        #expect(unpublished.coverage(for: .profile) == .published)
        #expect(unpublished.coverage(for: .inbox) == .notPublished)
        #expect(unpublished.relaysNeedAttention)
        #expect(
            unpublished.relayAttentionSummary
                == L10n.string(
                    "Your inbox relay list hasn't been published yet, so invitations to new chats may not arrive."))
    }

    @Test func aFullyPublishedConfigurationNeedsNoAttention() {
        let published = snapshot(nip65: ["wss://a.example"], inbox: ["wss://a.example"])

        #expect(!published.relaysNeedAttention)
        #expect(published.relayAttentionSummary.isEmpty)
    }

    @Test func neitherListPublishedSaysBothConsequences() {
        let neither = snapshot(
            nip65: ["wss://a.example"],
            inbox: ["wss://a.example"],
            publishedNip65: [],
            publishedInbox: []
        )

        #expect(
            neither.relayAttentionSummary
                == L10n.string(
                    "Your relay lists haven't been published yet, so other people may not find you and "
                        + "invitations to new chats may not arrive."))
    }

    /// A role with no relay at all is what the core substitutes defaults for, so it should not
    /// normally be reachable — but the callout still has to say something true if it is.
    @Test func anUnassignedRoleAsksForARelay() {
        let unassigned = snapshot(nip65: ["wss://a.example"], inbox: [])

        #expect(unassigned.coverage(for: .inbox) == .unassigned)
        #expect(
            unassigned.relayAttentionSummary
                == String(format: L10n.string("Choose a relay for %@."), RelayRole.inbox.label))
    }

    // MARK: - The last relay of a role

    @Test func theOnlyRelayForARoleIsRecognizedRegardlessOfSpelling() {
        let snapshot = snapshot(nip65: ["wss://a.example", "wss://b.example"], inbox: ["wss://a.example"])

        #expect(snapshot.isOnlyRelay("wss://A.example/", for: .inbox))
        #expect(!snapshot.isOnlyRelay("wss://a.example", for: .profile))
        #expect(snapshot.rolesDependingOnly(on: "wss://a.example") == [.inbox])
        #expect(snapshot.rolesDependingOnly(on: "wss://b.example").isEmpty)
    }

    /// Two spellings of one relay are one relay, so a role holding only those is still down to
    /// its last one and must refuse.
    ///
    /// The guard used to compare a *raw* count against an identity match, which disagreed with
    /// itself exactly here: `count == 2` said "not the last one" while both entries answered to
    /// the same key. `setRelayRole` then removed all matching entries and published an empty
    /// list, which the core rejects outright (`MissingDefaultRelays`); `removeRelay` took its
    /// own `!remaining.isEmpty` branch and silently skipped the role, leaving the relay half
    /// removed — gone from the other role, still here, and no error said.
    @Test func duplicateSpellingsOfOneRelayStillCountAsTheLastRelay() {
        let snapshot = snapshot(
            nip65: ["wss://dup.example", "wss://DUP.example/"],
            inbox: ["wss://dup.example", "wss://other.example"]
        )

        #expect(snapshot.isOnlyRelay("wss://dup.example", for: .profile))
        #expect(snapshot.isOnlyRelay("wss://DUP.example/", for: .profile))
        #expect(snapshot.rolesDependingOnly(on: "wss://dup.example") == [.profile])

        // The inbox list holds two genuinely different relays, so it is not down to its last.
        #expect(!snapshot.isOnlyRelay("wss://dup.example", for: .inbox))
    }

    /// A relay absent from a role is never that role's last one, however many duplicates the
    /// role does hold — the identity match still has to land.
    @Test func aRelayNotAssignedToARoleIsNotItsLastRelay() {
        let snapshot = snapshot(nip65: ["wss://dup.example", "wss://DUP.example/"], inbox: ["wss://a.example"])

        #expect(!snapshot.isOnlyRelay("wss://elsewhere.example", for: .profile))
        #expect(snapshot.rolesDependingOnly(on: "wss://elsewhere.example").isEmpty)
    }

    @Test func aSingleRelayInBothListsIsTheLastOneForBothRoles() {
        let snapshot = snapshot(nip65: ["wss://only.example"], inbox: ["wss://only.example"])

        #expect(snapshot.rolesDependingOnly(on: "wss://only.example") == [.profile, .inbox])
    }

    // MARK: - Defaults

    @Test func onlyTheSeedRelaysInBothListsCountAsTheDefaultConfiguration() {
        #expect(snapshot(nip65: MarmotClient.seedRelays, inbox: MarmotClient.seedRelays).isDefaultRelayConfiguration)
        #expect(
            !snapshot(nip65: MarmotClient.seedRelays, inbox: ["wss://custom.example"])
                .isDefaultRelayConfiguration)
        #expect(
            !snapshot(nip65: MarmotClient.seedRelays.reversed(), inbox: MarmotClient.seedRelays)
                .isDefaultRelayConfiguration)
    }

    // MARK: - Relay URL identity

    @Test func normalizationTrimsWhitespaceAndTrailingSlashes() {
        #expect(RelayURLValidator.normalized("  wss://a.example//  ") == "wss://a.example")
        #expect(RelayURLValidator.identity("WSS://A.Example/") == "wss://a.example")
    }
}
