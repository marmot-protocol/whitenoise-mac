import CryptoKit
import Foundation
import MarmotKit
import Security

nonisolated struct MessageMediaDiskCacheKey: Hashable, Sendable {
    let accountId: String
    let groupIdHex: String
    let ciphertextSha256: String
    let plaintextSha256: String

    init(accountId: String, groupIdHex: String, reference: MediaAttachmentReferenceFfi) {
        self.accountId = accountId
        self.groupIdHex = groupIdHex
        self.ciphertextSha256 = reference.ciphertextSha256.lowercased()
        self.plaintextSha256 = reference.plaintextSha256.lowercased()
    }

    var cacheID: String {
        Self.hexDigest("media-cache-v1", accountId, groupIdHex, ciphertextSha256)
    }

    var accountDigest: String {
        Self.accountDigest(for: accountId)
    }

    var payloadID: String {
        "disk|\(cacheID)"
    }

    private static func hexDigest(_ parts: String...) -> String {
        var data = Data()
        for part in parts {
            data.append(contentsOf: part.utf8)
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func accountDigest(for accountId: String) -> String {
        hexDigest("media-cache-account-v1", accountId)
    }
}

enum MessageMediaDiskCacheError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case randomKeyGenerationFailed(OSStatus)
    case invalidKeychainData
    case invalidSealedBox

    var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status):
            "Unable to read the media cache encryption key from Keychain (\(status))."
        case .keychainWriteFailed(let status):
            "Unable to store the media cache encryption key in Keychain (\(status))."
        case .randomKeyGenerationFailed(let status):
            "Unable to generate a media cache encryption key (\(status))."
        case .invalidKeychainData:
            "The media cache encryption key stored in Keychain is invalid."
        case .invalidSealedBox:
            "The cached media payload is not a valid encrypted record."
        }
    }
}

nonisolated enum MessageMediaDiskCacheKeychain {
    private static let service = "dev.ipf.whitenoise.media-cache"
    private static let account = "media-cache-v1"
    private static let keyByteCount = 32

    static func symmetricKey() throws -> SymmetricKey {
        if let stored = try storedKeyData() {
            guard stored.count == keyByteCount else {
                throw MessageMediaDiskCacheError.invalidKeychainData
            }
            return SymmetricKey(data: stored)
        }

        let generated = try randomKeyData()
        do {
            try storeKeyData(generated)
        } catch MessageMediaDiskCacheError.keychainWriteFailed(errSecDuplicateItem) {
            if let stored = try storedKeyData(), stored.count == keyByteCount {
                return SymmetricKey(data: stored)
            }
            throw MessageMediaDiskCacheError.invalidKeychainData
        }
        return SymmetricKey(data: generated)
    }

    static func deleteKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func storedKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MessageMediaDiskCacheError.keychainReadFailed(status)
        }
        guard let data = result as? Data else {
            throw MessageMediaDiskCacheError.invalidKeychainData
        }
        return data
    }

    private static func storeKeyData(_ data: Data) throws {
        var query = baseQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MessageMediaDiskCacheError.keychainWriteFailed(status)
        }
    }

    private static func randomKeyData() throws -> Data {
        var data = Data(count: keyByteCount)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw MessageMediaDiskCacheError.randomKeyGenerationFailed(status)
        }
        return data
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

