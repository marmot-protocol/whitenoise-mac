//
//  NamecoinResolver.swift
//  whitenoise-mac
//
//  The Namecoin `.bit` NIP-05 resolver: `alice@example.bit`, `example.bit`,
//  `d/example`, `id/alice` → Nostr pubkey hex, over the pinned ElectrumX
//  servers. Same closed loop the NIP-05 HTTP verifier serves for DNS names,
//  but over Namecoin's censorship-resistant name index (no DNS, no TLS CA).
//
//  Ported from whitenoise-linux `app/namecoin.odin` (commit 79447095f2).
//
//  ── TRUST MODEL ──────────────────────────────────────────────────────────
//
//  This resolver TRUSTS the pinned ElectrumX operators it talks to. It asks
//  the server for the latest transaction outputs bound to the name's
//  scripthash and reads the `nostr` field out of the value payload. It does
//  NOT verify:
//
//    * that the returned transaction is included in the best Namecoin chain
//      (no SPV proof, no block-header chain check),
//    * that the returned transaction actually spends into the claimed
//      scripthash on-chain (only that the server labelled it so in the
//      history response),
//    * that any of the servers agree with each other (no cross-server
//      quorum: the first Resolved wins).
//
//  A dishonest, compromised, or MITM'd ElectrumX server can therefore return
//  a fabricated name → pubkey binding. TLS leaf-pubkey pinning (see
//  ElectrumXTransport.swift) rules out network-path MITM against the pinned
//  servers, but does not rule out the operator themselves lying. This matches
//  the trust posture of the linux implementation and the parallel Kotlin /
//  TS resolvers; bundled SPV verification or dispatch to a local `namecoind`
//  is the planned follow-up. Script-hash derivation is computed locally, and
//  ambiguous records fail closed (see NamecoinRecord.swift).
//
//  ── ASYNC MODEL ─────────────────────────────────────────────────────────
//
//  The Odin original runs a worker pool plus a pending-intent queue drained
//  by the frame loop. Here Swift concurrency replaces both: each lookup is a
//  structured task, duplicate in-flight lookups for the same identifier
//  share one network round via the inflight map, and the workspace's
//  existing generation guards (account-switch / chat-switch freshness
//  checks) supply the drop-stale-intent semantics the pending queue carried.
//  Resolution happens off the UI thread by construction; the UI awaits.
//

import Foundation

/// Resolution failure surfaced to the UI. `.notFound` carries the identifier the user
/// typed so the error line can name it.
nonisolated enum NamecoinResolutionError: Error, Equatable {
    /// Not a Namecoin identifier after all (callers gate on `NamecoinIdentifier.isBit`
    /// first, so this should be unreachable in practice).
    case invalidIdentifier
    /// The name definitively does not resolve: no history, expired, or a record that
    /// fails the fail-closed extraction rules.
    case notFound(String)
    /// Every pinned server failed at the transport layer. Retryable; never cached.
    case unavailable
}

nonisolated protocol NamecoinResolving: Sendable {
    /// Resolve a `.bit` / `d/` / `id/` identifier to a 64-character lowercase hex pubkey
    /// suitable as a marmot member ref. Throws `NamecoinResolutionError`.
    func accountReference(for identifier: String) async throws -> String
}

