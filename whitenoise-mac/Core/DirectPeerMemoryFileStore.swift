//
//  DirectPeerMemoryFileStore.swift
//  whitenoise-mac
//
//  Protected persistence for the peer a conversation was last a two-person chat with.
//

import Foundation

/// The other party of a conversation, recorded while they were still a member.
///
/// MDK's roster only reports *current* members, so once the only other participant of a DM leaves,
/// nothing is left to name the conversation with and MDK projects the shortened group id as its
/// title. Remembering the departed peer locally is what keeps the chat recognisable — in the
/// sidebar, the chat header, and every picker built from `ChatItem`.
nonisolated struct RememberedDirectPeer: Codable, Hashable, Sendable {
    let accountIdHex: String
    /// Last published display name. Only a fallback: the peer's profile is still resolvable
    /// through the runtime after they leave, and a fresh lookup outranks this copy.
    let displayName: String?
    let pictureURL: String?

    init(accountIdHex: String, displayName: String?, pictureURL: String?) {
        self.accountIdHex = accountIdHex
        self.displayName = displayName
        self.pictureURL = pictureURL
    }
}

nonisolated protocol DirectPeerMemoryStoring: AnyObject {
    func loadAll() throws -> [String: [String: RememberedDirectPeer]]
    func write(_ peers: [String: RememberedDirectPeer], forAccountId accountId: String) throws
    func remove(forAccountId accountId: String) throws
    func removeAll() throws
}

nonisolated final class DirectPeerMemoryFileStore: DirectPeerMemoryStoring {
    private struct Record: Codable {
        let version: Int
        let accountId: String
        let peersByGroupId: [String: RememberedDirectPeer]
    }

    private static let directoryName = "Direct Peers"
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

    func loadAll() throws -> [String: [String: RememberedDirectPeer]] {
        var result: [String: [String: RememberedDirectPeer]] = [:]
        for record in try records.loadAll() where record.version == 1 {
            result[record.accountId, default: [:]].merge(record.peersByGroupId) { _, new in new }
        }
        return result
    }

    func write(_ peers: [String: RememberedDirectPeer], forAccountId accountId: String) throws {
        guard !peers.isEmpty else {
            try remove(forAccountId: accountId)
            return
        }
        try records.write(
            Record(version: 1, accountId: accountId, peersByGroupId: peers),
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
