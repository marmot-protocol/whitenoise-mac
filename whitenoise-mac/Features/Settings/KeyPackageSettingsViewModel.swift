import Foundation
import MarmotKit
import Observation

enum KeyPackageSettingsError: Equatable {
    case unavailable(String)

    var message: String {
        switch self {
        case .unavailable(let message): message
        }
    }
}

@MainActor
@Observable
final class KeyPackageSettingsViewModel {
    private(set) var inventory: [AccountKeyPackageInventoryEntryFfi] = []
    private(set) var relayEvents: [AccountKeyPackageRelayEventFfi] = []
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var error: KeyPackageSettingsError?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?

    init(accountRef: String, runtime: (any MarmotRuntime)?) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    func loadLocalInventory() async {
        guard let runtime, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await FFIExecutor.run { [runtime, accountRef] in
                try runtime.localAccountKeyPackages(accountRef: accountRef)
            }
            guard !Task.isCancelled else { return }
            inventory = loaded
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    func refresh() async {
        guard let runtime, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let bootstrapRelays = try await FFIExecutor.run { [runtime, accountRef] in
                RelaySettingsSnapshot(lists: try runtime.accountRelayLists(accountRef: accountRef))
                    .networkBootstrapRelays
            }
            guard !Task.isCancelled else { return }
            async let inventory = runtime.refreshAccountKeyPackages(
                accountRef: accountRef,
                bootstrapRelays: bootstrapRelays
            )
            async let relayEvents = runtime.accountKeyPackageRelayEvents(
                accountRef: accountRef,
                bootstrapRelays: bootstrapRelays
            )
            let (loadedInventory, loadedEvents) = try await (inventory, relayEvents)
            guard !Task.isCancelled else { return }
            self.inventory = loadedInventory
            self.relayEvents = loadedEvents
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    static func preview() -> KeyPackageSettingsViewModel {
        KeyPackageSettingsViewModel(accountRef: "preview", runtime: nil)
    }
}
