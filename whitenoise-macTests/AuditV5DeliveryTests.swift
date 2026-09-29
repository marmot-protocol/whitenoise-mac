import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// MarmotKit 0.11 writes only v5 audit files, so delivery goes through the v5 OTLP destination,
/// and the manual upload reports the v5 outcome rather than the leftover v4 file list.
@MainActor
struct AuditV5DeliveryTests {
    @Test func theAuditDestinationIsDisabledWithoutAToken() {
        let config = telemetryBuildConfig(auditToken: nil).auditOtlpConfig()

        #expect(config.enabled == false)
        #expect(config.destination == nil)
        #expect(config.endpoint == nil)
        #expect(config.authorizationBearerToken == nil)
        #expect(config.allowLoopbackDev == false)
    }

    @Test func theAuditEndpointComesFromTheBuildSettingAndKeepsTheStableDestination() {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "WhiteNoiseAuditLogBearerToken": "audit-token",
                "WhiteNoiseAuditOTLPEndpoint": "https://audit.example/v1/logs",
            ],
            environment: [:],
            osVersion: "26.0.0",
            deviceModelIdentifier: "Mac15,3"
        )

        let v5 = config.auditOtlpConfig()
        #expect(v5.endpoint == "https://audit.example/v1/logs")
        #expect(v5.destination == "whitenoise-audit-receiver")
        #expect(v5.authorizationBearerToken == "audit-token")
    }

    @Test func anUnresolvedAuditEndpointFallsBackToTheDefaultReceiver() {
        let config = TelemetryBuildConfig.current(
            infoDictionary: ["WhiteNoiseAuditOTLPEndpoint": "$(WN_AUDIT_OTLP_ENDPOINT)"],
            environment: [:],
            osVersion: "26.0.0",
            deviceModelIdentifier: nil
        )

        #expect(config.auditOtlpEndpoint == "https://otlp.whitenoise.chat/v1/logs")
    }

    /// One audit token serves every flavor, so the flavor has to travel inside the records. mdk
    /// copies the v4 source's `appVersion` into each v5 `source_context`, which is the only
    /// host-supplied field the v5 schema has room for.
    @Test func theAuditAppVersionCarriesTheFlavor() {
        let production = telemetryBuildConfig(environment: "production", serviceVersion: "2026.9.22+16")
        let development = telemetryBuildConfig(environment: "development", serviceVersion: "2026.9.22+16")

        #expect(production.auditTrackerConfig().source.appVersion == "2026.9.22+16.production")
        #expect(production.auditTrackerConfig().source.platform == "macos")
        #expect(development.auditTrackerConfig().source.appVersion == "2026.9.22+16.development")
    }

    @Test func aVersionWithoutABuildNumberStartsTheBuildMetadataWithTheFlavor() {
        let config = telemetryBuildConfig(environment: "production", serviceVersion: "2026.9.22")

        #expect(config.auditAppVersion == "2026.9.22+production")
    }

    @Test func theAuditAppVersionStaysInsideTheV5SchemaCharacterSet() {
        let config = telemetryBuildConfig(
            environment: "production",
            serviceVersion: "2026.9 (beta)/" + String(repeating: "9", count: 200)
        )
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._,+-")

        #expect(config.auditAppVersion.count <= 128)
        #expect(config.auditAppVersion.allSatisfy { allowed.contains($0) })
        #expect(config.auditAppVersion.hasPrefix("2026.9beta"))
        #expect(config.auditAppVersion.hasSuffix("+production"))
    }

    @Test func noDestinationIsNotReportedAsASuccessfulUpload() {
        let message = DiagnosticsSettingsViewModel.auditUploadStatusMessage(
            Self.result(v4SkippedReason: "audit log files missing", v5: nil)
        )

        #expect(message == L10n.string("No audit destination is configured, so audit logs stay on this Mac."))
    }

    @Test func acceptedBatchesAreReportedAsSent() {
        let message = DiagnosticsSettingsViewModel.auditUploadStatusMessage(
            Self.result(v4SkippedReason: "audit log files missing", v5: Self.v5(accepted: 3, idle: 1))
        )

        // The v4 skip reason is routine once 0.10.4's files have drained; it must not show.
        #expect(message == L10n.string("Audit logs sent."))
    }

    @Test func anIdlePassSaysTheLogsAreUpToDate() {
        let message = DiagnosticsSettingsViewModel.auditUploadStatusMessage(
            Self.result(v5: Self.v5(idle: 2))
        )

        #expect(message == L10n.string("Audit logs are up to date."))
    }

    @Test func blockedAndPendingAccountsAreBothReported() {
        let message = DiagnosticsSettingsViewModel.auditUploadStatusMessage(
            Self.result(v5: Self.v5(pending: 1, blocked: 1))
        )

        #expect(message.contains(L10n.string("Some accounts could not send their audit logs.")))
        #expect(message.contains(L10n.string("Some audit logs are still waiting to be sent. Try again later.")))
        #expect(!message.contains(L10n.string("Audit logs are up to date.")))
    }

    @Test func aSkippedV5PassShowsItsReason() {
        let message = DiagnosticsSettingsViewModel.auditUploadStatusMessage(
            Self.result(v5: Self.v5(skippedReason: "v5 delivery pass failed"))
        )

        #expect(message == String(format: L10n.string("Audit upload skipped: %@"), "v5 delivery pass failed"))
    }

    @Test func leftoverV4FilesThatDrainAreReportedAlongsideV5() {
        let message = DiagnosticsSettingsViewModel.auditUploadStatusMessage(
            Self.result(
                v4Uploaded: [AuditLogUploadResultFfi(path: "/tmp/audit-v4.jsonl", status: 200, bytesSent: 2048)],
                v5: Self.v5(idle: 1)
            )
        )

        let drained = String(
            format: L10n.string("Uploaded %d audit log files (%@)."),
            1,
            ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file)
        )
        // v5 had nothing new, so the drain line stands alone rather than claiming "up to date".
        #expect(message == drained)
    }

    @Test func disabledRecordingReportsTheSkipReason() {
        let message = DiagnosticsSettingsViewModel.auditUploadStatusMessage(
            Self.result(
                enabled: false,
                v4SkippedReason: "audit logging disabled",
                v5: Self.v5(skippedReason: "audit logging disabled")
            )
        )

        #expect(message == String(format: L10n.string("Audit upload skipped: %@"), "audit logging disabled"))
    }

    @Test func theManualUploadRunsTheV5Pass() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.nextAuditLogTrackerUpdate = Self.result(v5: Self.v5(accepted: 1))
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.uploadAuditLogs()

        #expect(runtime.didPostAuditLogTrackerUpdate)
        #expect(model.auditUploadStatus == L10n.string("Audit logs sent."))
        #expect(model.error == nil)
    }

    private static func result(
        enabled: Bool = true,
        v4Uploaded: [AuditLogUploadResultFfi] = [],
        v4SkippedReason: String? = nil,
        v5: AuditOtlpTrackerResultV5Ffi?
    ) -> AuditLogTrackerUpdateResultV5Ffi {
        AuditLogTrackerUpdateResultV5Ffi(
            enabled: enabled,
            v4Uploaded: v4Uploaded,
            v4SkippedReason: v4SkippedReason,
            v5: v5
        )
    }

    private static func v5(
        accepted: UInt64 = 0,
        pending: UInt64 = 0,
        blocked: UInt64 = 0,
        idle: UInt64 = 0,
        skippedReason: String? = nil
    ) -> AuditOtlpTrackerResultV5Ffi {
        AuditOtlpTrackerResultV5Ffi(
            acceptedBatches: accepted,
            pendingAccounts: pending,
            blockedAccounts: blocked,
            idleAccounts: idle,
            skippedReason: skippedReason
        )
    }
}