nonisolated struct NamecoinResolver: NamecoinResolving {
    /// A name whose last update is this many blocks behind the tip is treated as expired.
    /// Matches `NC_NAME_EXPIRE_DEPTH` upstream.
    static let nameExpireDepth = 36_000
    /// Bound the whole lookup, including hedged attempts and import expansion. Individual
    /// transports have shorter I/O deadlines; this is the last-resort budget for the resolver.
    static let overallTimeout: Duration = .seconds(20)
    /// Quartz 2.13-style staggered hedging: one immediate attempt, then one every 1.5s.
    static let hedgeDelay: Duration = .milliseconds(1_500)
    /// A fast definitive miss must not beat a positive already in flight on another server.
    static let negativeGrace: Duration = .milliseconds(1_500)

    private let transport: any ElectrumXTransporting
    private let servers: [NamecoinServer]
    private let cache = ResolutionCache()

    init(
        transport: any ElectrumXTransporting = ElectrumXTransport(),
        servers: [NamecoinServer] = .namecoinDefaultPinned
    ) {
        self.transport = transport
        self.servers = servers
    }

    func accountReference(for identifier: String) async throws -> String {
        guard let parsed = NamecoinIdentifier.parse(identifier) else {
            throw NamecoinResolutionError.invalidIdentifier
        }
        let key = NamecoinIdentifier.normalize(identifier)
        if let cached = await cache.cachedValue(for: key) {
            switch cached {
            case .resolved(let pubkeyHex):
                return pubkeyHex
            case .notFound:
                throw NamecoinResolutionError.notFound(identifier)
            }
        }

        // Duplicate in-flight lookups for the same identifier share one network round —
        // the upstream `nc_inflight` dedup. Structured concurrency replaces the worker
        // pool: the shared task IS the worker.
        let task = await cache.sharedTask(for: key) { [transport, servers] in
            try await Self.lookupWithTimeout(parsed: parsed, transport: transport, servers: servers)
        }
        defer {
            Task { await cache.clearInflight(for: key) }
        }

        do {
            let pubkeyHex = try await task.value
            await cache.storePositive(pubkeyHex, for: key)
            return pubkeyHex
        } catch let error as NamecoinResolutionError {
            // Only definitive outcomes are cached: not-found is a settled fact about the
            // chain; unavailable is retryable and must never latch.
            if case .notFound = error {
                await cache.storeNegative(for: key)
                // Surface the identifier the user actually typed (the lookup pipeline
                // works with the derived d/ name, which means nothing to them) — the UI
                // error message names this value.
                throw NamecoinResolutionError.notFound(identifier)
            }
            throw error
        }
    }

    // MARK: - Lookup pipeline

    private static func lookupWithTimeout(
        parsed: NamecoinParsedIdentifier,
        transport: any ElectrumXTransporting,
        servers: [NamecoinServer]
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await lookup(parsed: parsed, transport: transport, servers: servers)
            }
            group.addTask {
                try await Task.sleep(for: overallTimeout)
                throw NamecoinResolutionError.unavailable
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NamecoinResolutionError.unavailable
            }
            return result
        }
    }

    /// name → value JSON → import expansion → fail-closed nostr extraction → pubkey hex.
    private static func lookup(
        parsed: NamecoinParsedIdentifier,
        transport: any ElectrumXTransporting,
        servers: [NamecoinServer]
    ) async throws -> String {
        try Task.checkCancellation()
        let identifier = parsed.namecoinName
        switch await nameShowWithFallback(name: identifier, servers: servers, transport: transport) {
        case .unavailable:
            throw NamecoinResolutionError.unavailable
        case .notFound:
            throw NamecoinResolutionError.notFound(identifier)
        case .resolved(let valueJSON):
            // Walk the ifa-0001 `import` chain. Sub-import unavailability collapses to
            // "empty imported object" — only the root's availability drives the tri-state.
            let merged = await NamecoinRecord.resolveValueWithImports(valueJSON) { importName in
                guard
                    case .resolved(let raw) = await nameShowWithFallback(
                        name: importName,
                        servers: servers,
                        transport: transport
                    )
                else { return nil }
                return NamecoinRecord.jsonObject(raw)
            }
            guard let merged else {
                throw NamecoinResolutionError.notFound(identifier)
            }
            switch NamecoinRecord.extractNostr(from: merged, parsed: parsed) {
            case .resolved(let resolution):
                return resolution.pubkeyHex
            case .notFound:
                throw NamecoinResolutionError.notFound(identifier)
            case .unavailable:
                // Extraction never produces this; the case exists for the enum's
                // exhaustiveness at the transport boundary.
                throw NamecoinResolutionError.unavailable
            }
        }
    }

    /// Per-server result for one `name_show` attempt. Same tri-state as upstream
    /// `nc_name_show`: transport failures are retryable, everything else is definitive.
    private enum NameShowResult {
        case resolved(String)
        case notFound
        case unavailable
    }

    private enum NameShowEvent {
        case finished(Int, NameShowResult)
        case hedgeTimer(Int)
        case graceTimer(Int)
        case timerCancelled
    }

    /// Quartz 2.13-style hedging. The first server starts immediately and later servers start
    /// 1.5s apart, or immediately when the latest attempt fails. A positive always wins. A
    /// definitive miss stops new attempts but leaves existing attempts a 1.5s grace period, so
    /// a slow positive can beat a fast negative. Empty lists and all-transport-failure outcomes
    /// remain unavailable rather than being misreported as not-found.
    private static func nameShowWithFallback(
        name: String,
        servers: [NamecoinServer],
        transport: any ElectrumXTransporting
    ) async -> NameShowResult {
        guard let first = servers.first else { return .unavailable }

        return await withTaskGroup(of: NameShowEvent.self) { group in
            group.addTask {
                .finished(0, await nameShow(name: name, server: first, transport: transport))
            }

            var nextIndex = 1
            var latestStarted = 0
            var running = 1
            var definitiveMiss = false
            var timerGeneration = 0

            if nextIndex < servers.count {
                let generation = timerGeneration
                group.addTask {
                    do {
                        try await Task.sleep(for: hedgeDelay)
                        return .hedgeTimer(generation)
                    } catch {
                        return .timerCancelled
                    }
                }
            }

            while let event = await group.next() {
                switch event {
                case .timerCancelled:
                    continue

                case .hedgeTimer(let generation):
                    guard generation == timerGeneration, !definitiveMiss, nextIndex < servers.count
                    else { continue }
                    let index = nextIndex
                    nextIndex += 1
                    latestStarted = index
                    running += 1
                    group.addTask {
                        .finished(
                            index,
                            await nameShow(name: name, server: servers[index], transport: transport)
                        )
                    }
                    if nextIndex < servers.count {
                        timerGeneration += 1
                        let nextGeneration = timerGeneration
                        group.addTask {
                            do {
                                try await Task.sleep(for: hedgeDelay)
                                return .hedgeTimer(nextGeneration)
                            } catch {
                                return .timerCancelled
                            }
                        }
                    }

                case .graceTimer(let generation):
                    if definitiveMiss, generation == timerGeneration {
                        group.cancelAll()
                        return .notFound
                    }

                case .finished(let index, .resolved(let value)):
                    _ = index
                    group.cancelAll()
                    return .resolved(value)

                case .finished(let index, .notFound):
                    running -= 1
                    if !definitiveMiss {
                        definitiveMiss = true
                        // Invalidate the next-hedge timer: no new work may start after a miss.
                        timerGeneration += 1
                        guard running > 0 else {
                            group.cancelAll()
                            return .notFound
                        }
                        let generation = timerGeneration
                        group.addTask {
                            do {
                                try await Task.sleep(for: negativeGrace)
                                return .graceTimer(generation)
                            } catch {
                                return .timerCancelled
                            }
                        }
                    } else if running == 0 {
                        group.cancelAll()
                        return .notFound
                    }
                    _ = index

                case .finished(let index, .unavailable):
                    running -= 1
                    // Only failure of the latest attempt accelerates the next one. An older
                    // hedge failing must not compress the stagger for the current attempt.
                    if !definitiveMiss, index == latestStarted, nextIndex < servers.count {
                        timerGeneration += 1
                        let newIndex = nextIndex
                        nextIndex += 1
                        latestStarted = newIndex
                        running += 1
                        group.addTask {
                            .finished(
                                newIndex,
                                await nameShow(
                                    name: name,
                                    server: servers[newIndex],
                                    transport: transport
                                )
                            )
                        }
                        if nextIndex < servers.count {
                            timerGeneration += 1
                            let generation = timerGeneration
                            group.addTask {
                                do {
                                    try await Task.sleep(for: hedgeDelay)
                                    return .hedgeTimer(generation)
                                } catch {
                                    return .timerCancelled
                                }
                            }
                        }
                    } else if running == 0 {
                        group.cancelAll()
                        return definitiveMiss ? .notFound : .unavailable
                    }
                }
            }
            return definitiveMiss ? .notFound : .unavailable
        }
    }

    /// One `name_show` against one server: version handshake → history → latest tx →
    /// expiry check → value extraction. Mirrors `nc_name_show` call-for-call, including
    /// which failures are definitive (empty history, expired name, tx without the name
    /// value) and which are transport (any RPC round-trip failure).
    private static func nameShow(
        name: String,
        server: NamecoinServer,
        transport: any ElectrumXTransporting
    ) async -> NameShowResult {
        // server.version handshake — some ElectrumX operators reject calls before it.
        let versionRequest =
            #"{"jsonrpc":"2.0","id":1,"method":"server.version","params":["whitenoise-mac/namecoin","1.4"]}"#
        guard (try? await transport.roundTrip(to: server, request: versionRequest, wantID: 1)) != nil else {
            return .unavailable
        }

        // The ElectrumX scripthash key is derived locally — never trust the server for
        // name-to-script derivation.
        let script = NamecoinScript.buildNameIndexScript(name: Array(name.utf8))
        let scripthash = NamecoinScript.electrumScripthash(script)

        let historyRequest =
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"blockchain.scripthash.get_history\",\"params\":[\"\(scripthash)\"]}"
        guard let historyBody = try? await transport.roundTrip(to: server, request: historyRequest, wantID: 2)
        else {
            return .unavailable
        }
        guard let (txHash, height) = NamecoinRecord.lastHistoryEntry(from: historyBody) else {
            // Empty history is a definitive Namecoin miss (name never registered / no ops).
            return .notFound
        }

        let transactionRequest =
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"blockchain.transaction.get\",\"params\":[\"\(txHash)\",true]}"
        guard
            let transactionBody = try? await transport.roundTrip(
                to: server,
                request: transactionRequest,
                wantID: 3
            )
        else {
            return .unavailable
        }

        // Best-effort expiry check via headers.subscribe.
        let headersRequest = #"{"jsonrpc":"2.0","id":4,"method":"blockchain.headers.subscribe","params":[]}"#
        var currentHeight = 0
        if let headersBody = try? await transport.roundTrip(to: server, request: headersRequest, wantID: 4) {
            currentHeight = NamecoinRecord.headerHeight(from: headersBody)
        }
        if currentHeight > 0, height > 0, currentHeight - height >= nameExpireDepth {
            return .notFound
        }

        let value = NamecoinRecord.extractValue(fromTransactionBody: transactionBody, name: name)
        if value.isEmpty {
            // The history entry pointed at something that is not our name payload. Treat
            // as definitive miss — best-effort, same as upstream.
            return .notFound
        }
        return .resolved(value)
    }
}

/// Session cache + in-flight dedup. Positive hits mean "this identifier resolved to this
/// pubkey"; negative hits mean "definitively not found". Unavailable is never cached.
/// All upstream cache semantics (`nc_pos_cache` / `nc_neg_cache` / `nc_inflight`) carry
/// over; the actor replaces the upstream mutex.
private actor ResolutionCache {
    enum CachedValue {
        case resolved(String)
        case notFound
    }

    private var entries: [String: CachedValue] = [:]
    private var inflight: [String: Task<String, Error>] = [:]

    func cachedValue(for key: String) -> CachedValue? {
        entries[key]
    }

    /// Returns the in-flight task for `key`, creating one from `work` when none exists.
    func sharedTask(for key: String, work: @escaping @Sendable () async throws -> String) -> Task<String, Error> {
        if let existing = inflight[key] { return existing }
        let task = Task { try await work() }
        inflight[key] = task
        return task
    }

    func clearInflight(for key: String) {
        inflight[key] = nil
    }

    func storePositive(_ pubkeyHex: String, for key: String) {
        entries[key] = .resolved(pubkeyHex)
    }

    func storeNegative(for key: String) {
        guard entries[key] == nil else { return }
        entries[key] = .notFound
    }
}
