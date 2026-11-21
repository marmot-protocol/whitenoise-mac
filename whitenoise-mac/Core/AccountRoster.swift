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
    /// Changes MDK already holds, shown before a reload has them (a saved name, an account MDK signed
    /// out). Each is applied again to the reloads that were in flight when it was made, since those
    /// may have read the old value, and dropped after the last of them lands.
    @ObservationIgnored private var edits: [Edit] = []

    private struct Edit {
        let accountId: String
        let readsBefore: Set<UUID>
        let apply: (AccountItem) -> AccountItem
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
            for edit in self.edits where edit.readsBefore.contains(id) {
                items = items.map { $0.id == edit.accountId ? edit.apply($0) : $0 }
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
            self.edits.removeAll { $0.readsBefore.isDisjoint(with: remaining) }
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
        edits = []
        tail = nil
        accounts = []
    }

    /// Shows a name or picture for `accountId` right away. `confirmed` when MDK now holds it (the
    /// user just saved it): then a reload already in flight, which may have read the old one, gets
    /// it applied again when it lands. A value merely read from MDK isn't replayed over later reads.
    func updateProfile(accountId: String, displayName: String, pictureURL: String?, confirmed: Bool = false) {
        apply(to: accountId, replayingOverReloads: confirmed) { account in
            AccountItem(
                id: account.id, accountRef: account.accountRef, displayName: displayName,
                accountIdHex: account.accountIdHex, npub: account.npub, pictureURL: pictureURL,
                localSigning: account.localSigning, externalSigning: account.externalSigning,
                isRunning: account.isRunning, signedOut: account.signedOut, unlinked: account.unlinked)
        }
    }

    /// Shows `accountId` signed out right away: MDK signed it out (another device unlinked this Mac)
    /// before the app heard of it. A reload already in flight read it signed in, so it is applied
    /// again to those; any read that starts later gets it from MDK.
    func markSignedOut(accountId: String) {
        apply(to: accountId, replayingOverReloads: true) { account in
            AccountItem(
                id: account.id, accountRef: account.accountRef, displayName: account.displayName,
                accountIdHex: account.accountIdHex, npub: account.npub, pictureURL: account.pictureURL,
                localSigning: account.localSigning, externalSigning: account.externalSigning,
                isRunning: false, signedOut: true, unlinked: account.unlinked)
        }
    }

    private func apply(
        to accountId: String, replayingOverReloads: Bool, _ change: @escaping (AccountItem) -> AccountItem
    ) {
        if replayingOverReloads, !inFlight.isEmpty {
            edits.append(Edit(accountId: accountId, readsBefore: Set(inFlight.keys), apply: change))
        }
        accounts = accounts.map { $0.id == accountId ? change($0) : $0 }
    }
}
