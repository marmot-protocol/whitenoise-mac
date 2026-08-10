import Foundation

nonisolated struct ContactNicknames: Equatable, Sendable {
    static let maxLength = 64

    let ownerAccountIdHex: String
    private let byContactIdHex: [String: String]
    static let none = ContactNicknames(ownerAccountIdHex: "", byContactIdHex: [:])

    init(ownerAccountIdHex: String, byContactIdHex: [String: String]) {
        self.ownerAccountIdHex = Self.normalizedHex(ownerAccountIdHex) ?? ""
        self.byContactIdHex = byContactIdHex.reduce(into: [String: String]()) { result, entry in
            guard
                let contact = Self.normalizedHex(entry.key),
                let nickname = Self.sanitized(entry.value)
            else { return }
            result[contact] = nickname
        }
    }

    var isEmpty: Bool { byContactIdHex.isEmpty }

    /// The `isEmpty` check comes first so the overwhelmingly common "this account has nicknamed
    /// nobody" case costs one flag read. Projections that fold nicknames in walk a whole roster
    /// per rebuild, and normalizing each member's hex allocates.
    func nickname(forContactAccountIdHex hex: String) -> String? {
        guard !byContactIdHex.isEmpty, !ownerAccountIdHex.isEmpty, let contact = Self.normalizedHex(hex)
        else { return nil }
        return byContactIdHex[contact]
    }

    func displayName(forContactAccountIdHex hex: String, published: String?) -> String? {
        nickname(forContactAccountIdHex: hex) ?? published
    }

    static func owner(
        activeAccountIdHex: String?,
        localAccountIdsHex: [String],
        contactAccountIdHex: String
    ) -> String? {
        guard let owner = normalizedHex(activeAccountIdHex ?? ""),
            let contact = normalizedHex(contactAccountIdHex)
        else { return nil }
        let contactIsLocalAccount = localAccountIdsHex.contains { normalizedHex($0) == contact }
        return contactIsLocalAccount ? nil : owner
    }

    static func normalizedHex(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    static func sanitized(_ raw: String?) -> String? {
        guard let sanitized = PeerDisplayText.sanitize(raw) else { return nil }
        return sanitized.count <= maxLength ? sanitized : String(sanitized.prefix(maxLength))
    }
}

/// Identifies the nickname set a projection was built from: whose private labels, and which
/// revision of them. Comparing one is a string and an integer, so a memoized projection can
/// prove it is still current on a hot path without rebuilding or hashing the map itself.
nonisolated struct ContactNicknameStamp: Equatable, Sendable {
    let ownerAccountIdHex: String
    let revision: UInt64
}

/// A projection memoized against the nickname set that produced it. Nicknames are folded into
/// projections rather than resolved at render time, so every such memo has to be able to say
/// which labels it was baked with — see `WorkspaceState.contactNicknameStamp`.
nonisolated struct NicknameStamped<Value: Sendable>: Sendable {
    let stamp: ContactNicknameStamp
    let value: Value

    /// The memoized value, or nil once the nickname set has moved on since it was built.
    func value(at stamp: ContactNicknameStamp) -> Value? {
        self.stamp == stamp ? value : nil
    }
}
