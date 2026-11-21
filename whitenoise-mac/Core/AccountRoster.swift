//
//  AccountRoster.swift
//  whitenoise-mac
//
//  The one owner of the app's account list. MDK holds the accounts; this keeps the copy views draw
//  from, because a view can't call MDK while it renders (FFI reads run off the main actor) and MDK
//  sends no event when the list changes.
//

import Foundation
import MarmotKit
import Observation

/// MDK's account list as the app shows it, and the only place that changes it.
///
/// Callers that change an account (sign in, sign out, remove, an unlink from another device) ask
/// for `reload` instead of reading MDK and saving the result themselves. Reloads run one after
/// another, each starting only once the one before it has been installed, so the list installed
/// last is always the newest read. Without that, a read taken before MDK changed an account could
/// land after a newer one and put the old state back: an unlinked profile shown as signed in again.
@MainActor
@Observable
final class AccountRoster {
    private(set) var accounts: [AccountItem]
    /// The last reload queued, which the next one waits for.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Reloads not yet installed, so `clear()` can stop them and a profile edit knows which of them
    /// may have read the old name.
    @ObservationIgnored private var inFlight: [UUID: Task<[AccountItem], Error>] = [:]
    /// Names and pictures shown by `updateProfile` while reloads that may have read the old ones are
    /// still in flight. Each is applied to those reloads as they land and dropped after the last.
    @ObservationIgnored private var profileEdits: [ProfileEdit] = []

    private struct ProfileEdit {
        let accountId: String
        let displayName: String
        let pictureURL: String?
        let readsBefore: Set<UUID>
    }

    init(accounts: [AccountItem] = []) {
        self.accounts = accounts
    }

    /// Reads MDK's account list once every earlier reload has been installed, then installs it.
    /// Returns what it installed. A failed read installs nothing and throws.
    ///
    /// `including` keeps an account MDK doesn't list yet, such as one just created.
    @discardableResult
    func reload(from client: any MarmotRuntime, including extra: AccountItem? = nil) async throws -> [AccountItem] {
        let previous = tail
        let id = UUID()
        let read = Task { @MainActor [weak self] () throws -> [AccountItem] in
            await previous?.value
            try Task.checkCancellation()
            var items = try await Self.read(from: client)
            if let extra, !items.contains(where: { $0.id == extra.id }) {
                items.append(extra)
            }
            // Cleared while reading: what was read belongs to the list that was cleared.
            try Task.checkCancellation()
            guard let self else { return items }
            for edit in self.profileEdits where edit.readsBefore.contains(id) {
                items = items.map { $0.id == edit.accountId ? Self.edited($0, edit) : $0 }
            }
            self.accounts = items
            return items
        }
        inFlight[id] = read
        tail = Task { [weak self] in
            _ = try? await read.value
            guard let self else { return }
            self.inFlight[id] = nil
            let remaining = Set(self.inFlight.keys)
            self.profileEdits.removeAll { $0.readsBefore.isDisjoint(with: remaining) }
        }
        return try await read.value
    }

    /// MDK's list, with each account's name and picture, without installing it.
    nonisolated static func read(from client: any MarmotRuntime) async throws -> [AccountItem] {
        let summaries = try await FFIExecutor.run { try client.listAccounts() }
        return try await items(from: summaries, client: client)
    }

    /// Names and pictures for `summaries`, without installing them.
    nonisolated static func items(
        from summaries: [AccountSummaryFfi], client: any MarmotRuntime
    ) async throws -> [AccountItem] {
        try await FFIExecutor.run {
            summaries.map { summary in
                WorkspaceState.accountItem(
                    from: summary, resolved: WorkspaceState.resolvedAccountFFI(from: summary, client: client))
            }
        }
    }

    /// Empties the list, for a reset to a new install. Reloads still reading are cancelled, so none
    /// puts the old accounts back; each throws `CancellationError` to its caller.
    func clear() {
        for read in inFlight.values { read.cancel() }
        inFlight = [:]
        profileEdits = []
        tail = nil
        accounts = []
    }

    /// Shows a name or picture MDK now holds for `accountId` right away. A reload already in flight
    /// may have read the old one, so the edit is applied to it again when it lands.
    func updateProfile(accountId: String, displayName: String, pictureURL: String?) {
        let edit = ProfileEdit(
            accountId: accountId, displayName: displayName, pictureURL: pictureURL,
            readsBefore: Set(inFlight.keys))
        if !edit.readsBefore.isEmpty { profileEdits.append(edit) }
        accounts = accounts.map { $0.id == accountId ? Self.edited($0, edit) : $0 }
    }

    private static func edited(_ account: AccountItem, _ edit: ProfileEdit) -> AccountItem {
        AccountItem(
            id: account.id,
            accountRef: account.accountRef,
            displayName: edit.displayName,
            accountIdHex: account.accountIdHex,
            npub: account.npub,
            pictureURL: edit.pictureURL,
            localSigning: account.localSigning,
            externalSigning: account.externalSigning,
            isRunning: account.isRunning,
            signedOut: account.signedOut,
            unlinked: account.unlinked
        )
    }
}
