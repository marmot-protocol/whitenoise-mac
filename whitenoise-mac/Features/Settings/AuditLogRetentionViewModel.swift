import Foundation
import MarmotKit
import Observation

/// How long diagnostic (audit) logs are kept on this Mac, and how much room each account's logs
/// may take (MarmotKit 0.16.0).
///
/// MDK enforces both. Over the size budget it deletes the oldest files that were already sent, or
/// that will never be sent; logs still waiting to be sent go only once they pass the age limit.
/// The setter clamps (1–30 days, at least 16 MiB) and returns what it stored, which is what this
/// model shows.
@MainActor
@Observable
final class AuditLogRetentionViewModel {
    static let ageOptions: [UInt32] = [1, 3, 7, 14, 30]
    static let sizeOptions: [UInt64] = [64 << 20, 128 << 20, 256 << 20, 512 << 20, 1 << 30]

    private(set) var retention: AuditLogRetentionFfi?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var error: String?

    @ObservationIgnored private let runtime: (any MarmotRuntime)?

    init(runtime: (any MarmotRuntime)?) {
        self.runtime = runtime
    }

    /// The picker's choices, including the stored value when it is not one of the presets (set by
    /// another build or clamped by MDK), so the picker never shows a blank selection.
    var ageChoices: [UInt32] {
        Self.including(retention?.maxAgeDays, in: Self.ageOptions)
    }

    var sizeChoices: [UInt64] {
        Self.including(retention?.maxBytesPerAccount, in: Self.sizeOptions)
    }

    /// A read and a write never overlap: a read that started before a save would return the old
    /// policy after it, and the other picker would then write that stale field back.
    var isBusy: Bool { isLoading || isSaving }

    func load() async {
        guard let runtime, !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await FFIExecutor.run { [runtime] in try runtime.auditLogRetention() }
            guard !Task.isCancelled else { return }
            retention = loaded
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    func setMaxAgeDays(_ days: UInt32) async {
        guard let current = retention, current.maxAgeDays != days else { return }
        await save(AuditLogRetentionFfi(maxAgeDays: days, maxBytesPerAccount: current.maxBytesPerAccount))
    }

    func setMaxBytesPerAccount(_ bytes: UInt64) async {
        guard let current = retention, current.maxBytesPerAccount != bytes else { return }
        await save(AuditLogRetentionFfi(maxAgeDays: current.maxAgeDays, maxBytesPerAccount: bytes))
    }

    private func save(_ requested: AuditLogRetentionFfi) async {
        guard let runtime, !isBusy else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let stored = try await FFIExecutor.run { [runtime] in
                try runtime.setAuditLogRetention(retention: requested)
            }
            retention = stored
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private static func including<T: Comparable>(_ value: T?, in options: [T]) -> [T] {
        guard let value, !options.contains(value) else { return options }
        return (options + [value]).sorted()
    }

    static func preview(_ retention: AuditLogRetentionFfi? = nil) -> AuditLogRetentionViewModel {
        let model = AuditLogRetentionViewModel(runtime: nil)
        model.retention = retention ?? AuditLogRetentionFfi(maxAgeDays: 30, maxBytesPerAccount: 256 << 20)
        return model
    }
}
