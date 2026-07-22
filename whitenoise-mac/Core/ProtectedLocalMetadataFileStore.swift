//
//  ProtectedLocalMetadataFileStore.swift
//  whitenoise-mac
//
//  Shared protected-file mechanics for local-only account and conversation metadata.
//

import CryptoKit
import Foundation

nonisolated final class ProtectedLocalMetadataFileStore<Record: Codable> {
    private let directoryName: String
    private let fileManager: FileManager
    private let configuredDirectoryURL: URL?

    init(
        directoryName: String,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.directoryName = directoryName
        self.fileManager = fileManager
        configuredDirectoryURL = directoryURL
    }

    func loadAll() throws -> [Record] {
        let directory = try directoryURL()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard
                url.pathExtension == "json",
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                let data = try? Data(contentsOf: url)
            else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    func write(_ record: Record, forKey key: String) throws {
        let directory = try preparedDirectoryURL()
        let url = recordURL(forKey: key, directory: directory)
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

    func remove(forKey key: String) throws {
        let directory = try directoryURL()
        let url = recordURL(forKey: key, directory: directory)
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
            .appendingPathComponent(directoryName, isDirectory: true)
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

    private func recordURL(forKey key: String, directory: URL) -> URL {
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
