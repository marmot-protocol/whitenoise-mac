import Foundation
import MarmotKit
import Observation

enum AttachmentPolicyError: Equatable {
    case unavailable(String)
    case staleGeneration
}

/// Applies the host-managed acquisition fence for one account. No automatic category is
/// permitted until both account readiness and the user's persisted policy are known.
@MainActor
@Observable
final class AttachmentPolicyController {
    private(set) var policy: AttachmentDownloadPolicyFfi?
    private(set) var readiness: AccountSetupReadinessFfi?
    private(set) var effectivePermission = AttachmentAutomaticPermissionFfi(
        images: false, videos: false, audio: false, files: false
    )
    private(set) var error: AttachmentPolicyError?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private var connectivityAvailable = false

    init(accountRef: String, runtime: any MarmotRuntime) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    func revoke() async {
        let denied = AttachmentAutomaticPermissionFfi(
            images: false, videos: false, audio: false, files: false
        )
        do {
            let generation = try await runtime.beginAttachmentPermissionUpdate(accountRef: accountRef)
            guard
                try await runtime.setAttachmentAutomaticPermission(
                    accountRef: accountRef,
                    generation: generation,
                    permission: denied
                )
            else {
                effectivePermission = denied
                error = .staleGeneration
                return
            }
            effectivePermission = denied
            error = nil
        } catch is CancellationError {
            return
        } catch {
            effectivePermission = denied
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    func refresh(connectivityAvailable: Bool) async {
        self.connectivityAvailable = connectivityAvailable
        do {
            let denied = AttachmentAutomaticPermissionFfi(
                images: false, videos: false, audio: false, files: false
            )
            let revocation = try await runtime.beginAttachmentPermissionUpdate(accountRef: accountRef)
            try Task.checkCancellation()
            guard
                try await runtime.setAttachmentAutomaticPermission(
                    accountRef: accountRef,
                    generation: revocation,
                    permission: denied
                )
            else {
                effectivePermission = denied
                error = .staleGeneration
                return
            }
            effectivePermission = denied

            let readiness = try await FFIExecutor.run { [runtime, accountRef] in
                try runtime.accountSetupReadiness(accountRef: accountRef)
            }
            let policy = try await runtime.attachmentDownloadPolicy(accountRef: accountRef)
            try Task.checkCancellation()
            self.readiness = readiness
            self.policy = policy

            let accountReady = readiness == .localReady || readiness == .networkReady
            let allowed = accountReady && connectivityAvailable && policy.automatic
            let permission = AttachmentAutomaticPermissionFfi(
                images: allowed, videos: allowed, audio: allowed, files: allowed
            )
            guard allowed else {
                error = nil
                return
            }
            let generation = try await runtime.beginAttachmentPermissionUpdate(accountRef: accountRef)
            try Task.checkCancellation()
            guard
                try await runtime.setAttachmentAutomaticPermission(
                    accountRef: accountRef, generation: generation, permission: permission
                )
            else {
                effectivePermission = AttachmentAutomaticPermissionFfi(
                    images: false, videos: false, audio: false, files: false
                )
                error = .staleGeneration
                return
            }
            effectivePermission = permission
            error = nil
        } catch is CancellationError {
            return
        } catch {
            effectivePermission = AttachmentAutomaticPermissionFfi(
                images: false, videos: false, audio: false, files: false)
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    func refreshForCurrentConnectivity() async {
        await refresh(connectivityAvailable: connectivityAvailable)
    }
}
