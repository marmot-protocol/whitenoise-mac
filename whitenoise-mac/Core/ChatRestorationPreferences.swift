//
//  ChatRestorationPreferences.swift
//  whitenoise-mac
//
//  Account-scoped persistence for the optional startup chat restoration setting.
//

import Foundation

@MainActor
protocol ChatRestorationStoring: AnyObject {
    var isEnabled: Bool { get }

    func setEnabled(_ enabled: Bool)
    func targetGroupId(forOwnerAccountIdHex accountIdHex: String) -> String?
    func setTarget(groupIdHex: String, forOwnerAccountIdHex accountIdHex: String)
    func removeTarget(forOwnerAccountIdHex accountIdHex: String)
    func clearTargets()
}

@MainActor
final class UserDefaultsChatRestorationStore: ChatRestorationStoring {
    private enum Key {
        static let isEnabled = "whitenoise.mac.restoreLastSelectedChat"
        static let targetsByAccount = "whitenoise.mac.lastSelectedChatByAccountIdHex"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Key.isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.isEnabled)
    }

    func targetGroupId(forOwnerAccountIdHex accountIdHex: String) -> String? {
        targetsByAccount[Self.normalized(accountIdHex)]
    }

    func setTarget(groupIdHex: String, forOwnerAccountIdHex accountIdHex: String) {
        guard isEnabled else { return }
        let accountId = Self.normalized(accountIdHex)
        let groupId = Self.normalized(groupIdHex)
        guard !accountId.isEmpty, !groupId.isEmpty else { return }

        var targets = targetsByAccount
        targets[accountId] = groupId
        defaults.set(targets, forKey: Key.targetsByAccount)
    }

    func removeTarget(forOwnerAccountIdHex accountIdHex: String) {
        let accountId = Self.normalized(accountIdHex)
        guard !accountId.isEmpty else { return }

        var targets = targetsByAccount
        targets[accountId] = nil
        writeTargets(targets)
    }

    func clearTargets() {
        defaults.removeObject(forKey: Key.targetsByAccount)
    }

    private var targetsByAccount: [String: String] {
        defaults.dictionary(forKey: Key.targetsByAccount) as? [String: String] ?? [:]
    }

    private func writeTargets(_ targets: [String: String]) {
        if targets.isEmpty {
            clearTargets()
        } else {
            defaults.set(targets, forKey: Key.targetsByAccount)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
