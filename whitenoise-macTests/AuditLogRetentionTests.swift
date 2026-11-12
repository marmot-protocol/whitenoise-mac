import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// MarmotKit 0.16.0 audit log retention in Privacy & Security.
@MainActor
struct AuditLogRetentionTests: WorkspaceTestSupport {
    @Test func retentionLoadsMDKsDefaultsAndSavesAChoice() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)

        await model.load()
        #expect(model.retention?.maxAgeDays == 30)
        #expect(model.retention?.maxBytesPerAccount == 256 << 20)

        await model.setMaxAgeDays(7)?.value
        #expect(runtime.setAuditLogRetentionCalls.last?.maxAgeDays == 7)
        #expect(runtime.setAuditLogRetentionCalls.last?.maxBytesPerAccount == 256 << 20)
        #expect(model.retention?.maxAgeDays == 7)

        // Choosing the value already stored writes nothing.
        await model.setMaxAgeDays(7)?.value
        #expect(runtime.setAuditLogRetentionCalls.count == 1)
    }

    /// MDK clamps and returns what it stored; the model shows that, not what was asked for.
    @Test func retentionShowsTheValueMDKStored() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)
        await model.load()

        await model.setMaxBytesPerAccount(1 << 20)?.value

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
        await model.setMaxAgeDays(7)?.value
        runtime.auditLogRetentionGate.release()
        await reload.value

        #expect(model.retention == runtime.storedAuditLogRetention)
    }

    /// A picker change claims the model before it returns, so a reload that runs next — the page
    /// reappearing — backs off instead of reading the old policy over the save.
    @Test func aRetentionChangeClaimsTheModelBeforeAnyReload() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)
        await model.load()

        let save = model.setMaxAgeDays(7)
        #expect(model.isBusy)
        await model.load()
        await save?.value

        #expect(runtime.storedAuditLogRetention.maxAgeDays == 7)
        #expect(model.retention?.maxAgeDays == 7)
    }

    /// The day count follows the app's language, plural rules included.
    @Test func theDayCountUsesEachLanguagesPluralForms() {
        #expect(L10n.plural("%llu days", UInt64(1), locale: Locale(identifier: "en")) == "1 day")
        #expect(L10n.plural("%llu days", UInt64(14), locale: Locale(identifier: "en")) == "14 days")
        // The presets 1, 3 and 7 are three different Russian plural forms.
        let russian = Locale(identifier: "ru")
        #expect(L10n.plural("%llu days", UInt64(1), locale: russian) == "1 день")
        #expect(L10n.plural("%llu days", UInt64(3), locale: russian) == "3 дня")
        #expect(L10n.plural("%llu days", UInt64(7), locale: russian) == "7 дней")
    }

    /// The limits are whole mebibytes and read that way.
    @Test func sizeChoicesReadInBinaryUnits() {
        #expect(DiagnosticLogRetentionSection.sizeLabel(256 << 20).hasPrefix("256"))
        #expect(DiagnosticLogRetentionSection.sizeLabel(1 << 30).hasPrefix("1"))
        #expect(!DiagnosticLogRetentionSection.sizeLabel(1 << 30).hasPrefix("1.07"))
    }

    @Test func aRetentionFailureIsShownAndKeepsTheLastValue() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AuditLogRetentionViewModel(runtime: runtime)
        await model.load()

        runtime.auditLogRetentionError = MarmotKitError.Io(details: "disk")
        await model.setMaxAgeDays(3)?.value

        #expect(model.retention?.maxAgeDays == 30)
        #expect(model.error == UserFacingError.message(for: MarmotKitError.Io(details: "")))
    }

    /// While the page reloads, the retention pickers wait: a change cannot overlap the reload's
    /// read, so the older policy cannot be put back on screen over it.
    @Test func retentionWaitsForThePageReload() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = DiagnosticsSettingsViewModel(runtime: runtime)
        await model.load()
        #expect(model.canChangeRetention)

        runtime.auditLogFilesGateEnabled = true
        let reload = Task { await model.load() }
        await Self.waitUntil { runtime.didReachAuditLogFilesGate }
        #expect(!model.canChangeRetention)

        runtime.releaseAuditLogFilesGate()
        await reload.value
        #expect(model.canChangeRetention)
    }

    /// Retention is its own read: the page's other settings failing to load must not take the
    /// pickers away.
    @Test func aFailedSettingsReadStillReadsRetention() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.usageDiagnosticsSettingsError = MarmotKitError.StorageBusy(details: "")
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(model.error != nil)
        #expect(model.retention.retention?.maxAgeDays == 30)
        #expect(model.showsRetention)
    }

    /// MDK enforces retention whether or not logging is on right now, so the pickers do not hide
    /// behind the logging switch or the file list: logging off with nothing listed still shows them.
    @Test func retentionShowsWheneverItLoaded() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = DiagnosticsSettingsViewModel(runtime: runtime)
        #expect(!model.showsRetention)

        await model.load()

        #expect(model.auditSettings?.enabled == false)
        #expect(model.auditLogFiles.isEmpty)
        #expect(model.showsRetention)
    }
}
