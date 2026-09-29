import Foundation
import MarmotKit
import Observation

enum DiagnosticsSettingsError: Equatable {
    case unavailable(String)

    var message: String {
        switch self {
        case .unavailable(let message): message
        }
    }
}

@MainActor
@Observable
final class DiagnosticsSettingsViewModel {
    private(set) var settings: UsageDiagnosticsSettingsFfi?
    private(set) var status: UsageDiagnosticsStatusFfi?
    private(set) var auditSettings: AuditLogSettingsFfi?
    private(set) var auditLogFiles: [AuditLogFileFfi] = []
    private(set) var isLoading = false
    private(set) var isSavingUsage = false
    private(set) var isSavingAudit = false
    private(set) var isLoadingAuditLogs = false
    private(set) var isDeletingAuditLogs = false
    private(set) var isUploadingAuditLogs = false
    private(set) var auditUploadStatus: String?
    private(set) var error: DiagnosticsSettingsError?

    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let productAnalytics: ProductAnalyticsRecorder?

    init(
        runtime: (any MarmotRuntime)?,
        productAnalytics: ProductAnalyticsRecorder? = nil
    ) {
        self.runtime = runtime
        self.productAnalytics = productAnalytics
    }

    func load() async {
        guard let runtime, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await FFIExecutor.run { [runtime] in
                (
                    try runtime.usageDiagnosticsSettings(),
                    try runtime.usageDiagnosticsStatus(),
                    try runtime.auditLogSettings()
                )
            }
            guard !Task.isCancelled else { return }
            settings = loaded.0
            status = loaded.1
            auditSettings = loaded.2
            configureProductAnalytics(for: loaded.0)
            error = nil
            await loadAuditLogs()
        } catch is CancellationError {
            return
        } catch {
            productAnalytics?.deactivate()
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard let runtime, !isSavingUsage else { return }
        isSavingUsage = true
        defer { isSavingUsage = false }
        do {
            settings = try await FFIExecutor.run { [runtime] in
                try runtime.setUsageDiagnosticsConsent(enabled: enabled)
            }
            status = try await FFIExecutor.run { [runtime] in try runtime.usageDiagnosticsStatus() }
            if let settings {
                configureProductAnalytics(for: settings)
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            productAnalytics?.deactivate()
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func setAuditEnabled(_ enabled: Bool) async {
        guard let runtime, !isSavingAudit else { return }
        isSavingAudit = true
        defer { isSavingAudit = false }
        do {
            auditSettings = try await runtime.setAuditLogSettings(
                settings: AuditLogSettingsFfi(enabled: enabled)
            )
            error = nil
            await loadAuditLogs()
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func refresh() async {
        await load()
    }

    func flush() async {
        guard let runtime else { return }
        do {
            try await runtime.flushProductAnalytics()
            guard !Task.isCancelled else { return }
            status = try await FFIExecutor.run { [runtime] in try runtime.usageDiagnosticsStatus() }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func loadAuditLogs() async {
        guard let runtime, !isLoadingAuditLogs else { return }
        isLoadingAuditLogs = true
        defer { isLoadingAuditLogs = false }
        do {
            let files = try await FFIExecutor.run { [runtime] in try runtime.auditLogFiles() }
            try Task.checkCancellation()
            auditLogFiles = files
            error = nil
        } catch is CancellationError {
            return
        } catch {
            auditLogFiles = []
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func deleteAllAuditLogs() async {
        guard let runtime, !isDeletingAuditLogs else { return }
        isDeletingAuditLogs = true
        auditUploadStatus = nil
        defer { isDeletingAuditLogs = false }
        do {
            for file in auditLogFiles {
                _ = try await runtime.deleteAuditLogFile(path: file.path)
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
        await loadAuditLogs()
    }

    func uploadAuditLogs() async {
        guard let runtime, !isUploadingAuditLogs else { return }
        isUploadingAuditLogs = true
        auditUploadStatus = nil
        defer { isUploadingAuditLogs = false }
        do {
            let result = try await runtime.postAuditLogTrackerUpdateV5()
            auditUploadStatus = Self.auditUploadStatusMessage(result)
            error = nil
            await loadAuditLogs()
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func diagnosticLogExport(path: String? = nil) async throws -> DiagnosticLogSnapshot {
        guard let runtime else { throw DiagnosticLogExport.ExportError.noLogs }
        let files = try await FFIExecutor.run { [runtime] in try runtime.auditLogFiles() }
        let file = try DiagnosticLogExport.fileForExport(in: files, path: path)
        for attempt in 0..<3 {
            do {
                return try await Task.detached(priority: .userInitiated) {
                    try DiagnosticLogExport.snapshot(file: file)
                }.value
            } catch DiagnosticLogExport.ExportError.fileChangedDuringRead where attempt < 2 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw DiagnosticLogExport.ExportError.fileChangedDuringRead
    }

    static func preview() -> DiagnosticsSettingsViewModel {
        DiagnosticsSettingsViewModel(runtime: nil)
    }

    private func configureProductAnalytics(for settings: UsageDiagnosticsSettingsFfi) {
        guard settings.decision == .granted, let runtime, let productAnalytics else {
            productAnalytics?.deactivate()
            return
        }
        productAnalytics.activate(
            event: { event in
                _ = try? runtime.recordProductEvent(event: event.ffi)
            },
            timing: { stage, durationMs, outcome in
                _ = try runtime.recordHostTiming(
                    name: stage.rawValue,
                    durationMs: durationMs,
                    outcome: outcome
                )
            }
        )
    }

    /// One pass reports two paths. v5 carries everything MarmotKit 0.11 records; the v4 upload
    /// list only drains files left by 0.10.4, so an empty one says nothing about success. The v4
    /// skip reason is not shown while v5 is configured: once those files are gone it reads
    /// "audit log files missing" on every pass.
    static func auditUploadStatusMessage(_ result: AuditLogTrackerUpdateResultV5Ffi) -> String {
        guard result.enabled else {
            guard let reason = nonEmpty(result.v5?.skippedReason) ?? nonEmpty(result.v4SkippedReason) else {
                return L10n.string("No audit logs uploaded.")
            }
            return String(format: L10n.string("Audit upload skipped: %@"), reason)
        }

        var lines: [String] = []
        if !result.v4Uploaded.isEmpty {
            let totalBytes = result.v4Uploaded.reduce(UInt64(0)) { $0 + $1.bytesSent }
            lines.append(
                String(
                    format: L10n.string("Uploaded %d audit log files (%@)."),
                    result.v4Uploaded.count,
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: totalBytes),
                        countStyle: .file
                    )
                )
            )
        }
        guard let v5 = result.v5 else {
            lines.append(L10n.string("No audit destination is configured, so audit logs stay on this Mac."))
            return lines.joined(separator: " ")
        }
        if let reason = nonEmpty(v5.skippedReason) {
            lines.append(String(format: L10n.string("Audit upload skipped: %@"), reason))
            return lines.joined(separator: " ")
        }
        if v5.acceptedBatches > 0 {
            lines.append(L10n.string("Audit logs sent."))
        }
        if v5.blockedAccounts > 0 {
            lines.append(L10n.string("Some accounts could not send their audit logs."))
        }
        if v5.pendingAccounts > 0 {
            lines.append(L10n.string("Some audit logs are still waiting to be sent. Try again later."))
        }
        if lines.isEmpty {
            lines.append(L10n.string("Audit logs are up to date."))
        }
        return lines.joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