nonisolated final class MessageMediaDiskCache: @unchecked Sendable {
    typealias DirectoryResolver = @Sendable () throws -> URL
    typealias KeyProvider = @Sendable () throws -> SymmetricKey
    typealias KeyDeleter = @Sendable () -> Void

    static let shared = MessageMediaDiskCache()

    private static let directoryName = "WhiteNoiseMediaCache"
    private static let versionDirectoryName = "v1"
    private static let metadataFileName = "metadata.bin"
    private static let payloadFileName = "payload.bin"

    private let directoryResolver: DirectoryResolver
    private let keyProvider: KeyProvider
    private let keyDeleter: KeyDeleter
    private let lock = NSLock()
    private var generation = 0
    private var purgeTask: Task<Void, Never>?
    private var purgeGeneration: Int?

    init(
        directoryResolver: @escaping DirectoryResolver = MessageMediaDiskCache.defaultDirectoryURL,
        keyProvider: @escaping KeyProvider = MessageMediaDiskCacheKeychain.symmetricKey,
        keyDeleter: @escaping KeyDeleter = MessageMediaDiskCacheKeychain.deleteKey
    ) {
        self.directoryResolver = directoryResolver
        self.keyProvider = keyProvider
        self.keyDeleter = keyDeleter
    }

    static func defaultDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directoryURL(baseURL: base)
    }

    static func directoryURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(versionDirectoryName, isDirectory: true)
    }

    func cachedDownload(for key: MessageMediaDiskCacheKey) async -> MessageMediaDownload? {
        await waitForActivePurge()
        let startGeneration = currentGeneration()

        let root: URL
        let symmetricKey: SymmetricKey
        do {
            root = try directoryResolver()
            symmetricKey = try keyProvider()
        } catch {
            return nil
        }

        let result = await Task.detached(priority: .utility) {
            Self.readDownload(for: key, root: root, symmetricKey: symmetricKey)
        }.value

        guard currentGeneration() == startGeneration else { return nil }
        return result
    }

    func store(_ download: MessageMediaDownload, for key: MessageMediaDiskCacheKey) async {
        // #236: atomically reject the store if a wipe/purge is in flight — `beginStore()`
        // returns nil under an active purge, so we never resurrect the cache root after the
        // key has been (or is about to be) deleted. #230: also honor cooperative cancellation
        // so a store whose owning WorkspaceState task is cancelled mid-flight (account purge)
        // bails and cleans up its staging rather than committing late. `start.generation` is
        // the snapshot taken under the lock by `beginStore()`.
        guard let start = beginStore() else { return }
        guard !Task.isCancelled else { return }

        let root: URL
        let symmetricKey: SymmetricKey
        do {
            root = try directoryResolver()
            symmetricKey = try keyProvider()
        } catch {
            return
        }
        guard !Task.isCancelled, currentGeneration() == start.generation else { return }

        let plaintext = download.payload.data
        let prepared = await Task.detached(priority: .utility) {
            Self.prepareStagedEntry(
                download: download,
                plaintext: plaintext,
                for: key,
                root: root,
                symmetricKey: symmetricKey
            )
        }.value

        guard let prepared else { return }
        guard !Task.isCancelled else {
            Self.discardPreparedEntry(prepared)
            return
        }
        commitPreparedEntry(prepared, startGeneration: start.generation)
    }

    func purgeAll(removeEncryptionKey: Bool = false) async {
        let root = try? directoryResolver()
        let deleteKey = keyDeleter
        let task = beginPurge {
            if let root {
                try? FileManager.default.removeItem(at: root)
            }
            if removeEncryptionKey {
                deleteKey()
            }
        }
        await task.task.value
        finishPurge(task)
    }

    func purgeAccount(_ accountId: String) async {
        await waitForActivePurge()

        let root: URL
        let symmetricKey: SymmetricKey
        do {
            root = try directoryResolver()
            symmetricKey = try keyProvider()
        } catch {
            return
        }

        let accountDigest = MessageMediaDiskCacheKey.accountDigest(for: accountId)
        let task = beginPurge {
            Self.removeEntries(
                matchingAccountDigest: accountDigest,
                root: root,
                symmetricKey: symmetricKey
            )
        }
        await task.task.value
        finishPurge(task)
    }

    #if DEBUG
        func entryDirectory(for key: MessageMediaDiskCacheKey) -> URL? {
            try? Self.entryDirectory(for: key, root: directoryResolver())
        }
    #endif

    private func waitForActivePurge() async {
        if let task = activePurgeTask() {
            await task.value
        }
    }

    private func activePurgeTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return purgeTask
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func beginStore() -> StoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard purgeTask == nil else { return nil }
        return StoreHandle(generation: generation)
    }

    private func beginPurge(_ work: @escaping @Sendable () -> Void) -> PurgeHandle {
        lock.lock()
        generation += 1
        let activeGeneration = generation
        let task = Task.detached(priority: .utility) {
            work()
        }
        purgeTask = task
        purgeGeneration = activeGeneration
        lock.unlock()
        return PurgeHandle(task: task, generation: activeGeneration)
    }

    private func finishPurge(_ handle: PurgeHandle) {
        lock.lock()
        if purgeGeneration == handle.generation {
            purgeTask = nil
            purgeGeneration = nil
        }
        lock.unlock()
    }

    private func commitPreparedEntry(_ prepared: PreparedEntry, startGeneration: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard generation == startGeneration else {
            Self.discardPreparedEntry(prepared)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: prepared.finalDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: prepared.finalDirectory)
            try FileManager.default.moveItem(at: prepared.stagingDirectory, to: prepared.finalDirectory)
        } catch {
            try? FileManager.default.removeItem(at: prepared.stagingDirectory)
        }
    }

    private struct Metadata: Codable {
        let version: Int
        let accountDigest: String
        let ciphertextSha256: String
        let plaintextSha256: String
        let fileName: String
        let mediaType: String
        let sizeBytes: UInt64
        let cachedAtUnixSeconds: TimeInterval
    }

    private struct PreparedEntry {
        let root: URL
        let stagingDirectory: URL
        let finalDirectory: URL
    }

    private struct StoreHandle {
        let generation: Int
    }

    private struct PurgeHandle {
        let task: Task<Void, Never>
        let generation: Int
    }

    private static func readDownload(
        for key: MessageMediaDiskCacheKey,
        root: URL,
        symmetricKey: SymmetricKey
    ) -> MessageMediaDownload? {
        let entryDirectory = entryDirectory(for: key, root: root)
        let metadataURL = entryDirectory.appendingPathComponent(metadataFileName)
        let payloadURL = entryDirectory.appendingPathComponent(payloadFileName)

        do {
            let metadataData = try Data(contentsOf: metadataURL)
            let metadataPlaintext = try open(
                metadataData,
                using: symmetricKey,
                authenticatedBy: metadataAAD(for: key.cacheID)
            )
            let metadata = try JSONDecoder().decode(Metadata.self, from: metadataPlaintext)
            guard metadata.version == 1,
                metadata.accountDigest == key.accountDigest,
                metadata.ciphertextSha256 == key.ciphertextSha256,
                metadata.plaintextSha256 == key.plaintextSha256
            else {
                try? FileManager.default.removeItem(at: entryDirectory)
                return nil
            }

            let payloadData = try Data(contentsOf: payloadURL)
            let plaintext = try open(
                payloadData,
                using: symmetricKey,
                authenticatedBy: payloadAAD(for: key.cacheID)
            )
            // AES-GCM `open` above already authenticates the payload against its key
            // and AAD, so a full SHA-256 re-hash of the plaintext on every read would
            // be redundant tamper detection. Keep only the cheap length sanity check.
            guard UInt64(plaintext.count) == metadata.sizeBytes else {
                try? FileManager.default.removeItem(at: entryDirectory)
                return nil
            }

            return MessageMediaDownload(
                payload: DownloadedMediaPayload(id: key.payloadID, data: plaintext),
                fileName: metadata.fileName,
                mediaType: metadata.mediaType,
                sizeBytes: metadata.sizeBytes
            )
        } catch {
            if FileManager.default.fileExists(atPath: entryDirectory.path) {
                try? FileManager.default.removeItem(at: entryDirectory)
            }
            return nil
        }
    }

    private static func prepareStagedEntry(
        download: MessageMediaDownload,
        plaintext: Data,
        for key: MessageMediaDiskCacheKey,
        root: URL,
        symmetricKey: SymmetricKey
    ) -> PreparedEntry? {
        guard hexSHA256(plaintext) == key.plaintextSha256 else { return nil }

        let stagingDirectory =
            root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let finalDirectory = entryDirectory(for: key, root: root)
        let metadata = Metadata(
            version: 1,
            accountDigest: key.accountDigest,
            ciphertextSha256: key.ciphertextSha256,
            plaintextSha256: key.plaintextSha256,
            fileName: download.fileName,
            mediaType: download.mediaType,
            sizeBytes: download.sizeBytes,
            cachedAtUnixSeconds: Date().timeIntervalSince1970
        )

        do {
            try prepareDirectory(root)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

            let metadataPlaintext = try JSONEncoder().encode(metadata)
            let encryptedMetadata = try seal(
                metadataPlaintext,
                using: symmetricKey,
                authenticatedBy: metadataAAD(for: key.cacheID)
            )
            let encryptedPayload = try seal(
                plaintext,
                using: symmetricKey,
                authenticatedBy: payloadAAD(for: key.cacheID)
            )

            try encryptedMetadata.write(
                to: stagingDirectory.appendingPathComponent(metadataFileName),
                options: [.atomic, .completeFileProtection]
            )
            try encryptedPayload.write(
                to: stagingDirectory.appendingPathComponent(payloadFileName),
                options: [.atomic, .completeFileProtection]
            )
            return PreparedEntry(root: root, stagingDirectory: stagingDirectory, finalDirectory: finalDirectory)
        } catch {
            discardStagingDirectory(stagingDirectory, root: root)
            return nil
        }
    }

    private static func discardPreparedEntry(_ prepared: PreparedEntry) {
        discardStagingDirectory(prepared.stagingDirectory, root: prepared.root)
    }

    private static func discardStagingDirectory(_ stagingDirectory: URL, root: URL) {
        try? FileManager.default.removeItem(at: stagingDirectory)
        removeEmptyDirectory(stagingDirectory.deletingLastPathComponent())
        removeEmptyDirectory(root)
    }

    private static func removeEmptyDirectory(_ directory: URL) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            guard contents.isEmpty else { return }
            try FileManager.default.removeItem(at: directory)
        } catch {
            return
        }
    }

    private static func removeEntries(
        matchingAccountDigest accountDigest: String,
        root: URL,
        symmetricKey: SymmetricKey
    ) {
        guard
            let shardDirectories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for shardDirectory in shardDirectories where shardDirectory.lastPathComponent != "staging" {
            guard
                let entryDirectories = try? FileManager.default.contentsOfDirectory(
                    at: shardDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for entryDirectory in entryDirectories {
                let cacheID = entryDirectory.lastPathComponent
                let metadataURL = entryDirectory.appendingPathComponent(metadataFileName)
                guard let metadataData = try? Data(contentsOf: metadataURL),
                    let metadataPlaintext = try? open(
                        metadataData,
                        using: symmetricKey,
                        authenticatedBy: metadataAAD(for: cacheID)
                    ),
                    let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataPlaintext),
                    metadata.accountDigest == accountDigest
                else { continue }
                try? FileManager.default.removeItem(at: entryDirectory)
            }
        }
    }

    private static func prepareDirectory(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try rootURL.setResourceValues(values)
    }

    private static func entryDirectory(for key: MessageMediaDiskCacheKey, root: URL) -> URL {
        root
            .appendingPathComponent(String(key.cacheID.prefix(2)), isDirectory: true)
            .appendingPathComponent(key.cacheID, isDirectory: true)
    }

    private static func seal(
        _ data: Data,
        using key: SymmetricKey,
        authenticatedBy aad: Data
    ) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: aad).combined else {
            throw MessageMediaDiskCacheError.invalidSealedBox
        }
        return combined
    }

    private static func open(
        _ data: Data,
        using key: SymmetricKey,
        authenticatedBy aad: Data
    ) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    private static func metadataAAD(for cacheID: String) -> Data {
        Data("white-noise-media-cache-metadata-v1|\(cacheID)".utf8)
    }

    private static func payloadAAD(for cacheID: String) -> Data {
        Data("white-noise-media-cache-payload-v1|\(cacheID)".utf8)
    }

    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
