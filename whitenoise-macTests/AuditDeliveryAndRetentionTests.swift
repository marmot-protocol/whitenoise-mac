import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// MarmotKit 0.16.0 audit log retention and v5 delivery status in Settings.
@MainActor
struct AuditDeliveryAndRetentionTests: WorkspaceTestSupport {
    private static func status(
        _ account: String = "a",
        configured: Bool = true,
        lastSuccessAtMs: UInt64? = nil,
        failure: AuditDeliveryFailureV5Ffi? = nil,
        consecutiveFailures: UInt64 = 0,
        paused: Bool = false,
        undeliveredBytes: UInt64? = nil
    ) -> AuditDeliveryStatusV5Ffi {
        AuditDeliveryStatusV5Ffi(
            accountRef: account,
            destinationConfigured: configured,
            lastSuccessAtMs: lastSuccessAtMs,
            lastFailure: failure,
            consecutiveFailures: consecutiveFailures,
            rejectedBatches: 0,
            paused: paused,
            backlog: undeliveredBytes.map {
                AuditDeliveryBacklogV5Ffi(
                    undeliveredBytes: $0, undeliveredSegments: 1, gaps: 0, oldestUndeliveredAtMs: nil,
                    observedAtMs: 0)
            }
        )
    }

    // MARK: Retention

