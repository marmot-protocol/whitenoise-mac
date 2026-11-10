import Foundation
import MarmotKit
import Observation

enum QuarantinedGroupsError: Equatable {
    case unavailable(String)

    var message: String {
        switch self {
        case .unavailable(let message): message
        }
    }
}

@MainActor
@Observable
final class QuarantinedGroupsViewModel {
    private(set) var groups: [AppQuarantinedGroupFfi] = []
    private(set) var isLoading = false
    private(set) var retryingGroupIDs: Set<String> = []
    private(set) var error: QuarantinedGroupsError?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?

    init(accountRef: String, runtime: (any MarmotRuntime)?) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    func load() async {
        guard let runtime, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await runtime.quarantinedGroups(accountRef: accountRef)
            guard !Task.isCancelled else { return }
            groups = loaded
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    func retry(_ groupID: String) async {
        guard let runtime, !retryingGroupIDs.contains(groupID) else { return }
        retryingGroupIDs.insert(groupID)
        defer { retryingGroupIDs.remove(groupID) }
        do {
            let recovered = try await runtime.retryHydrateQuarantinedGroup(
                accountRef: accountRef,
                groupIdHex: groupID
            )
            guard !Task.isCancelled else { return }
            if recovered {
                groups.removeAll { $0.groupIdHex == groupID }
            } else {
                groups = try await runtime.quarantinedGroups(accountRef: accountRef)
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(UserFacingError.message(for: error))
        }
    }

    static func preview() -> QuarantinedGroupsViewModel {
        QuarantinedGroupsViewModel(accountRef: "preview", runtime: nil)
    }
}
