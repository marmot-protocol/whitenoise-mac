//
//  HiddenMessageFileStore.swift
//  whitenoise-mac
//
//  Protected persistence for local "Delete for me" message ids.
//

import CryptoKit
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
    private let fileManager: FileManager
    private let configuredDirectoryURL: URL?

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        configuredDirectoryURL = directoryURL
    }

    convenience init(fileManager: FileManager = .default, storageRootPath: String) {
        self.init(
            fileManager: fileManager,
            directoryURL: URL(fileURLWithPath: storageRootPath, isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        )
    }

    func loadAll() throws -> [HiddenMessageScope: Set<String>] {
        let directory = try directoryURL()
        guard fileManager.fileExists(atPath: directory.path) else { return [:] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var result: [HiddenMessageScope: Set<String>] = [:]
        for url in urls where url.pathExtension == "json" {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                let data = try? Data(contentsOf: url),
                let record = try? JSONDecoder().decode(Record.self, from: data),
                record.version == 1
            else { continue }
            result[record.scope, default: []].formUnion(record.messageIds)
        }
        return result
    }

    func write(_ messageIds: Set<String>, for scope: HiddenMessageScope) throws {
        guard !messageIds.isEmpty else {
            try remove(for: scope)
            return
        }
        let directory = try preparedDirectoryURL()
        let url = recordURL(for: scope, directory: directory)
        let record = Record(version: 1, scope: scope, messageIds: messageIds.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        try excludeFromBackup(url)
    }

    func remove(for scope: HiddenMessageScope) throws {
        let directory = try directoryURL()
        let url = recordURL(for: scope, directory: directory)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func removeAll() throws {
        let directory = try directoryURL()
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func directoryURL() throws -> URL {
        if let configuredDirectoryURL { return configuredDirectoryURL }
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return
            base
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func preparedDirectoryURL() throws -> URL {
        let directory = try directoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        try excludeFromBackup(directory)
        return directory
    }

    private func recordURL(for scope: HiddenMessageScope, directory: URL) -> URL {
        let key = "\(scope.accountId)\u{1F}\(scope.groupIdHex)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}
