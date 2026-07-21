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
        Self.hexDigest("media-cache-v1", accountId, groupIdHex, ciphertextSha256, plaintextSha256)
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

private actor MessageMediaDiskCacheStagingCoordinator {
    func perform(_ operation: @Sendable () -> Void) {
        operation()
    }
}

nonisolated final class MessageMediaDiskCache: @unchecked Sendable {
    typealias DirectoryResolver = @Sendable () throws -> URL
    typealias KeyProvider = @Sendable () throws -> SymmetricKey
    typealias KeyDeleter = @Sendable () -> Void
    typealias TimestampProvider = @Sendable () -> TimeInterval

    struct EvictionPolicy: Sendable {
        static let standard = EvictionPolicy(
            maxEntryCount: 2_048,
            maxTotalBytes: 512 * 1024 * 1024
        )

        let maxEntryCount: Int
        // Filesystem footprint cap for encrypted cache records. Uses allocated bytes when
        // available so sparse/block-rounded files count the way they affect Application Support.
        let maxTotalBytes: UInt64

        init(maxEntryCount: Int, maxTotalBytes: UInt64) {
            // Keep the policy total: a zero entry cap is meaningful for tests and callers that
            // want every stored record evicted immediately.
            self.maxEntryCount = Swift.max(0, maxEntryCount)
            self.maxTotalBytes = maxTotalBytes
        }
    }

    static let shared = MessageMediaDiskCache()

    private static let directoryName = "WhiteNoiseMediaCache"
    private static let versionDirectoryName = "v1"
    private static let metadataFileName = "metadata.bin"
    private static let payloadFileName = "payload.bin"

    private let directoryResolver: DirectoryResolver
    private let keyProvider: KeyProvider
    private let keyDeleter: KeyDeleter
    // Keychain reads are synchronous XPC calls. Keep the immutable session key in memory and
    // serialize first resolution with deletion so a concurrent purge cannot leave a stale key.
    private let keyLock = NSLock()
    private var cachedSymmetricKey: SymmetricKey?
    private let timestampProvider: TimestampProvider
    private let evictionPolicy: EvictionPolicy
    // Preparation and commit share one actor-isolated synchronous operation so at most one full
    // encrypted payload is present in `staging/` per cache instance. This bounds the temporary
    // disk spike without putting encryption or file writes back on the read/purge bookkeeping lock.
    private let stagingCoordinator = MessageMediaDiskCacheStagingCoordinator()
    // Staging directories older than this cache instance were left by a previous process and
    // are safe to discard; same-session staging may still be an in-flight store.
    private let sessionStartedAtUnixSeconds: TimeInterval
    private let lock = NSLock()
    // Serializes the filesystem create/remove/move work of commits and purges so a slow
    // commit never blocks generation reads or purge bookkeeping (which stay on `lock`).
    // A commit holds this lock while it re-reads the scoped generation and moves the final
    // entry into place; a purge holds it while it deletes on disk. Because `beginPurge()`
    // advances the relevant generation under `lock` before its filesystem work runs, a
    // commit that observes an unchanged generation while holding this lock is guaranteed no
    // purge deletion for that entry can interleave with its move, so an older store can never
    // resurrect a purged entry. Per-account purges intentionally do not invalidate unrelated
    // account generations, but they are still serialized through this same lock so filesystem
    // moves/removes cannot interleave.
    private let fileMutationLock = NSLock()
    private var globalGeneration = 0
    // Demand-created per-account counters are pruned on full-cache wipes; the global generation
    // bump invalidates any stale handles that captured the older per-account values.
    private var accountGenerations: [String: Int] = [:]
    private var purgeSequence = 0
    private var purgeTasks: [Int: ActivePurge] = [:]
    private var didSweepStagingDirectories = false
    #if DEBUG
        private var testingBeforeRemoveStaleStagingDirectories: (@Sendable () -> Void)?
        private var testingBeforePreparedEntryMove: (@Sendable () throws -> Void)?
    #endif
    // Updated under `fileMutationLock` on commit and eviction. Tracks committed entries only;
    // live staging bytes are sampled separately when enforcing the byte cap.
    // Invalidated when read-path deletions or account purges remove an unknown subset.
    // Seeded with one full scan when nil so stores under the cap avoid re-walking the tree every time (#377).
    private var trackedFootprint: CacheFootprint?

    init(
        directoryResolver: @escaping DirectoryResolver = MessageMediaDiskCache.defaultDirectoryURL,
        keyProvider: @escaping KeyProvider = MessageMediaDiskCacheKeychain.symmetricKey,
        keyDeleter: @escaping KeyDeleter = MessageMediaDiskCacheKeychain.deleteKey,
        timestampProvider: @escaping TimestampProvider = { Date().timeIntervalSince1970 },
        evictionPolicy: EvictionPolicy = .standard,
        sessionStartedAtUnixSeconds: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.directoryResolver = directoryResolver
        self.keyProvider = keyProvider
        self.keyDeleter = keyDeleter
        self.timestampProvider = timestampProvider
        self.evictionPolicy = evictionPolicy
        self.sessionStartedAtUnixSeconds = sessionStartedAtUnixSeconds
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
        await waitForActivePurge(affecting: key.accountDigest)
        guard let start = beginAccess(for: key.accountDigest) else { return nil }

        let root: URL
        let symmetricKey: SymmetricKey
        do {
            root = try directoryResolver()
        } catch {
            return nil
        }
        sweepStaleStagingDirectoriesIfNeeded(root: root)
        do {
            symmetricKey = try encryptionKey()
        } catch {
            return nil
        }

        let result = await Task.detached(priority: .utility) { [self] in
            readDownload(for: key, root: root, symmetricKey: symmetricKey, start: start)
        }.value

        guard isCurrent(start) else { return nil }
        return result
    }

    func store(_ download: MessageMediaDownload, for key: MessageMediaDiskCacheKey) async {
        // #236: atomically reject the store if a wipe/purge affecting this entry is in flight —
        // `beginAccess(for:)` returns nil under a matching active purge, so we never resurrect the
        // cache root after the key has been (or is about to be) deleted. #230: also honor
        // cooperative cancellation so a store whose owning WorkspaceState task is cancelled
        // mid-flight (account purge) bails and cleans up its staging rather than committing late.
        // `start` is the scoped generation snapshot taken under the lock by `beginAccess(for:)`.
        guard let start = beginAccess(for: key.accountDigest) else { return }
        guard !Task.isCancelled else { return }

        let root: URL
        do {
            root = try directoryResolver()
        } catch {
            return
        }
        sweepStaleStagingDirectoriesIfNeeded(root: root)
        guard !Task.isCancelled, isCurrent(start) else { return }

        let plaintext = download.payload.data
        await stagingCoordinator.perform { [self] in
            guard !Task.isCancelled, isCurrent(start) else { return }

            let symmetricKey: SymmetricKey
            do {
                symmetricKey = try encryptionKey()
            } catch {
                return
            }
            guard !Task.isCancelled, isCurrent(start) else { return }

            guard
                let prepared = Self.prepareStagedEntry(
                    download: download,
                    plaintext: plaintext,
                    for: key,
                    root: root,
                    symmetricKey: symmetricKey,
                    cachedAtUnixSeconds: timestampProvider()
                )
            else { return }

            guard !Task.isCancelled else {
                Self.discardPreparedEntry(prepared)
                return
            }
            commitPreparedEntry(prepared, start: start)
        }
    }

    func purgeAll(removeEncryptionKey: Bool = false) async {
        let root = try? directoryResolver()
        let task = beginPurge(scope: .all) { [self] in
            var removalSucceeded = root != nil
            if let root, FileManager.default.fileExists(atPath: root.path) {
                do {
                    try FileManager.default.removeItem(at: root)
                } catch {
                    removalSucceeded = false
                }
            }
            if removeEncryptionKey {
                deleteEncryptionKey()
            }
            // An unresolved root or a failed removal can leave entries on disk — a zero footprint
            // would be a false zero the incremental accountant never reconciles, so nil it instead
            // to force a re-seed.
            trackedFootprint = removalSucceeded ? CacheFootprint(entryCount: 0, byteCount: 0) : nil
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
        } catch {
            return
        }
        sweepStaleStagingDirectoriesIfNeeded(root: root)
        do {
            symmetricKey = try encryptionKey()
        } catch {
            return
        }

        let accountDigest = MessageMediaDiskCacheKey.accountDigest(for: accountId)
        let task = beginPurge(scope: .account(accountDigest)) { [self] in
            Self.removeEntries(
                matchingAccountDigest: accountDigest,
                root: root,
                symmetricKey: symmetricKey
            )
            // Keep account matching separate from corrupt-entry reclamation. The first
            // pass only removes entries it can attribute to the target account; this
            // second pass is account-agnostic and deletes entries no account can read.
            Self.removeUnreadableEntries(root: root, symmetricKey: symmetricKey)
            // Account purges remove an arbitrary subset of entries. Re-seed lazily on the next store.
            trackedFootprint = nil
        }
        await task.task.value
        finishPurge(task)
    }

    #if DEBUG
        func entryDirectory(for key: MessageMediaDiskCacheKey) -> URL? {
            try? Self.entryDirectory(for: key, root: directoryResolver())
        }

        func testingWithFileMutationLock(_ operation: () -> Void) {
            fileMutationLock.lock()
            defer { fileMutationLock.unlock() }
            operation()
        }

        func testingSetBeforeStagingSweepHook(_ hook: @escaping @Sendable () -> Void) {
            testingBeforeRemoveStaleStagingDirectories = hook
        }

        func testingSetBeforePreparedEntryMoveHook(_ hook: @escaping @Sendable () throws -> Void) {
            testingBeforePreparedEntryMove = hook
        }

        func testingTrackedFootprintIsInitialized() -> Bool {
            fileMutationLock.withLock { trackedFootprint != nil }
        }
    #endif

    private func encryptionKey() throws -> SymmetricKey {
        try keyLock.withLock {
            if let cachedSymmetricKey {
                return cachedSymmetricKey
            }
            let symmetricKey = try keyProvider()
            cachedSymmetricKey = symmetricKey
            return symmetricKey
        }
    }

    private func deleteEncryptionKey() {
        keyLock.withLock {
            keyDeleter()
            cachedSymmetricKey = nil
        }
    }

    private func waitForActivePurge(affecting accountDigest: String? = nil) async {
        while true {
            let purges = activePurgeTasks(affecting: accountDigest)
            guard !purges.isEmpty else { return }
            for purge in purges {
                await purge.task.value
                finishPurge(purge)
            }
        }
    }

    private func activePurgeTasks(affecting accountDigest: String?) -> [PurgeHandle] {
        lock.lock()
        defer { lock.unlock() }
        return purgeTasks.compactMap { entry in
            let sequence = entry.key
            let purge = entry.value
            if let accountDigest, !purge.scope.affects(accountDigest: accountDigest) {
                return nil
            }
            return PurgeHandle(task: purge.task, sequence: sequence)
        }
    }

    private func beginAccess(for accountDigest: String) -> AccessHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasActivePurgeAffecting(accountDigest: accountDigest) else { return nil }
        return AccessHandle(
            accountDigest: accountDigest,
            globalGeneration: globalGeneration,
            accountGeneration: accountGenerations[accountDigest, default: 0]
        )
    }

    private func sweepStaleStagingDirectoriesIfNeeded(root: URL) {
        lock.lock()
        if didSweepStagingDirectories {
            lock.unlock()
            return
        }
        lock.unlock()

        fileMutationLock.lock()
        defer { fileMutationLock.unlock() }

        lock.lock()
        if didSweepStagingDirectories {
            lock.unlock()
            return
        }
        let cutoff = sessionStartedAtUnixSeconds
        lock.unlock()

        #if DEBUG
            testingBeforeRemoveStaleStagingDirectories?()
        #endif
        Self.removeStaleStagingDirectories(root: root, olderThanUnixSeconds: cutoff)

        lock.lock()
        didSweepStagingDirectories = true
        lock.unlock()
    }

    private func beginPurge(scope: PurgeScope, _ work: @escaping @Sendable () -> Void) -> PurgeHandle {
        lock.lock()
        advanceGeneration(for: scope)
        purgeSequence += 1
        let sequence = purgeSequence
        let fileMutationLock = self.fileMutationLock
        let task = Task.detached(priority: .utility) {
            fileMutationLock.lock()
            defer { fileMutationLock.unlock() }
            work()
        }
        purgeTasks[sequence] = ActivePurge(task: task, scope: scope)
        lock.unlock()
        return PurgeHandle(task: task, sequence: sequence)
    }

    private func finishPurge(_ handle: PurgeHandle) {
        lock.lock()
        purgeTasks[handle.sequence] = nil
        lock.unlock()
    }

    private func advanceGeneration(for scope: PurgeScope) {
        switch scope {
        case .all:
            globalGeneration += 1
            accountGenerations.removeAll(keepingCapacity: true)
        case .account(let accountDigest):
            accountGenerations[accountDigest, default: 0] += 1
        }
    }

    private func isCurrent(_ handle: AccessHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return globalGeneration == handle.globalGeneration
            && accountGenerations[handle.accountDigest, default: 0] == handle.accountGeneration
    }

    private func hasActivePurgeAffecting(accountDigest: String) -> Bool {
        purgeTasks.values.contains { $0.scope.affects(accountDigest: accountDigest) }
    }

    private func commitPreparedEntry(
        _ prepared: PreparedEntry,
        start: AccessHandle
    ) {
        // Hold only the narrow filesystem-mutation lock across the slow create/remove/move
        // so generation reads and purge bookkeeping (on `lock`) never block on this commit.
        // The scoped generation re-check happens under `fileMutationLock`: a purge advances
        // the relevant generation under `lock` before acquiring `fileMutationLock` for its
        // deletion, so an unchanged generation observed here means no matching purge deletion
        // can interleave.
        fileMutationLock.lock()
        defer { fileMutationLock.unlock() }

        guard isCurrent(start) else {
            Self.discardPreparedEntry(prepared)
            return
        }

        let isReplacement = FileManager.default.fileExists(atPath: prepared.finalDirectory.path)
        let replacedByteCount =
            isReplacement
            ? Self.entryByteCount(at: prepared.finalDirectory)
            : 0
        let committedByteCount = Self.entryByteCount(at: prepared.stagingDirectory)
        var replacementBackup: URL?

        do {
            try FileManager.default.createDirectory(
                at: prepared.finalDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if isReplacement {
                let backup =
                    prepared.stagingDirectory.deletingLastPathComponent()
                    .appendingPathComponent("replacement-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.moveItem(at: prepared.finalDirectory, to: backup)
                replacementBackup = backup
            }
            #if DEBUG
                try testingBeforePreparedEntryMove?()
            #endif
            try FileManager.default.moveItem(at: prepared.stagingDirectory, to: prepared.finalDirectory)
            if let replacementBackup {
                try FileManager.default.removeItem(at: replacementBackup)
                Self.removeEmptyDirectory(replacementBackup.deletingLastPathComponent())
            }
            updateTrackedFootprintAfterCommit(
                isNewEntry: !isReplacement,
                committedByteCount: committedByteCount,
                replacedByteCount: replacedByteCount,
                root: prepared.root
            )
            enforceEvictionPolicy(root: prepared.root)
        } catch {
            Self.discardPreparedEntry(prepared)
            if let replacementBackup,
                FileManager.default.fileExists(atPath: replacementBackup.path)
            {
                if FileManager.default.fileExists(atPath: prepared.finalDirectory.path) {
                    try? FileManager.default.removeItem(at: replacementBackup)
                } else {
                    try? FileManager.default.moveItem(at: replacementBackup, to: prepared.finalDirectory)
                }
                Self.removeEmptyDirectory(replacementBackup.deletingLastPathComponent())
            }
            // Any failed filesystem sequence may have removed, restored, or partially committed
            // an entry. Force the next store to reconcile from disk instead of carrying a false
            // byte/entry count forward.
            trackedFootprint = nil
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

    private enum PurgeScope {
        case all
        case account(String)

        func affects(accountDigest: String) -> Bool {
            switch self {
            case .all:
                return true
            case .account(let purgedAccountDigest):
                return purgedAccountDigest == accountDigest
            }
        }
    }

    private struct AccessHandle: Sendable {
        let accountDigest: String
        let globalGeneration: Int
        let accountGeneration: Int
    }

    private struct ActivePurge {
        let task: Task<Void, Never>
        let scope: PurgeScope
    }

    private struct PurgeHandle {
        let task: Task<Void, Never>
        let sequence: Int
    }

    private struct CacheEntry {
        let directory: URL
        let cachedAtUnixSeconds: TimeInterval
        let byteCount: UInt64
    }

    private struct CacheFootprint {
        var entryCount: Int
        var byteCount: UInt64
    }

    private struct CacheScan {
        let removableEntries: [CacheEntry]
        let committedFootprint: CacheFootprint
        let stagingByteCount: UInt64
    }

    private enum MetadataStatus {
        case readable(Metadata)
        case corrupt
        case unavailable
    }

    private func readDownload(
        for key: MessageMediaDiskCacheKey,
        root: URL,
        symmetricKey: SymmetricKey,
        start: AccessHandle
    ) -> MessageMediaDownload? {
        let entryDirectory = Self.entryDirectory(for: key, root: root)
        let metadataURL = entryDirectory.appendingPathComponent(Self.metadataFileName)
        let payloadURL = entryDirectory.appendingPathComponent(Self.payloadFileName)

        let metadataData: Data
        do {
            metadataData = try Data(contentsOf: metadataURL)
        } catch {
            // A raw filesystem read failure may be transient; preserve the entry
            // just like the purge path's `.unavailable` metadata status.
            return nil
        }

        let metadata: Metadata
        do {
            let metadataPlaintext = try Self.open(
                metadataData,
                using: symmetricKey,
                authenticatedBy: Self.metadataAAD(for: key.cacheID)
            )
            metadata = try JSONDecoder().decode(Metadata.self, from: metadataPlaintext)
        } catch {
            removeEntryAfterFailedRead(entryDirectory: entryDirectory, root: root, start: start)
            return nil
        }
        guard metadata.version == 1,
            metadata.accountDigest == key.accountDigest,
            metadata.ciphertextSha256 == key.ciphertextSha256,
            metadata.plaintextSha256 == key.plaintextSha256
        else {
            removeEntryAfterFailedRead(entryDirectory: entryDirectory, root: root, start: start)
            return nil
        }

        let payloadData: Data
        do {
            payloadData = try Data(contentsOf: payloadURL)
        } catch {
            // A raw payload filesystem read failure may be transient; keep the entry
            // until decrypt/auth failure proves the payload is corrupt.
            return nil
        }

        do {
            let plaintext = try Self.open(
                payloadData,
                using: symmetricKey,
                authenticatedBy: Self.payloadAAD(for: key.cacheID)
            )
            // AES-GCM `open` above already authenticates the payload against its key and
            // AAD, and the store path verifies the plaintext SHA-256 before writing, so the
            // bytes on disk are cryptographically bound to this entry. `metadata.sizeBytes`
            // is the FFI-reported size, which is not guaranteed to equal the decrypted
            // length (e.g. a declared imeta size); comparing them here would self-delete a
            // valid entry on every read whenever they diverge (#313), so we don't.

            return MessageMediaDownload(
                payload: DownloadedMediaPayload(id: key.payloadID, data: plaintext),
                fileName: metadata.fileName,
                mediaType: metadata.mediaType,
                sizeBytes: metadata.sizeBytes
            )
        } catch {
            removeEntryAfterFailedRead(entryDirectory: entryDirectory, root: root, start: start)
            return nil
        }
    }

    private func removeEntryAfterFailedRead(entryDirectory: URL, root: URL, start: AccessHandle) {
        fileMutationLock.lock()
        defer { fileMutationLock.unlock() }

        guard isCurrent(start), FileManager.default.fileExists(atPath: entryDirectory.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: entryDirectory)
            // The read path can delete entries whose on-disk bytes may already have diverged
            // from the tracked accountant (corruption, cache-buster metadata mismatch). Match
            // account purges by invalidating and letting the next store re-seed from disk.
            trackedFootprint = nil
            Self.removeEmptyDirectory(entryDirectory.deletingLastPathComponent())
            Self.removeEmptyDirectory(root)
        } catch {
            return
        }
    }

    private static func prepareStagedEntry(
        download: MessageMediaDownload,
        plaintext: Data,
        for key: MessageMediaDiskCacheKey,
        root: URL,
        symmetricKey: SymmetricKey,
        cachedAtUnixSeconds: TimeInterval
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
            cachedAtUnixSeconds: cachedAtUnixSeconds
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
            // Persist eviction ordering outside the sealed metadata. Reads do not change a
            // directory's modification date, and moving the staged directory preserves it.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: cachedAtUnixSeconds)],
                ofItemAtPath: stagingDirectory.path
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

    private static func removeStaleStagingDirectories(root: URL, olderThanUnixSeconds cutoff: TimeInterval) {
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        guard
            let stagingDirectories = try? FileManager.default.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for stagingDirectory in stagingDirectories {
            guard isDirectory(stagingDirectory),
                isStaleStagingDirectory(stagingDirectory, olderThanUnixSeconds: cutoff)
            else { continue }
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        removeEmptyDirectory(stagingRoot)
        removeEmptyDirectory(root)
    }

    private static func isStaleStagingDirectory(_ directory: URL, olderThanUnixSeconds cutoff: TimeInterval) -> Bool {
        guard
            let values = try? directory.resourceValues(forKeys: [
                .contentModificationDateKey,
                .creationDateKey,
            ])
        else {
            return true
        }
        guard let modifiedAt = values.contentModificationDate ?? values.creationDate else {
            return true
        }
        return modifiedAt.timeIntervalSince1970 < cutoff
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

            for entryDirectory in entryDirectories where isDirectory(entryDirectory) {
                guard
                    case .readable(let metadata) = metadataStatus(
                        in: entryDirectory,
                        symmetricKey: symmetricKey
                    )
                else {
                    // A per-account purge cannot prove an unreadable entry belongs to the
                    // target account. Skip it here; the account-agnostic cleanup pass owns
                    // corrupt-entry reclamation.
                    continue
                }
                if metadata.accountDigest == accountDigest {
                    try? FileManager.default.removeItem(at: entryDirectory)
                    removeEmptyDirectory(shardDirectory)
                }
            }
        }
    }

    private static func removeUnreadableEntries(root: URL, symmetricKey: SymmetricKey) {
        guard
            let shardDirectories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for shardDirectory in shardDirectories where shardDirectory.lastPathComponent != "staging" {
            guard isDirectory(shardDirectory),
                let entryDirectories = try? FileManager.default.contentsOfDirectory(
                    at: shardDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for entryDirectory in entryDirectories where isDirectory(entryDirectory) {
                guard case .corrupt = metadataStatus(in: entryDirectory, symmetricKey: symmetricKey) else {
                    continue
                }
                try? FileManager.default.removeItem(at: entryDirectory)
                removeEmptyDirectory(shardDirectory)
            }
        }
        removeEmptyDirectory(root)
    }

    private static func metadataStatus(in entryDirectory: URL, symmetricKey: SymmetricKey) -> MetadataStatus {
        let cacheID = entryDirectory.lastPathComponent
        let metadataURL = entryDirectory.appendingPathComponent(metadataFileName)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return .corrupt }

        let metadataData: Data
        do {
            metadataData = try Data(contentsOf: metadataURL)
        } catch {
            // Do not reclaim entries whose metadata could not be read at all; a transient
            // filesystem read failure is exactly what the per-account purge must not turn
            // into collateral deletion.
            return .unavailable
        }

        guard
            let metadataPlaintext = try? open(
                metadataData,
                using: symmetricKey,
                authenticatedBy: metadataAAD(for: cacheID)
            ),
            let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataPlaintext)
        else { return .corrupt }
        guard metadata.version == 1 else {
            // A decryptable, decodable record with a different version may belong to a
            // newer cache format. Skip it instead of reclaiming it account-agnostically.
            return .unavailable
        }
        return .readable(metadata)
    }

    private func updateTrackedFootprintAfterCommit(
        isNewEntry: Bool,
        committedByteCount: UInt64,
        replacedByteCount: UInt64,
        root: URL
    ) {
        if trackedFootprint == nil {
            trackedFootprint = Self.committedFootprint(root: root)
            return
        }

        let tracked = trackedFootprint!
        let entryCount = isNewEntry ? tracked.entryCount + 1 : tracked.entryCount
        let withoutReplaced =
            tracked.byteCount > replacedByteCount ? tracked.byteCount - replacedByteCount : 0
        trackedFootprint = CacheFootprint(
            entryCount: entryCount,
            byteCount: Self.addingWithSaturation(withoutReplaced, committedByteCount)
        )
    }

    private func enforceEvictionPolicy(root: URL) {
        guard let tracked = trackedFootprint else { return }
        let trackedTotalBytes = Self.addingWithSaturation(
            tracked.byteCount,
            Self.stagingByteCount(root: root)
        )
        guard
            tracked.entryCount > evictionPolicy.maxEntryCount
                || trackedTotalBytes > evictionPolicy.maxTotalBytes
        else { return }

        let scan = Self.cacheScan(root: root)
        var entries = scan.removableEntries
        var committedBytes = scan.committedFootprint.byteCount
        var totalBytes = Self.addingWithSaturation(committedBytes, scan.stagingByteCount)
        var remainingCount = scan.committedFootprint.entryCount

        guard remainingCount > evictionPolicy.maxEntryCount || totalBytes > evictionPolicy.maxTotalBytes
        else {
            trackedFootprint = CacheFootprint(entryCount: remainingCount, byteCount: committedBytes)
            return
        }

        entries.sort {
            if $0.cachedAtUnixSeconds == $1.cachedAtUnixSeconds {
                return $0.directory.path < $1.directory.path
            }
            return $0.cachedAtUnixSeconds < $1.cachedAtUnixSeconds
        }

        for entry in entries {
            guard
                remainingCount > evictionPolicy.maxEntryCount
                    || totalBytes > evictionPolicy.maxTotalBytes
            else { break }

            do {
                try FileManager.default.removeItem(at: entry.directory)
                remainingCount -= 1
                committedBytes = committedBytes > entry.byteCount ? committedBytes - entry.byteCount : 0
                totalBytes = totalBytes > entry.byteCount ? totalBytes - entry.byteCount : 0
                Self.removeEmptyDirectory(entry.directory.deletingLastPathComponent())
            } catch {
                continue
            }
        }
        Self.removeEmptyDirectory(root)
        // Staging bytes are live, temporary disk usage rather than committed cache entries.
        // Keep the incremental accountant committed-only so each staging directory is counted
        // exactly once when a later commit moves it into place.
        trackedFootprint = CacheFootprint(entryCount: remainingCount, byteCount: committedBytes)
    }

    private static func committedFootprint(root: URL) -> CacheFootprint {
        guard
            let shardDirectories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return CacheFootprint(entryCount: 0, byteCount: 0) }

        var entryCount = 0
        var byteCount: UInt64 = 0
        for shardDirectory in shardDirectories where shardDirectory.lastPathComponent != "staging" {
            guard isDirectory(shardDirectory),
                let entryDirectories = try? FileManager.default.contentsOfDirectory(
                    at: shardDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for entryDirectory in entryDirectories where isDirectory(entryDirectory) {
                entryCount += 1
                byteCount = addingWithSaturation(byteCount, entryByteCount(at: entryDirectory))
            }
        }
        return CacheFootprint(entryCount: entryCount, byteCount: byteCount)
    }

    private static func cacheScan(root: URL) -> CacheScan {
        let stagedBytes = stagingByteCount(root: root)
        guard
            let shardDirectories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return CacheScan(
                removableEntries: [],
                committedFootprint: CacheFootprint(entryCount: 0, byteCount: 0),
                stagingByteCount: stagedBytes
            )
        }

        var entries: [CacheEntry] = []
        var entryCount = 0
        var byteCount: UInt64 = 0
        for shardDirectory in shardDirectories where shardDirectory.lastPathComponent != "staging" {
            guard isDirectory(shardDirectory),
                let entryDirectories = try? FileManager.default.contentsOfDirectory(
                    at: shardDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for entryDirectory in entryDirectories where isDirectory(entryDirectory) {
                let entryByteCount = entryByteCount(at: entryDirectory)
                let cachedAtUnixSeconds = evictionTimestamp(for: entryDirectory)
                entryCount += 1
                byteCount = addingWithSaturation(byteCount, entryByteCount)

                entries.append(
                    CacheEntry(
                        directory: entryDirectory,
                        cachedAtUnixSeconds: cachedAtUnixSeconds,
                        byteCount: entryByteCount
                    )
                )
            }
        }
        return CacheScan(
            removableEntries: entries,
            committedFootprint: CacheFootprint(entryCount: entryCount, byteCount: byteCount),
            stagingByteCount: stagedBytes
        )
    }

    private static func evictionTimestamp(for entryDirectory: URL) -> TimeInterval {
        let metadataURL = entryDirectory.appendingPathComponent(metadataFileName)
        guard
            (try? metadataURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            let modifiedAt = try? entryDirectory.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        else {
            // Entries without a normal metadata file or readable timestamp are disposable under
            // pressure. Reclaim them before entries with known ordering.
            return -Double.infinity
        }
        return modifiedAt.timeIntervalSince1970
    }

    private static func stagingByteCount(root: URL) -> UInt64 {
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        guard
            let stagingDirectories = try? FileManager.default.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        return stagingDirectories.reduce(into: UInt64(0)) { byteCount, stagingDirectory in
            guard isDirectory(stagingDirectory) else { return }
            byteCount = addingWithSaturation(byteCount, entryByteCount(at: stagingDirectory))
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func entryByteCount(at entryDirectory: URL) -> UInt64 {
        addingWithSaturation(
            fileByteCount(at: entryDirectory.appendingPathComponent(metadataFileName)),
            fileByteCount(at: entryDirectory.appendingPathComponent(payloadFileName))
        )
    }

    private static func fileByteCount(at url: URL) -> UInt64 {
        guard
            let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ])
        else { return 0 }

        let byteCount = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        return UInt64(Swift.max(0, byteCount))
    }

    private static func addingWithSaturation(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
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
