import Foundation

nonisolated protocol ContactNicknameStoring: AnyObject {
    func loadAll() throws -> [String: [String: String]]
    func write(_ nicknames: [String: String], forOwnerAccountIdHex ownerAccountIdHex: String) throws
    func remove(forOwnerAccountIdHex ownerAccountIdHex: String) throws
    func removeAll() throws
}

nonisolated final class ContactNicknameFileStore: ContactNicknameStoring {
    private struct Record: Codable {
        let version: Int
        let ownerAccountIdHex: String
        let nicknamesByContactIdHex: [String: String]
    }

    private static let directoryName = "Contact Nicknames"
    private let records: ProtectedLocalMetadataFileStore<Record>

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        records = ProtectedLocalMetadataFileStore(
            directoryName: Self.directoryName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    convenience init(fileManager: FileManager = .default, storageRootPath: String) {
        self.init(
            fileManager: fileManager,
            directoryURL: URL(fileURLWithPath: storageRootPath, isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        )
    }

    func loadAll() throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for record in try records.loadAll() where record.version == 1 {
            guard let owner = ContactNicknames.normalizedHex(record.ownerAccountIdHex) else { continue }
            result[owner, default: [:]].merge(record.nicknamesByContactIdHex) { _, new in new }
        }
        return result
    }

    func write(_ nicknames: [String: String], forOwnerAccountIdHex ownerAccountIdHex: String) throws {
        guard let owner = ContactNicknames.normalizedHex(ownerAccountIdHex) else { return }
        guard !nicknames.isEmpty else {
            try remove(forOwnerAccountIdHex: owner)
            return
        }
        try records.write(
            Record(version: 1, ownerAccountIdHex: owner, nicknamesByContactIdHex: nicknames),
            forKey: owner
        )
    }

    func remove(forOwnerAccountIdHex ownerAccountIdHex: String) throws {
        guard let owner = ContactNicknames.normalizedHex(ownerAccountIdHex) else { return }
        try records.remove(forKey: owner)
    }

    func removeAll() throws {
        try records.removeAll()
    }
}
