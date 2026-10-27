# MarmotKit 0.14.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.14.0` at MDK commit
`3fb4b4759ac676b0c21c4c3527074866c9fa4c89`. The host-side contract is MDK's
`docs/integration/0.14.0.md`; the release notes are `docs/release/0.14.0.md`.

## Storage

This is a one-way boundary, and a harder one than 0.11.0–0.13.0: going back means restoring a copy,
not just switching branches.

- **Schema migrations.** The first open of each account database runs MDK migrations 0108–0116
  (schema 107 → 116): attachment-history counters, full-disk download parking, the encrypted
  media-file catalog, convergence witness columns, staged outgoing media, a file-backed avatar
  table, catch-up replay obligations and the Keep media setting. None rewrites message history.
  0112 discards 0.13.0 download checkpoints, so interrupted downloads restart from zero; 0114 keeps
  at most 32 MiB of avatar and group-image bytes and drops the rest, to be fetched again when shown.
- **Directory cache.** `app-cache.sqlite3` goes from schema 1 to 2 (the public event preview table).
  `shared.sqlite3` is unchanged.
- **One-time rekey.** Every app database (`session.sqlite`, `app-cache.sqlite3`, a legacy
  `app.sqlite3`) is rekeyed once from a passphrase to a raw SQLCipher key, which makes later opens
  much faster. `PRAGMA rekey` rewrites every page; for `session.sqlite` it runs before the
  migrations. A `<database>.raw-key-migrating` marker lets an interrupted rekey resume on the next
  open. MDK has not measured its time or temporary disk use (about one database of WAL) on a large
  account.
- **Encrypted media files.** Attachment bodies, download checkpoints, avatars and group images move
  out of the database into encrypted files under `<account>/media/`, in bounded background batches
  while the app runs. On a tight disk the move pauses (`AttachmentMigrationStateFfi.Paused`) rather
  than deleting anything; Manage Storage shows that state. `<account>/handoff/` holds plaintext
  copies for attachment handoff leases (`Core/AttachmentHandoff.swift`) until they are released.
  The database file only shrinks if it qualifies for MDK's one automatic compaction.
- **No downgrade.** A 0.13.0 binary cannot open a rekeyed database: it fails with a key error before
  reading any table, which locally shows up as a `storage_backend` startup error after switching
  back to an older branch. Even after MDK's documented offline rekey back to a passphrase, 0.13.0
  refuses schema 116 with `UnsupportedSchemaVersion`. Re-upgrade, or restore a device-local copy of
  the whole account directory taken before upgrading (databases with their WAL, the `.salt`
  sidecars and the Keychain credentials). Restoring an older database also rewinds MLS state, so
  prefer re-upgrading. For local testing, use a separate container.
- **Backups.** `MarmotStorageRoot` excludes the Marmot root from backups. A restored database
  without its `media/` files, or the files without their database, is unsupported, and MDK's media
  sweep removes files that have no row.

## Binding changes

- Every `Marmot` construction, tests included, passes `deployment: marmotDeploymentWhiteNoise()`.
  Its keychain service is `com.marmot.whitenoise`, the one existing installs use.
- `MarmotKitError` gains `InvalidEditTarget`, `InvalidPublicEventReferences`,
  `DirectoryLookupIncomplete`, `FollowListTooLarge`, `GroupCatchingUp`, `GroupCommitUndelivered`
  and `StorageFull`, and `MissingKeyPackage` gains a `reason`. Nothing switches exhaustively over
  `MarmotKitError`. The group-change advisories run through `GroupChangeAdvisoryRetry`
  (`Core/GroupChangeAdvisory.swift`); `obsoleteOnly` recipients get "needs to update" copy
  (`ChatCreationFailure.needsAppUpdate`).
- `AttachmentTransferStateFfi` gains `StorageBlocked` and `CleanedBySetting`; `CleanedBySetting` is
  treated like a manual removal. `RetentionSweepStatusFfi` loses `DeferredScanExhausted`.
- `OnboardingFindingFfi` gains `context`, `purpose`, `outcome`, `declaredCapability`, `actions` and
  `observedRevision` with no binding defaults; the test fixtures build findings through
  `OnboardingFindingFfi+Preview.swift`. `OnboardingIssueFfi` gains `InspectionCompleted`, which
  only records that a relay answered: the account-setup steps print no line for it.

## Adopted

- **Group-change prompts** (`GroupCatchingUp`, `GroupCommitUndelivered`): ask, acknowledge only
  after consent, retry once. See AGENTS.md for the alert-host rule.
- **Manage Storage** (Settings → Storage), reading `attachmentStorageUsage` and removing in bulk.
- **Attachment handoff leases** for opening documents in another app and for Save As.
- **Account attachment history** pages (`attachmentHistoryPage`, read by `AttachmentViewModel`).

## Not adopted yet

- **Per-finding onboarding actions and context.** The account-setup steps still read only each
  finding's `issue` and `endpoint`, and offer the step's full action set (as the iOS app does).
- **Keep media** as a setting (the app only renders its removals), **public event previews**,
  **captured media send** and **commit delivery status**.

## Known issues upstream

- MDK #2237: a message arriving more than five epochs late stays undecryptable without a "history
  may be incomplete" notice.
- Group-change prompts: undecryptable traffic can hold changes behind `GroupCatchingUp` (#2277), no
  bounded catch-up runs before the refusal (#2283), and an acknowledgement cannot be withdrawn
  (#2389).
- MDK #2158: an upload still in flight when the group epoch advances is lost.
