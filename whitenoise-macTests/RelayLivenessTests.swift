import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// MarmotKit 0.16.0 relay liveness on the Relays page: a live, complete list per update, owned by
/// the page's task, with a per-relay Reconnect.
@MainActor
struct RelayLivenessTests: WorkspaceTestSupport {
    private static let eu = "wss://relay.eu.whitenoise.chat"
    private static let us = "wss://relay.us.whitenoise.chat"

    private static func row(
        _ url: String, _ status: RelayStatusFfi, attempt: UInt64? = nil, error: String? = nil
    ) -> RelayLivenessFfi {
        RelayLivenessFfi(url: url, status: status, lastAttemptUnix: attempt, lastError: error)
    }

    @Test func theFirstSnapshotAndLaterListsReplaceTheConnections() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.relayLiveness = [Self.row(Self.eu, .connecting), Self.row(Self.us, .unknown)]
        let model = RelayLivenessViewModel(accountRef: "account", runtime: runtime)

        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await Self.waitUntil { model.connection(for: Self.eu) != nil }
        #expect(model.connection(for: Self.eu)?.state == .connecting)
        #expect(model.connection(for: Self.us)?.state == .unknown)

        // A complete replacement: the US relay is gone from this list, so it is gone here too.
        runtime.relayLivenessSubscriptions.last?.deliver([Self.row(Self.eu, .connected)])
        await Self.waitUntil { model.connection(for: Self.eu)?.state == .connected }
        #expect(model.connection(for: Self.us) == nil)
    }

    /// MDK canonicalizes relay URLs; a row must still find the relay the page lists.
    @Test func aCanonicalizedURLFindsItsRelay() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.relayLiveness = [Self.row("WSS://Relay.EU.WhiteNoise.chat/", .connected)]
        let model = RelayLivenessViewModel(accountRef: "account", runtime: runtime)

        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await Self.waitUntil { !model.connections.isEmpty }

        #expect(model.connection(for: Self.eu)?.state == .connected)
    }

    /// Leaving the page cancels its task, and that must wake MDK's receive — which keeps waiting
    /// after a Swift cancellation otherwise.
    @Test func cancellingThePageTaskCancelsTheSubscription() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.relayLiveness = [Self.row(Self.eu, .connected)]
        let model = RelayLivenessViewModel(accountRef: "account", runtime: runtime)

        let observing = Task { await model.observe() }
        await Self.waitUntil { model.connection(for: Self.eu) != nil }
        let subscription = try #require(runtime.relayLivenessSubscriptions.last)
        #expect(!subscription.isCancelled)

        observing.cancel()
        await observing.value

        #expect(subscription.isCancelled)
    }

    @Test func aFailedSubscribeLeavesTheRowsWithoutConnectionState() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.relayLivenessError = MarmotKitError.Runtime(details: "closed")
        let model = RelayLivenessViewModel(accountRef: "account", runtime: runtime)

        await model.observe()

        #expect(runtime.relayLivenessSubscribeCount == 1)
        #expect(model.connections.isEmpty)
    }

    @Test func reconnectShowsBusyThenTheRelaysNewState() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.reconnectRelayGate.isEnabled = true
        let model = RelayLivenessViewModel(accountRef: "account", runtime: runtime)

        let reconnecting = Task { await model.reconnect(Self.eu) }
        await runtime.reconnectRelayGate.waitUntilReached()
        #expect(model.isReconnecting(Self.eu))
        // A second press while the first is running does not dial again.
        await model.reconnect(Self.eu)
        #expect(runtime.reconnectedRelayURLs == [Self.eu])

        runtime.reconnectRelayGate.release()
        await reconnecting.value

        #expect(!model.isReconnecting(Self.eu))
        #expect(model.connection(for: Self.eu)?.state == .connected)
        #expect(model.reconnectError(for: Self.eu) == nil)
    }

    @Test func aFailedReconnectIsShownForThatRelayUntilItsRetried() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.reconnectRelayError = MarmotKitError.Runtime(details: "not configured")
        let model = RelayLivenessViewModel(accountRef: "account", runtime: runtime)

        await model.reconnect(Self.eu)
        #expect(model.reconnectError(for: Self.eu) == UserFacingError.message(for: MarmotKitError.Runtime(details: "")))
        #expect(model.reconnectError(for: Self.us) == nil)

        runtime.reconnectRelayError = nil
        await model.reconnect(Self.eu)
        #expect(model.reconnectError(for: Self.eu) == nil)
    }

    @Test func livenessMapsToTheAppsConnection() {
        let mapped = RelayConnection(liveness: Self.row(Self.eu, .offline, attempt: 1_800_000_000, error: " timeout "))
        #expect(mapped.state == .offline)
        #expect(mapped.lastAttempt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(mapped.lastError == "timeout")

        let blank = RelayConnection(liveness: Self.row(Self.eu, .unknown, error: "  "))
        #expect(blank.lastAttempt == nil)
        #expect(blank.lastError == nil)
    }

    /// The relay settings model owns the liveness model, so the page needs no new dependency.
    @Test func relaySettingsCarriesItsLivenessModel() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.relayLiveness = [Self.row(Self.eu, .connected)]
        let settings = SettingsViewModel(account: AccountItem.samples[0], runtime: runtime)

        let observing = Task { await settings.relays.liveness.observe() }
        defer { observing.cancel() }
        await Self.waitUntil { settings.relays.liveness.connection(for: Self.eu) != nil }

        #expect(settings.relays.liveness.connection(for: Self.eu)?.state == .connected)
    }
}
