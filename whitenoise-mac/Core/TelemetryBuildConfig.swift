import Darwin
import Foundation
import MarmotKit

enum TelemetrySettingsActionError: LocalizedError {
    case telemetryNotConfigured
    case auditLogNotConfigured

    var errorDescription: String? {
        switch self {
        case .telemetryNotConfigured:
            L10n.string("Telemetry credentials are not available in this launch environment.")
        case .auditLogNotConfigured:
            L10n.string("Audit log credentials are not available in this launch environment.")
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
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        deviceModelIdentifier: String? = nil
    ) -> TelemetryBuildConfig {
        let info = infoDictionary ?? [:]
        let environment = environment ?? processInfo.environment

        return TelemetryBuildConfig(
            otlpEndpoint: stringValue(
                for: "DarkmatterTelemetryOTLPEndpoint",
                in: info,
                environmentKeys: ["DARKMATTER_OTLP_ENDPOINT"],
                environment: environment
            ) ?? defaultOtlpEndpoint,
            bearerToken: environmentStringValue(
                for: [
                    "DARKMATTER_OTLP_BEARER_TOKEN",
                    "OTLP_TOKEN_DARKMATTER_MAC"
                ],
                in: environment
            ),
            auditLogBearerToken: environmentStringValue(
                for: [
                    "DARKMATTER_AUDIT_LOG_BEARER_TOKEN",
                    "AUDIT_LOG_TOKEN_DARKMATTER_MAC"
                ],
                in: environment
            ),
            deploymentEnvironment: deploymentEnvironment(
                from: stringValue(
                    for: "DarkmatterTelemetryEnvironment",
                    in: info,
                    environmentKeys: ["DARKMATTER_TELEMETRY_ENVIRONMENT"],
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
                deviceModelIdentifier: deviceModelIdentifier
            )
        )
    }

    func auditTrackerConfig(accountLabel: String?) -> AuditLogTrackerConfigFfi {
        AuditLogTrackerConfigFfi(
            endpoint: nil,
            authorizationBearerToken: auditLogBearerToken,
            source: AuditLogUploadSourceFfi(
                accountLabel: accountLabel,
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
           let value = resolvedStringValue(raw) {
            return value
        }
        return environmentKeys.lazy
            .compactMap { environment[$0] }
            .compactMap(resolvedStringValue)
            .first
    }

    nonisolated private static func environmentStringValue(
        for keys: [String],
        in environment: [String: String]
    ) -> String? {
        keys.lazy
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
            return "development"
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
