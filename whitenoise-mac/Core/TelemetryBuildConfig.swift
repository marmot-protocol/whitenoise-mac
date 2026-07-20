import Darwin
import Foundation
import MarmotKit

enum TelemetrySettingsActionError: LocalizedError {
    case telemetryNotConfigured
    case auditLogNotConfigured

    var errorDescription: String? {
        switch self {
        case .telemetryNotConfigured:
            L10n.string("Telemetry credentials are not configured for this build.")
        case .auditLogNotConfigured:
            L10n.string("Audit log credentials are not configured for this build.")
        }
    }
}

struct TelemetryBuildConfig: Equatable {
    static let defaultOtlpEndpoint = "https://otlp.ipf.dev/v1/metrics"
    static let tenant = "whitenoise-mac"

    let otlpEndpoint: String
    let bearerToken: String?
    let auditLogBearerToken: String?
    let deploymentEnvironment: String
    let serviceVersion: String
    let osVersion: String
    let deviceModelIdentifier: String?

    var telemetryCredentialsAvailable: Bool {
        bearerToken != nil
    }

    var auditLogCredentialsAvailable: Bool {
        auditLogBearerToken != nil
    }

    static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        processInfo: ProcessInfo = .processInfo,
        environment: [String: String]? = nil,
        osVersion: String = TelemetryBuildConfig.marketingOSVersion(),
        deviceModelIdentifier: String? = nil
    ) -> TelemetryBuildConfig {
        let info = infoDictionary ?? [:]
        let environment = environment ?? processInfo.environment

        return TelemetryBuildConfig(
            otlpEndpoint: stringValue(
                for: "WhiteNoiseTelemetryOTLPEndpoint",
                in: info,
                environmentKeys: ["WN_OTLP_ENDPOINT"],
                environment: environment
            ) ?? defaultOtlpEndpoint,
            bearerToken: stringValue(
                for: "WhiteNoiseTelemetryBearerToken",
                in: info,
                environmentKeys: [
                    "WN_OTLP_BEARER_TOKEN",
                    "OTLP_TOKEN_WN_MAC",
                ],
                environment: environment
            ),
            auditLogBearerToken: stringValue(
                for: "WhiteNoiseAuditLogBearerToken",
                in: info,
                environmentKeys: [
                    "WN_AUDIT_LOG_BEARER_TOKEN",
                    "AUDIT_LOG_TOKEN_WN_MAC",
                ],
                environment: environment
            ),
            deploymentEnvironment: deploymentEnvironment(
                from: stringValue(
                    for: "WhiteNoiseTelemetryEnvironment",
                    in: info,
                    environmentKeys: ["WN_TELEMETRY_ENVIRONMENT"],
                    environment: environment
                )
            ),
            serviceVersion: serviceVersion(from: info),
            osVersion: osVersion,
            deviceModelIdentifier: deviceModelIdentifier ?? Self.deviceModelIdentifier()
        )
    }

    func runtimeConfig(installId: String) -> RelayTelemetryRuntimeConfigFfi {
        RelayTelemetryRuntimeConfigFfi(
            otlpEndpoint: otlpEndpoint,
            authorizationBearerToken: bearerToken,
            resource: RelayTelemetryResourceFfi(
                serviceVersion: serviceVersion,
                serviceInstanceId: installId,
                deploymentEnvironment: deploymentEnvironment,
                tenant: Self.tenant,
                osType: "darwin",
                osVersion: osVersion,
                // The audit-log source may still use the local model label, but the
                // relay telemetry resource is exported to OTLP with a stable install
                // id. Do not include hw.model in the OTLP-exported resource.
                deviceModelIdentifier: nil
            )
        )
    }

    func auditTrackerConfig() -> AuditLogTrackerConfigFfi {
        // Account identity now lives in the JSONL source_context emitted by the
        // Marmot core (Goggles contract), so the host no longer supplies an
        // account label here.
        AuditLogTrackerConfigFfi(
            endpoint: nil,
            authorizationBearerToken: auditLogBearerToken,
            source: AuditLogUploadSourceFfi(
                deviceLabel: deviceModelIdentifier,
                platform: "macOS",
                appVersion: serviceVersion
            )
        )
    }

    nonisolated private static func stringValue(
        for key: String,
        in info: [String: Any],
        environmentKeys: [String] = [],
        environment: [String: String] = [:]
    ) -> String? {
        if let raw = info[key] as? String,
            let value = resolvedStringValue(raw)
        {
            return value
        }
        return environmentKeys.lazy
            .compactMap { environment[$0] }
            .compactMap(resolvedStringValue)
            .first
    }

    nonisolated private static func resolvedStringValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUnresolvedBuildSetting(trimmed) else { return nil }
        return trimmed
    }

    nonisolated private static func deploymentEnvironment(from raw: String?) -> String {
        guard let environment = raw?.lowercased() else { return "development" }
        switch environment {
        case "production", "staging", "development", "test":
            return environment
        default:
            return "unknown"
        }
    }

    nonisolated private static func serviceVersion(from info: [String: Any]) -> String {
        let version = stringValue(for: "CFBundleShortVersionString", in: info) ?? "unknown"
        guard let build = stringValue(for: "CFBundleVersion", in: info) else {
            return version
        }
        return "\(version)+\(build)"
    }

    nonisolated private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")")
    }

    /// Marketing-only OS version formatted as "major.minor.patch".
    ///
    /// `ProcessInfo.operatingSystemVersionString` embeds the build number (for
    /// example "Version 15.5 (Build 24F74)"), a higher-entropy fingerprinting
    /// signal. This resource is exported to a remote OTLP endpoint, so emit only
    /// the marketing version drawn from `operatingSystemVersion`.
    nonisolated static func marketingOSVersion(
        _ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    nonisolated static func deviceModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return nil
        }
        let identifier = String(cString: value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }
}
