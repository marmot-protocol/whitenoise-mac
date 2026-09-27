import Foundation
import MarmotKit
import Observation

/// Account-scoped durable avatar bytes. Remote URLs remain a presentation fallback when a
/// target has no ready retained asset or the bounded read is deferred.
@MainActor
@Observable
final class AvatarAssetStore {
    private(set) var assetsByTarget: [String: AvatarAssetFfi] = [:]
    private(set) var bytesByReference: [String: AvatarBytesFfi] = [:]
    private(set) var error: String?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime

    init(accountRef: String, runtime: any MarmotRuntime) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    /// Registers visible demand for `targets` and reads whichever of them the core already holds.
    /// Acquisition itself completes later, through a projection update that calls `load` again.
    func request(targets: [String]) async {
        guard !targets.isEmpty else { return }
        do {
            var assets: [AvatarAssetFfi] = []
            for batch in AvatarAssetReads.batches(Array(Set(targets)).sorted()) {
                assets += try await runtime.requestAvatarAssets(accountRef: accountRef, targets: batch)
                try Task.checkCancellation()
            }
            for asset in assets { assetsByTarget[asset.target] = asset }
            try await readMissingBytes(for: assets)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Installs the assets a snapshot carries. Readable ones are read; the rest are requested,
    /// because the core only acquires an identity avatar something on screen has asked for — the
    /// chat list's own rows get background demand, message senders do not.
    func load(assets: [AvatarAssetFfi]) async {
        guard !assets.isEmpty else { return }
        for asset in assets { assetsByTarget[asset.target] = asset }
        let unrequested = assets.filter { asset in
            (asset.availability == .missing || asset.availability == .stale)
                && (asset.acquisition == nil || asset.acquisition == .idle)
        }
        do {
            try await readMissingBytes(for: assets)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        if !unrequested.isEmpty {
            await request(targets: unrequested.map(\.target))
        }
    }

    private func readMissingBytes(for assets: [AvatarAssetFfi]) async throws {
        let references = AvatarAssetReads.readableReferences(
            assets.filter { asset in
                guard let reference = asset.reference else { return false }
                return bytesByReference[reference]?.contentRevision != asset.contentRevision
            }
        )
        guard !references.isEmpty else { return }
        let payloads = try await AvatarAssetReads.read(
            runtime: runtime, accountRef: accountRef, references: references
        )
        bytesByReference.merge(payloads) { _, latest in latest }
    }

    func clear() async {
        do {
            try await runtime.clearAvatarCache(accountRef: accountRef)
            assetsByTarget.removeAll()
            bytesByReference.removeAll()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
