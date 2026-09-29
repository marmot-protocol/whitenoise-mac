import Darwin
import Foundation
import MarmotKit

struct TelemetryBuildConfig: Equatable {
    static let defaultOtlpEndpoint = "https://otlp.ipf.dev/v1/metrics"
    static let defaultAuditOtlpEndpoint = "https://otlp.whitenoise.chat/v1/logs"
    /// MarmotKit binds its v5 delivery cursor to this identity, so it has to stay the same across
    /// token rotations and endpoint moves. Changing it makes the core treat the receiver as new.
    static let auditOtlpDestination = "whitenoise-audit-receiver"
    static let tenant = "whitenoise-mac"

    let otlpEndpoint: String
    let bearerToken: String?
    /// Write token for the audit receiver. Both delivery paths use it: v5 OTLP batches to
    /// `auditOtlpEndpoint`, and the v4 whole-file tracker that drains files left by MarmotKit
    /// 0.10.4. It is separate from `bearerToken` because metrics go to a different service.
    let auditLogBearerToken: String?
    let auditOtlpEndpoint: String
    let deploymentEnvironment: String
    let serviceVersion: String
    let osVersion: String
    let deviceModelIdentifier: String?
    let productAnalyticsEndpoint: String?
    let productAnalyticsAppKey: String?
    let productAnalyticsOperator: String
    let productAnalyticsRetentionDisclosure: String?

