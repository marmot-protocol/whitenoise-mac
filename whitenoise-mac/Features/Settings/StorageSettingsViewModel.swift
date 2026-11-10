import Foundation
import MarmotKit
import Observation

enum StorageSettingsError: Equatable {
    case unavailable(String)

    var message: String {
        switch self {
        case .unavailable(let message): message
        }
    }
}

@MainActor
@Observable
final class StorageSettingsViewModel {
    private(set) var policy: AttachmentDownloadPolicyFfi?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var error: StorageSettingsError?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let attachmentPolicyController: AttachmentPolicyController?

    init(
        accountRef: String,
        runtime: (any MarmotRuntime)?,
        attachmentPolicyController: AttachmentPolicyController?
    ) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.attachmentPolicyController = attachmentPolicyController
    }

    func load() async {
        guard let runtime, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await runtime.attachmentDownloadPolicy(accountRef: accountRef)
            guard !Task.isCancelled else { return }
            policy = loaded
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    func saveLimits(retainedBytes: UInt64, diskReserve: UInt64, transferLimit: UInt64) async {
        guard let runtime, var updated = policy, !isSaving else { return }
        updated.retainedBytes = retainedBytes
        updated.diskReserve = diskReserve
        updated.transferLimit = transferLimit
        isSaving = true
        defer { isSaving = false }
        do {
            try await runtime.setAttachmentDownloadPolicy(accountRef: accountRef, policy: updated)
            guard !Task.isCancelled else { return }
            policy = updated
            error = nil
            await attachmentPolicyController?.refreshForCurrentConnectivity()
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    static func preview() -> StorageSettingsViewModel {
        StorageSettingsViewModel(accountRef: "preview", runtime: nil, attachmentPolicyController: nil)
    }
}
