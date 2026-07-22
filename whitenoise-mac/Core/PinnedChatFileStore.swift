//
//  PinnedChatFileStore.swift
//  whitenoise-mac
//
//  Protected persistence for local, account-scoped pinned chats.
//

import Foundation

nonisolated protocol PinnedChatStoring: AnyObject {
    func loadAll() throws -> [String: Set<String>]
    func write(_ groupIds: Set<String>, forAccountId accountId: String) throws
    func remove(forAccountId accountId: String) throws
    func removeAll() throws
}

nonisolated final class PinnedChatFileStore: PinnedChatStoring {
    private struct Record: Codable {
        let version: Int
        let accountId: String
        let groupIds: [String]
    }

    private static let directoryName = "Pinned Chats"
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

    func loadAll() throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for record in try records.loadAll() where record.version == 1 {
            result[record.accountId, default: []].formUnion(record.groupIds)
        }
        return result
    }

    func write(_ groupIds: Set<String>, forAccountId accountId: String) throws {
        guard !groupIds.isEmpty else {
            try remove(forAccountId: accountId)
            return
        }
        try records.write(
            Record(version: 1, accountId: accountId, groupIds: groupIds.sorted()),
            forKey: accountId
        )
    }

    func remove(forAccountId accountId: String) throws {
        try records.remove(forKey: accountId)
    }

    func removeAll() throws {
        try records.removeAll()
    }
}
