//
//  PeerProfileRefreshGate.swift
//  whitenoise-mac
//
//  Admission control for relay-backed peer profile (kind:0) refreshes. Pure value
//  type: no platform state, no FFI, no clock of its own — callers pass `now` so the
//  cache-TTL clock (`WorkspaceState.nowProvider`) drives this too.
//
//  Why a gate at all: `requestPeerProfileRefresh` is called from projection and
//  render paths (timeline window applies, chat-row enrichment, reaction rows), so
//  without admission control a scrolling transcript would issue one relay round-trip
//  per frame per sender. Android solves this the same way (`ProfileRefreshGate.kt`).
//

import Foundation

nonisolated struct PeerProfileRefreshGate: Sendable {
    /// Cooldown after an attempt run has settled, so a render-path caller can ask on
    /// every frame without producing relay traffic. Matches Android's
    /// `PROFILE_REFRESH_RETRY_COOLDOWN_MILLIS`.
    static let retryCooldown: TimeInterval = 60

    /// Attempts allowed before the id falls back to `retryCooldown`. A peer with no
    /// published kind:0 anywhere must cost a bounded number of round-trips, not a loop.
    static let maxAttemptsPerWindow = 3

    /// Delay before attempt 2 and attempt 3 of a run. Mirrors whitenoise-linux's
    /// `resolve_display_name_async` ladder (`2u64 << (attempt - 2)` → 2s, 4s), which
    /// exists because "a transient relay failure must not strand the caller until some
    /// unrelated event re-asks".
    static let backoffDelays: [TimeInterval] = [2, 4]

    /// Cooldown applied after the *n*-th consecutive run that failed to name the peer, so a
    /// pubkey with no kind:0 anywhere stops costing round-trips.
    ///
    /// Without this the gate is an infinite pulse: a spent run reset `attempt` to `0`, the
    /// entry was pruned as its 60s cooldown elapsed, and the very next projection re-admitted
    /// the id at the bottom of the 2s/4s ladder — 3 relay round-trips per peer per ~66s, for
    /// the life of the process. The timeline and chat-list paths request every sender and
    /// every roster member they see, so an unresolvable 50-member group sustained ~150
    /// round-trips a minute forever, each also taking a slot on the shared `FFIExecutor.queue`
    /// that the transcript projection needs. Escalating instead keeps the responsive first
    /// minute and turns the steady state into a trickle.
    static let repeatedFailureCooldowns: [TimeInterval] = [60, 300, 1800]

    private struct Entry: Sendable {
        /// No attempt may start before this instant.
        var retryAfter: Date
        /// Attempts already spent in the current run. `0` means the run settled and the
        /// id is serving out a cooldown; the counter then carries no information.
        var attempt: Int
        /// Consecutive runs that ended without naming the peer. Indexes
        /// `repeatedFailureCooldowns`; reset the moment the peer resolves.
        var failedRuns: Int = 0
    }

    /// How often the retained set is actually swept. `tryStart` runs once per unresolved
    /// sender on every timeline window apply and every live delta, so sweeping on each call
    /// would put an O(retained) pass on the projection hot path for a set that changes at
    /// human speed. Admission itself never depends on the sweep — `now < retryAfter` is the
    /// gate — so amortizing it only shifts *when* a stale entry is collected.
    static let pruneInterval: TimeInterval = 1

    private var inFlight: Set<String> = []
    private var entries: [String: Entry] = [:]
    private var nextPruneAt = Date.distantPast

    /// Whether an attempt may start for `accountIdHex` right now.
    mutating func tryStart(_ accountIdHex: String, now: Date) -> Bool {
        pruneExpired(now: now)
        guard !inFlight.contains(accountIdHex) else { return false }
        if let entry = entries[accountIdHex], now < entry.retryAfter { return false }
        inFlight.insert(accountIdHex)
        return true
    }

    /// Records the outcome of an attempt. `resolved` means the lookup produced a usable
    /// profile, which settles the run; otherwise the backoff ladder advances.
    ///
    /// `deferRetries` skips the urgent 2s/4s ladder and settles the run immediately. Callers
    /// pass it for a peer the user has already nicknamed: that row reads correctly right now,
    /// so the only thing still missing is the published name shown beneath the nickname, and
    /// nothing about it justifies a burst of round-trips.
    mutating func finish(_ accountIdHex: String, now: Date, resolved: Bool, deferRetries: Bool = false) {
        inFlight.remove(accountIdHex)
        // Prune here as well as in `tryStart`. `tryStart` is not guaranteed to run
        // again on a gate that goes quiescent after a burst of `finish` calls — e.g. a
        // large group whose senders are all resolved in one pass — and without this the
        // map retains one entry per distinct pubkey for the process lifetime. Android
        // hit exactly this (`ProfileRefreshGate.kt`, their #230).
        pruneExpired(now: now)

        let existing = entries[accountIdHex]

        guard !resolved else {
            // Resolving clears the failure history: the next time this peer goes unnameable
            // it is a fresh problem (a changed pubkey, a rotated relay set) and deserves the
            // responsive ladder again, not the cooldown its previous run had escalated to.
            entries[accountIdHex] = Entry(retryAfter: now.addingTimeInterval(Self.retryCooldown), attempt: 0)
            return
        }

        let attempt = (existing?.attempt ?? 0) + 1
        let backoffIndex = attempt - 1
        if !deferRetries, attempt < Self.maxAttemptsPerWindow, backoffIndex < Self.backoffDelays.count {
            entries[accountIdHex] = Entry(
                retryAfter: now.addingTimeInterval(Self.backoffDelays[backoffIndex]),
                attempt: attempt,
                failedRuns: existing?.failedRuns ?? 0
            )
            return
        }

        // Run spent. Reset the ladder so a later window starts fresh, but carry the run
        // count forward so the cooldown before that window escalates.
        let failedRuns = (existing?.failedRuns ?? 0) + 1
        let cooldown = Self.repeatedFailureCooldowns[
            min(failedRuns - 1, Self.repeatedFailureCooldowns.count - 1)
        ]
        entries[accountIdHex] = Entry(
            retryAfter: now.addingTimeInterval(cooldown),
            attempt: 0,
            failedRuns: failedRuns
        )
    }

    /// Drops one id's admission state. Used when an update arrives from outside this
    /// gate (a profile stream, or an explicit user-driven re-resolve) and the pending
    /// cooldown would otherwise suppress a legitimate immediate retry.
    mutating func remove(_ accountIdHex: String) {
        inFlight.remove(accountIdHex)
        entries.removeValue(forKey: accountIdHex)
    }

    /// Account-switch / sign-out reset. Admission state is scoped to the active
    /// account's directory view, exactly like `peerProfileFFICache`.
    mutating func removeAll() {
        inFlight.removeAll()
        entries.removeAll()
    }

    /// Evicts entries that carry no state worth keeping, once their cooldown has elapsed.
    ///
    /// An entry that resolved (`attempt == 0`, `failedRuns == 0`) carries nothing beyond its
    /// cooldown, so it can go the moment the cooldown elapses. Anything else — a mid-ladder
    /// attempt, or a settled run that failed — must be retained *past* its `retryAfter`,
    /// otherwise the next request drops the counter it was holding: the ladder would restart
    /// at 2s forever instead of ever settling, and `failedRuns` would reset to 0 so the
    /// cooldown could never escalate. Retention is still bounded: if nobody re-asked within
    /// `retryCooldown` of the wait expiring, the run is stale and resetting it is correct.
    private mutating func pruneExpired(now: Date) {
        guard now >= nextPruneAt, !entries.isEmpty else { return }
        nextPruneAt = now.addingTimeInterval(Self.pruneInterval)

        // Collect then remove, rather than rebuilding the dictionary with `filter`. In the
        // common case nothing has expired, and an empty `[String]` costs no allocation — so a
        // sweep that finds nothing is free, instead of reallocating the whole map.
        var expired: [String] = []
        for (accountIdHex, entry) in entries {
            let horizon =
                entry.attempt == 0 && entry.failedRuns == 0
                ? entry.retryAfter
                : entry.retryAfter.addingTimeInterval(Self.retryCooldown)
            if now >= horizon { expired.append(accountIdHex) }
        }
        for accountIdHex in expired {
            entries.removeValue(forKey: accountIdHex)
        }
    }

    #if DEBUG
        /// Test-only: entries the gate is retaining. Asserts the pruning bound above.
        var retainedEntryCountForTesting: Int { entries.count }
        var inFlightCountForTesting: Int { inFlight.count }
        func retryAfterForTesting(_ accountIdHex: String) -> Date? { entries[accountIdHex]?.retryAfter }
        func attemptForTesting(_ accountIdHex: String) -> Int? { entries[accountIdHex]?.attempt }
        func failedRunsForTesting(_ accountIdHex: String) -> Int? { entries[accountIdHex]?.failedRuns }
    #endif
}