    @Test func retentionLoadsMDKsDefaultsAndSavesAChoice() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)

        await model.load()
        #expect(model.retention?.maxAgeDays == 30)
        #expect(model.retention?.maxBytesPerAccount == 256 << 20)

        await model.setMaxAgeDays(7)
        #expect(runtime.setAuditLogRetentionCalls.last?.maxAgeDays == 7)
        #expect(runtime.setAuditLogRetentionCalls.last?.maxBytesPerAccount == 256 << 20)
        #expect(model.retention?.maxAgeDays == 7)

        // Choosing the value already stored writes nothing.
        await model.setMaxAgeDays(7)
        #expect(runtime.setAuditLogRetentionCalls.count == 1)
    }

    /// MDK clamps and returns what it stored; the model shows that, not what was asked for.
    @Test func retentionShowsTheValueMDKStored() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)
        await model.load()

        await model.setMaxBytesPerAccount(1 << 20)

        #expect(model.retention?.maxBytesPerAccount == 16 << 20)
        // A stored value outside the presets is offered, so the picker still has a selection.
        #expect(model.sizeChoices.contains(16 << 20))
        #expect(model.sizeChoices == model.sizeChoices.sorted())
    }

    /// Reopening the page reloads retention. A save made while that read is in flight must not be
    /// undone on screen by the older value it returns, or the next change to the other picker
    /// would write the stale field back.
    @Test func aReloadInFlightCannotHideASave() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)
        await model.load()

        runtime.auditLogRetentionGate.isEnabled = true
        let reload = Task { await model.load() }
        await Self.waitUntil { runtime.auditLogRetentionGate.didReach }
        await model.setMaxAgeDays(7)
        runtime.auditLogRetentionGate.release()
        await reload.value

        #expect(model.retention == runtime.storedAuditLogRetention)
    }

    /// The day count follows the app's language, plural rules included.
    @Test func theDayCountUsesEachLanguagesPluralForms() {
        #expect(L10n.plural("%lld days", Int64(1), locale: Locale(identifier: "en")) == "1 day")
        #expect(L10n.plural("%lld days", Int64(14), locale: Locale(identifier: "en")) == "14 days")
        let russian = Locale(identifier: "ru")
        #expect(L10n.plural("%lld days", Int64(1), locale: russian) == "1 день")
        #expect(L10n.plural("%lld days", Int64(3), locale: russian) == "3 дня")
        #expect(L10n.plural("%lld days", Int64(7), locale: russian) == "7 дней")
    }

    @Test func aRetentionFailureIsShownAndKeepsTheLastValue() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)
        await model.load()

        runtime.auditLogRetentionError = MarmotKitError.Io(details: "disk")
        await model.setMaxAgeDays(3)

        #expect(model.retention?.maxAgeDays == 30)
        #expect(model.error == UserFacingError.message(for: MarmotKitError.Io(details: "")))
    }

    // MARK: Delivery summary

    @Test func noDestinationMeansNoSummary() {
        #expect(AuditDeliverySummary(statuses: []) == nil)
        #expect(AuditDeliverySummary(statuses: [Self.status(configured: false, paused: true)]) == nil)
    }

    @Test func aPausedAccountWinsAndNamesTheRefusal() throws {
        let summary = try #require(
            AuditDeliverySummary(statuses: [
                Self.status("a", lastSuccessAtMs: 2_000),
                Self.status(
                    "b",
                    failure: AuditDeliveryFailureV5Ffi(kind: .receiverBlocked, httpStatus: 401, atMs: 3_000),
                    consecutiveFailures: 2,
                    paused: true
                ),
            ]))

        #expect(summary.state == .paused(httpStatus: 401))
        #expect(summary.message.contains("401"))
        #expect(summary.lastSuccess == Date(unixMilliseconds: 2_000))
    }

    @Test func failingAccountsRetryAndOthersReportTheirLastSend() throws {
        let retrying = try #require(
            AuditDeliverySummary(statuses: [Self.status(lastSuccessAtMs: 1_000, consecutiveFailures: 1)]))
        #expect(retrying.state == .retrying)

        let upToDate = try #require(
            AuditDeliverySummary(statuses: [
                Self.status("a", lastSuccessAtMs: 1_000, undeliveredBytes: 10),
                Self.status("b", lastSuccessAtMs: 5_000, undeliveredBytes: 32),
            ]))
        #expect(upToDate.state == .upToDate)
        #expect(upToDate.lastSuccess == Date(unixMilliseconds: 5_000))
        #expect(upToDate.undeliveredBytes == 42)

        let never = try #require(AuditDeliverySummary(statuses: [Self.status()]))
        #expect(never.state == .neverSent)
        #expect(never.message != upToDate.message)
    }

    @Test func everyFailureKindHasALabel() {
        let kinds: [AuditDeliveryFailureKindV5Ffi] = [
            .stateOverLimit, .tooManyOpenFiles, .localIo, .localBlocked, .receiverBlocked, .receiverRejected,
            .receiverRetryable, .noResponse, .internal,
        ]
        #expect(Set(kinds.map(AuditDeliveryFailurePresentation.label)).count == kinds.count)
    }

    // MARK: Wiring

    @Test func loadingDiagnosticsLoadsRetentionAndDelivery() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.auditDeliveryStatuses = [Self.status(lastSuccessAtMs: 1_000)]
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(model.retention.retention?.maxAgeDays == 30)
        #expect(model.delivery.summary?.state == .upToDate)
    }

    /// Upload Now lifts a paused account, so the status line must be re-read after it.
    @Test func uploadingRereadsTheDeliveryStatus() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.auditDeliveryStatuses = [Self.status(paused: true)]
        let model = DiagnosticsSettingsViewModel(runtime: runtime)
        await model.load()
        #expect(model.delivery.summary?.state == .paused(httpStatus: nil))

        runtime.auditDeliveryStatuses = [Self.status(lastSuccessAtMs: 9_000)]
        await model.uploadAuditLogs()

        #expect(runtime.didPostAuditLogTrackerUpdate)
        #expect(model.delivery.summary?.state == .upToDate)
    }

    @Test func aDeliveryReadFailureIsShownOnItsSection() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.auditDeliveryStatusError = MarmotKitError.StorageBusy(details: "")
        let model = AuditDeliveryStatusViewModel(runtime: runtime)

        await model.load()

        #expect(model.statuses.isEmpty)
        #expect(model.error == UserFacingError.message(for: MarmotKitError.StorageBusy(details: "")))
    }
}
