//
//  ImprovementsPromptPreferences.swift
//  whitenoise-mac
//
//  Account-scoped record of who has already been offered the one-time "Help Improve White Noise"
//  choice, so it is asked once per identity and never again.
//
//  Deliberately records only *that* an account was asked, never what it answered: the answer is the
//  pair of Data Sharing settings themselves, which the Marmot core owns per account and Privacy &
//  Security reads back. Keeping a second copy of the answer here would be a second source of truth
//  that could disagree with the one the runtime actually exports from.
//

import Foundation

@MainActor
protocol ImprovementsPromptStoring: AnyObject {
    func hasBeenOffered(toOwnerAccountIdHex accountIdHex: String) -> Bool
    func markOffered(toOwnerAccountIdHex accountIdHex: String)
    func forget(ownerAccountIdHex accountIdHex: String)
    func clearAll()
}

@MainActor
final class UserDefaultsImprovementsPromptStore: ImprovementsPromptStoring {
    private enum Key {
        static let offeredAccounts = "whitenoise.mac.improvementsPromptOfferedAccountIdHexes"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasBeenOffered(toOwnerAccountIdHex accountIdHex: String) -> Bool {
        let accountId = Self.normalized(accountIdHex)
        guard !accountId.isEmpty else { return false }
        return offeredAccounts.contains(accountId)
    }

    func markOffered(toOwnerAccountIdHex accountIdHex: String) {
        let accountId = Self.normalized(accountIdHex)
        guard !accountId.isEmpty else { return }

        var accounts = offeredAccounts
        guard accounts.insert(accountId).inserted else { return }
        write(accounts)
    }

    func forget(ownerAccountIdHex accountIdHex: String) {
        let accountId = Self.normalized(accountIdHex)
        guard !accountId.isEmpty else { return }

        var accounts = offeredAccounts
        guard accounts.remove(accountId) != nil else { return }
        write(accounts)
    }

    func clearAll() {
        defaults.removeObject(forKey: Key.offeredAccounts)
    }

    private var offeredAccounts: Set<String> {
        Set(defaults.stringArray(forKey: Key.offeredAccounts) ?? [])
    }

    private func write(_ accounts: Set<String>) {
        if accounts.isEmpty {
            clearAll()
        } else {
            defaults.set(accounts.sorted(), forKey: Key.offeredAccounts)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
