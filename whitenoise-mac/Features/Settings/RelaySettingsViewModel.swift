import Foundation
import MarmotKit
import Observation

enum RelaySettingsError: Equatable {
    case invalidURL
    case lastRelay(RelayRole)
    case unavailable(String)

    var message: String {
        switch self {
        case .invalidURL:
            L10n.string("Relay URLs must use wss:// (cleartext ws:// is allowed only for localhost).")
        case .lastRelay(let role):
            String(
                format: L10n.string("%@ needs at least one relay. Add another relay before turning this one off."),
                role.label
            )
        case .unavailable(let message):
            message
        }
    }
}

/// Account-scoped ownership for the Relays destination. The view renders only this snapshot;
/// changing accounts destroys the owning `AccountScope`, so an old account cannot publish into
/// its replacement's UI after an await resumes.
@MainActor
@Observable
final class RelaySettingsViewModel {
    private(set) var settings = RelaySettingsSnapshot.defaults
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var error: RelaySettingsError?

    var endpoints: [RelayEndpointItem] { settings.endpoints }

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let relayListsDidChange: @MainActor () -> Void
    @ObservationIgnored private var isActive = true

    init(
        accountRef: String,
        runtime: (any MarmotRuntime)?,
        relayListsDidChange: @escaping @MainActor () -> Void = {}
    ) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.relayListsDidChange = relayListsDidChange
    }

    func load() async {
        guard isActive, let runtime, !isLoading, !isSaving else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let lists = try await FFIExecutor.run { [accountRef] in
                try runtime.accountRelayLists(accountRef: accountRef)
            }
            guard isActive, !Task.isCancelled else { return }
            settings = RelaySettingsSnapshot(lists: lists)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard isActive, !Task.isCancelled else { return }
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func addRelay(_ url: String, roles: Set<RelayRole>) async {
        guard isActive else { return }
        let relay = RelayURLValidator.normalized(url)
        guard !relay.isEmpty, !roles.isEmpty else { return }
        guard RelayURLValidator.isAcceptable(relay) else {
            error = .invalidURL
            return
        }

        let key = RelayURLValidator.identity(relay)
        var lists: [RelayRole: [String]] = [:]
        for role in roles {
            var relays = settings.relays(for: role)
            guard !relays.contains(where: { RelayURLValidator.identity($0) == key }) else { continue }
            relays.append(relay)
            lists[role] = relays
        }
        await publish(lists)
    }

    func removeRelay(_ url: String) async {
        guard isActive else { return }
        if let role = settings.rolesDependingOnly(on: url).first {
            error = .lastRelay(role)
            return
        }

        let key = RelayURLValidator.identity(url)
        var lists: [RelayRole: [String]] = [:]
        for role in RelayRole.allCases {
            let relays = settings.relays(for: role)
            let remaining = relays.filter { RelayURLValidator.identity($0) != key }
            guard remaining.count != relays.count, !remaining.isEmpty else { continue }
            lists[role] = remaining
        }
        await publish(lists)
    }

    func setRole(_ role: RelayRole, isEnabled: Bool, forRelay url: String) async {
        guard isActive else { return }
        let relay = RelayURLValidator.normalized(url)
        let key = RelayURLValidator.identity(relay)
        var relays = settings.relays(for: role)
        let isAssigned = relays.contains { RelayURLValidator.identity($0) == key }
        guard isAssigned != isEnabled else { return }

        if isEnabled {
            guard RelayURLValidator.isAcceptable(relay) else {
                error = .invalidURL
                return
            }
            relays.append(relay)
        } else {
            guard !settings.isOnlyRelay(relay, for: role) else {
                error = .lastRelay(role)
                return
            }
            relays.removeAll { RelayURLValidator.identity($0) == key }
        }
        await publish([role: relays])
    }

    func restoreDefaults() async {
        guard isActive else { return }
        let lists = Dictionary(
            uniqueKeysWithValues: RelayRole.allCases.compactMap { role in
                settings.relays(for: role).map(RelayURLValidator.identity)
                    == role.defaultRelays.map(RelayURLValidator.identity) ? nil : (role, role.defaultRelays)
            }
        )
        await publish(lists)
    }

    private func publish(_ lists: [RelayRole: [String]]) async {
        guard isActive, let runtime, !lists.isEmpty, !isSaving else { return }
        guard lists.values.allSatisfy({ !$0.isEmpty }) else { return }
        guard lists.values.joined().allSatisfy(RelayURLValidator.isAcceptable) else {
            error = .invalidURL
            return
        }

        let previous = settings
        var optimistic = settings
        for role in RelayRole.allCases {
            if let relays = lists[role] { optimistic.setRelays(relays, for: role) }
        }
        settings = optimistic
        error = nil
        isSaving = true
        defer { isSaving = false }

        var published: AccountRelayListsFfi?
        do {
            for role in RelayRole.allCases {
                guard let relays = lists[role] else { continue }
                switch role {
                case .profile:
                    published = try await runtime.setAccountNip65Relays(
                        accountRef: accountRef,
                        relays: relays,
                        bootstrapRelays: previous.networkBootstrapRelays
                    )
                case .inbox:
                    published = try await runtime.setAccountInboxRelays(
                        accountRef: accountRef,
                        relays: relays,
                        bootstrapRelays: previous.networkBootstrapRelays
                    )
                }
                try Task.checkCancellation()
                guard isActive else { return }
            }
            guard let published else { return }
            settings = RelaySettingsSnapshot(lists: published)
            relayListsDidChange()
        } catch is CancellationError {
            return
        } catch {
            guard isActive, !Task.isCancelled else { return }
            settings = published.map(RelaySettingsSnapshot.init(lists:)) ?? previous
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func deactivate() {
        isActive = false
    }
}
