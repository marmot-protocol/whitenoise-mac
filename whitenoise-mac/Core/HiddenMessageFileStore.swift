//
//  HiddenMessageFileStore.swift
//  whitenoise-mac
//
//  Protected persistence for local "Delete for me" message ids.
//

import Foundation

nonisolated struct HiddenMessageScope: Codable, Hashable, Sendable {
    let accountId: String
    let groupIdHex: String
}

nonisolated protocol HiddenMessageStoring: AnyObject {
    func loadAll() throws -> [HiddenMessageScope: Set<String>]
    func write(_ messageIds: Set<String>, for scope: HiddenMessageScope) throws
    func remove(for scope: HiddenMessageScope) throws
    func removeAll() throws
}

nonisolated final class HiddenMessageFileStore: HiddenMessageStoring {
    private struct Record: Codable {
        let version: Int
        let scope: HiddenMessageScope
        let messageIds: [String]
    }

    private static let directoryName = "Hidden Messages"
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

    func loadAll() throws -> [HiddenMessageScope: Set<String>] {
        var result: [HiddenMessageScope: Set<String>] = [:]
        for record in try records.loadAll() where record.version == 1 {
            result[record.scope, default: []].formUnion(record.messageIds)
        }
        return result
    }

    func write(_ messageIds: Set<String>, for scope: HiddenMessageScope) throws {
        guard !messageIds.isEmpty else {
            try remove(for: scope)
            return
        }
        let record = Record(version: 1, scope: scope, messageIds: messageIds.sorted())
        try records.write(record, forKey: storageKey(for: scope))
    }

    func remove(for scope: HiddenMessageScope) throws {
        try records.remove(forKey: storageKey(for: scope))
    }

    func removeAll() throws {
        try records.removeAll()
    }

    private func storageKey(for scope: HiddenMessageScope) -> String {
        "\(scope.accountId)\u{1F}\(scope.groupIdHex)"
    }
}
