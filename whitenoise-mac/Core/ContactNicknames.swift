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

    func nickname(forContactAccountIdHex hex: String) -> String? {
        guard !ownerAccountIdHex.isEmpty, let contact = Self.normalizedHex(hex) else { return nil }
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
