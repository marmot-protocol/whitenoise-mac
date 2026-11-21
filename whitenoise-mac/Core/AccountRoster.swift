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
        let read = Task { @MainActor [weak self] () throws -> [AccountItem] in
            await previous?.value
            var items = try await Self.read(from: client)
            if let extra, !items.contains(where: { $0.id == extra.id }) {
                items.append(extra)
            }
            self?.accounts = items
            return items
        }
        tail = Task { _ = try? await read.value }
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

    /// Empties the list, for a reset to a new install.
    func clear() {
        accounts = []
    }

    /// Shows a name or picture the user just saved for `accountId` before MDK's next read has it.
    func updateProfile(accountId: String, displayName: String, pictureURL: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        let account = accounts[index]
        accounts[index] = AccountItem(
            id: account.id,
            accountRef: account.accountRef,
            displayName: displayName,
            accountIdHex: account.accountIdHex,
            npub: account.npub,
            pictureURL: pictureURL,
            localSigning: account.localSigning,
            externalSigning: account.externalSigning,
            isRunning: account.isRunning,
            signedOut: account.signedOut,
            unlinked: account.unlinked
        )
    }
}
