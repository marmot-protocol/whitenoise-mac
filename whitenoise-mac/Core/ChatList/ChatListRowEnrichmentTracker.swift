import Foundation

/// Tracks ownership of incremental, per-row chat-list enrichment tasks (issue #40).
///
/// Single-row chat-list updates spawn one enrichment `Task` per group. Exactly one such task
/// should "own" a group's slot at a time: a newer update must supersede (coalesce) an in-flight
/// one, listener teardown / account switch must cancel them all, and a finishing task must
/// release its slot only if it is still the current owner.
///
/// Ownership is keyed by a token that this tracker never reuses — not even after
/// `cancelAll()` clears the maps on reload / account switch. Monotonicity is per instance, not
/// global: two trackers each issue tokens from zero, which is harmless because a token is only
/// ever compared against the maps of the tracker that issued it. That is the crux of the fix: a
/// per-group counter that reset to its first value on clear would let a stale, already-canceled
/// task match a *future* task's reused token and erroneously drop the future task's slot,
/// reintroducing the untracked / uncancellable enrichment work this is meant to prevent.
struct ChatListRowEnrichmentTracker {
    /// How long a backfill attempt keeps its group from being attempted again. A backfill that
    /// fails (the roster or transcript read threw) records nothing, so without this every chat-list
    /// snapshot would re-run it for as long as the read keeps failing.
    static let backfillRetryDelay: TimeInterval = 60

    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: Int] = [:]
    private var nextToken: Int = 0
    /// Earliest time each group's backfill may run again. Separate from `tokens`, which only cover
    /// a task while it is in flight and are gone the moment a failed attempt finishes.
    private var backfillNotBefore: [String: Date] = [:]

    /// Number of currently tracked (live) tasks. Diagnostic / test helper.
    var trackedTaskCount: Int { tasks.count }

    /// The current ownership token for `group`, if any. Diagnostic / test helper.
    func currentToken(forGroup group: String) -> Int? { tokens[group] }

    /// The task currently owning `group`, if any — so a test can await it instead of polling.
    func task(forGroup group: String) -> Task<Void, Never>? { tasks[group] }

    /// Whether a backfill for `group` may start at `now`: nothing is in flight for it, and its
    /// last attempt (if any) is at least `backfillRetryDelay` old.
    func mayStartBackfill(forGroup group: String, now: Date) -> Bool {
        guard tokens[group] == nil else { return false }
        guard let notBefore = backfillNotBefore[group] else { return true }
        return now >= notBefore
    }

    /// Records that a backfill for `group` starts at `now`, holding off the next one until
    /// `backfillRetryDelay` has passed. A successful one leaves nothing to backfill, so this only
    /// ever gates a retry of one that failed.
    mutating func noteBackfillAttempt(forGroup group: String, now: Date) {
        backfillNotBefore[group] = now.addingTimeInterval(Self.backfillRetryDelay)
    }

    /// Allocates a globally unique, never-reused ownership token for `group` and cancels any
    /// task currently owning it. Call before spawning the replacement task.
    mutating func beginTask(forGroup group: String) -> Int {
        tasks[group]?.cancel()
        nextToken += 1
        let token = nextToken
        tokens[group] = token
        return token
    }

    /// Records `task` as the owner of `group` for `token`. If `token` is no longer current
    /// (a newer `beginTask` has since run for this group) the late registration is ignored and
    /// the task canceled, so it cannot clobber a newer owner.
    mutating func register(task: Task<Void, Never>, forGroup group: String, token: Int) {
        guard tokens[group] == token else {
            task.cancel()
            return
        }
        tasks[group] = task
    }

    /// Releases `group`'s slot iff `token` is still the current owner. A stale token (from an
    /// older, already-superseded or canceled task) is a no-op, so it can never drop a newer task.
    mutating func finishTask(forGroup group: String, token: Int) {
        guard tokens[group] == token else { return }
        tasks[group] = nil
        tokens[group] = nil
    }

    /// Cancels every tracked task and clears all ownership and backfill-retry state. The token sequence is
    /// deliberately **not** reset, so tokens issued after this call stay unique with respect to
    /// any still-unwinding canceled task.
    mutating func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        tokens.removeAll()
        backfillNotBefore.removeAll()
    }
}