    init(
        otlpEndpoint: String,
        bearerToken: String?,
        auditLogBearerToken: String?,
        auditOtlpEndpoint: String = TelemetryBuildConfig.defaultAuditOtlpEndpoint,
        deploymentEnvironment: String,
        serviceVersion: String,
        osVersion: String,
        deviceModelIdentifier: String?,
        productAnalyticsEndpoint: String? = nil,
        productAnalyticsAppKey: String? = nil,
        productAnalyticsOperator: String = "white_noise",
        productAnalyticsRetentionDisclosure: String? = nil
    ) {
        self.otlpEndpoint = otlpEndpoint
        self.bearerToken = bearerToken
        self.auditLogBearerToken = auditLogBearerToken
        self.auditOtlpEndpoint = auditOtlpEndpoint
        self.deploymentEnvironment = deploymentEnvironment
        self.serviceVersion = serviceVersion
        self.osVersion = osVersion
        self.deviceModelIdentifier = deviceModelIdentifier
        self.productAnalyticsEndpoint = productAnalyticsEndpoint
        self.productAnalyticsAppKey = productAnalyticsAppKey
        self.productAnalyticsOperator = productAnalyticsOperator
        self.productAnalyticsRetentionDisclosure = productAnalyticsRetentionDisclosure
    }

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
            auditOtlpEndpoint: stringValue(
                for: "WhiteNoiseAuditOTLPEndpoint",
                in: info,
                environmentKeys: ["WN_AUDIT_OTLP_ENDPOINT"],
                environment: environment
            ) ?? defaultAuditOtlpEndpoint,
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
            deviceModelIdentifier: deviceModelIdentifier ?? Self.deviceModelIdentifier(),
            productAnalyticsEndpoint: stringValue(
                for: "WhiteNoiseProductAnalyticsEndpoint",
                in: info,
                environmentKeys: ["WN_PRODUCT_ANALYTICS_ENDPOINT"],
                environment: environment
            ),
            productAnalyticsAppKey: stringValue(
                for: "WhiteNoiseProductAnalyticsAppKey",
                in: info,
                environmentKeys: ["WN_PRODUCT_ANALYTICS_APP_KEY"],
                environment: environment
            ),
            productAnalyticsOperator: stringValue(
                for: "WhiteNoiseProductAnalyticsOperator",
                in: info,
                environmentKeys: ["WN_PRODUCT_ANALYTICS_OPERATOR"],
                environment: environment
            ) ?? "white_noise",
            productAnalyticsRetentionDisclosure: stringValue(
                for: "WhiteNoiseProductAnalyticsRetention",
                in: info,
                environmentKeys: ["WN_PRODUCT_ANALYTICS_RETENTION"],
                environment: environment
            )
        )
    }

    /// `serviceInstanceId` is left empty on purpose: MarmotKit substitutes its own consent-scoped
    /// diagnostic id whenever it builds an exporter. Asking the host to fetch it first
    /// (`telemetryInstallId()`) throws `ConsentRequired` until the user grants usage diagnostics,
    /// which surfaced as a raw error banner on every launch.
    func runtimeConfig() -> RelayTelemetryRuntimeConfigFfi {
        RelayTelemetryRuntimeConfigFfi(
            otlpEndpoint: otlpEndpoint,
            authorizationBearerToken: bearerToken,
            resource: RelayTelemetryResourceFfi(
                serviceVersion: serviceVersion,
                serviceInstanceId: "",
                deploymentEnvironment: deploymentEnvironment,
                tenant: Self.tenant,
                osType: "darwin",
                osVersion: osVersion,
                // The audit-log source may still use the local model label, but the
                // relay telemetry resource is exported to OTLP with MarmotKit's install
                // id. Do not include hw.model in the OTLP-exported resource.
                deviceModelIdentifier: nil
            )
        )
    }

    /// v5 audit delivery. MarmotKit 0.11 writes only v5 files while audit logging is on, and holds
    /// this config in memory only, so it is applied on every launch. Without a token the sender is
    /// disabled and recordings stay on this Mac. Recording itself is the user's separate setting:
    /// a destination never turns it on.
    func auditOtlpConfig() -> AuditOtlpConfigV5Ffi {
        guard let auditLogBearerToken else {
            return AuditOtlpConfigV5Ffi(
                enabled: false,
                destination: nil,
                endpoint: nil,
                authorizationBearerToken: nil,
                allowLoopbackDev: false
            )
        }
        return AuditOtlpConfigV5Ffi(
            enabled: true,
            destination: Self.auditOtlpDestination,
            endpoint: auditOtlpEndpoint,
            authorizationBearerToken: auditLogBearerToken,
            allowLoopbackDev: false
        )
    }

    /// The v4 tracker config. It is more than the v4 drain: in MarmotKit 0.11 its `source` is the
    /// only way the host gets data into v5 records. mdk copies `appVersion`, `platform` and
    /// `hardwareModel` into every v5 `source_context`, and neither the v5 OTLP envelope nor
    /// `AuditOtlpConfigV5Ffi` has a field of its own for them. Deleting this config therefore
    /// strips the version and flavor from delivered audit data, even after the v4 files drain.
    func auditTrackerConfig() -> AuditLogTrackerConfigV4Ffi {
        // Account identity now lives in the JSONL source_context emitted by the
        // Marmot core (Goggles contract), so the host no longer supplies an
        // account label here.
        AuditLogTrackerConfigV4Ffi(
            endpoint: nil,
            authorizationBearerToken: auditLogBearerToken,
            source: AuditLogUploadSourceV4Ffi(
                hardwareModel: deviceModelIdentifier,
                platform: "macos",
                appVersion: auditAppVersion
            )
        )
    }

    /// The app version as audit data sees it, with the flavor appended: `2026.9.22+16.production`,
    /// or `2026.9.22+production` when the build has no build number.
    ///
    /// Prod and staging share one audit token, so the receiver can tell them apart only from the
    /// records, and the v5 schema has no environment field (`producer.host_build` exists but mdk
    /// always writes it as null). The flavor therefore rides in `app_version` as semver build
    /// metadata. The schema limits the field to `[A-Za-z0-9._,+-]` and 128 characters; mdk only
    /// trims it, so anything else is dropped here rather than producing a record that fails
    /// validation. An over-long version is cut, never the flavor.
    var auditAppVersion: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._,+-")
        let version = serviceVersion.filter { allowed.contains($0) }
        let flavor = (version.contains("+") ? "." : "+") + deploymentEnvironment.filter { allowed.contains($0) }
        return String(version.prefix(max(0, 128 - flavor.count))) + flavor
    }

    func productAnalyticsRuntimeConfig() -> ProductAnalyticsRuntimeConfigFfi {
        ProductAnalyticsRuntimeConfigFfi(
            eventsEndpoint: productAnalyticsEndpoint,
            appKey: productAnalyticsAppKey,
            metadata: ProductAnalyticsMetadataFfi(
                appVersion: serviceVersion,
                osFamily: "macos",
                osMajorVersion: osVersion.split(separator: ".").first.map(String.init) ?? "unknown",
                deviceClass: "desktop",
                hostSurface: "native",
                environment: deploymentEnvironment,
                isDebug: Self.isDebugBuild
            ),
            registry: ProductAnalyticsTimingStage.registry,
            allowLoopback: false,
            operator: productAnalyticsOperator
        )
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
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

/// App-defined timings accepted by MarmotKit's consent-gated product event pipeline.
/// The names match the iOS registry where the same screen projection is measured.
enum ProductAnalyticsTimingStage: String, CaseIterable {
    case timelineWindow = "app_timeline_window"
    case timelineTail = "app_timeline_tail"
    case timelineDelta = "app_timeline_delta"
    case timelineRebuild = "app_timeline_rebuild"
    case timelineProfiles = "app_timeline_profiles"
    case outgoingProjection = "app_outgoing_projection"
    case outgoingConfirmation = "app_outgoing_confirmation"
    case sendDraftReady = "app_send_draft_ready"
    case sendSubmission = "app_send_submission"
    case sendProjection = "app_send_projection"
    case markdownRebuild = "app_markdown_rebuild"
    case mediaRebuild = "app_media_rebuild"
    case inboxSnapshot = "app_inbox_snapshot"
    case inboxBatch = "app_inbox_batch"
    case inboxRefresh = "app_inbox_refresh"
    case inboxPublish = "app_inbox_publish"
    case composerMarkdown = "app_composer_markdown"

    static var registry: [ProductEventSchemaFfi] {
        allCases.map { stage in
            ProductEventSchemaFfi(
                name: stage.rawValue,
                mode: .aggregate,
                properties: [
                    ProductPropertySchemaFfi(name: "elapsed", kind: .durationBucket, choices: []),
                    ProductPropertySchemaFfi(
                        name: "outcome",
                        kind: .enum,
                        choices: ["success", "failure"]
                    ),
                ]
            )
        }
    }
}
