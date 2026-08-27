//
//  ImprovementsPromptTests.swift
//  whitenoise-macTests
//

import Foundation
import Testing

@testable import whitenoise_mac

/// The record behind the one-time "Help Improve White Noise" ask.
///
/// This is the half that can be tested without a runtime: which identities the store believes have
/// already been offered the choice. When the prompt actually goes up — the part that needs a signed-
/// in workspace — is guarded next to the other sign-up and sign-in tests, which is where the fake
/// runtime lives.
///
/// Deliberately records only *that* an account was asked, never what it answered, so nothing here
/// asserts anything about the two switches themselves.
@Suite(.serialized)
@MainActor
struct ImprovementsPromptTests {

    private static func store(suite: String) throws -> (UserDefaultsImprovementsPromptStore, UserDefaults) {
        // A named suite, never `.standard`: writing into the test host's own preferences would let
        // the first run record an account and every later run find it already offered — passing
        // for the wrong reason, and only on a machine that had run the suite before.
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (UserDefaultsImprovementsPromptStore(defaults: defaults), defaults)
    }

    @Test func theStoreRecordsAccountsIndependentlyAndCaseInsensitively() throws {
        let suite = "whitenoise.mac.tests.improvementsPrompt.records"
        let (store, defaults) = try Self.store(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: "AABB"))

        // Account hex reaches this from two places that disagree about case, the same reason
        // `UserDefaultsChatRestorationStore` normalizes: a mismatch here re-asks a recorded
        // identity rather than failing loudly.
        store.markOffered(toOwnerAccountIdHex: "AABB")
        #expect(store.hasBeenOffered(toOwnerAccountIdHex: "aabb"))
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: "ccdd"))

        store.markOffered(toOwnerAccountIdHex: "  ccdd  ")
        #expect(store.hasBeenOffered(toOwnerAccountIdHex: "ccdd"))

        store.forget(ownerAccountIdHex: "aabb")
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: "AABB"))
        #expect(store.hasBeenOffered(toOwnerAccountIdHex: "ccdd"))

        store.clearAll()
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: "ccdd"))
    }

    @Test func theRecordSurvivesANewStoreOverTheSameDefaults() throws {
        let suite = "whitenoise.mac.tests.improvementsPrompt.persistence"
        let (store, defaults) = try Self.store(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.markOffered(toOwnerAccountIdHex: "aabb")

        // The prompt is only ever reached from a fresh sign-up or sign-in, so a record that did
        // not outlive the launch that wrote it would mean the identity is asked again on a path
        // it can no longer take — or never asked at all.
        let reopened = UserDefaultsImprovementsPromptStore(defaults: defaults)
        #expect(reopened.hasBeenOffered(toOwnerAccountIdHex: "aabb"))
    }

    /// An identity with no hex cannot be recorded as asked, so asking it would repeat forever.
    /// `presentImprovementsPromptIfNeeded()` refuses that case; this pins the store's half of it.
    @Test func anAccountWithNoHexIsNeverRecorded() throws {
        let suite = "whitenoise.mac.tests.improvementsPrompt.empty"
        let (store, defaults) = try Self.store(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.markOffered(toOwnerAccountIdHex: "   ")
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: "   "))
        #expect(!store.hasBeenOffered(toOwnerAccountIdHex: ""))
    }
}
