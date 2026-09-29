# MarmotKit 0.11.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.11.0` at MDK commit
`946e0547485c9a2c393c2048ec3a968fd50fb441`. The host-side contract is MDK's
`docs/integration/0.11.0.md`; read the copy on MDK `master`, not the tagged one, because a
post-tag supplement reclassified polls as required and audit v5 as required when audit is on.

## Storage

The first open of each account database runs MDK migrations 90–98 in one forward pass. They add
tables and columns and rewrite no message history. Opening an account with this build is a one-way
boundary: a 0.10.4 binary refuses the upgraded database with `UnsupportedSchemaVersion` before it
reads account tables. Rolling back the application binary is not a database rollback; keep a
pre-upgrade copy of the container when rollback evidence is required.

For developers: after running this build against a container, switching back to a 0.10.4 build of
`master` fails at startup with a `storage_backend` error. That is the schema downgrade, not
corruption. Use a separate container, or restore the copy.

`MarmotKitMigrationTests` still opens the 0.9.16 account-root fixture described in
`MarmotKit-0.10.4-migration.md`; that fixture now migrates through 57–98.

## "History may be incomplete" notices

Migration 92 turns every 0.10.4 overflow marker into a delivery-loss recovery obligation. No
comparison can certify it, so shortly after the upgrade it parks and appears as a `DeliveryLoss`
notice. **This is expected on upgraded accounts and is not a new loss.** While the notice is
pending, the account's transport cursor stays fenced; dismissing it releases the fence once no
other loss recovery is pending.

The app surfaces notices through `HistoryNoticesViewModel`, owned by `AccountScope`:

- It subscribes to the runtime event firehose before its first read and re-reads
  `historyNotices(accountRef:)` on every `historyNoticesChanged` for its account, so a notice that
  parks while the app is open appears without a relaunch.
- Account-wide notices (no `groupIdHex`) are banners under the chat-list header. Group notices come
  from `GroupRecoveryStatusFfi.historyMayBeIncomplete` / `historyNoticeIds` and appear in the
  group's details.
- Only the user dismisses a notice. A `false` from `dismissHistoryNotice` means the occurrence
  re-armed or is gone; the list is re-read. Notice ids change on every re-arm and are never stored.
- Notices stay out of analytics.

A group's `automatic_recovery_failed` warning survives the upgrade unchanged and clears only on
authenticated recovery or a rejoin, not over time.

MDK #2086: a large catch-up can strand undecryptable messages without raising a notice. The app
cannot detect that case, so no copy promises complete history.

## Audit logs: known regression until audit v5 lands

Once audit logging is enabled, 0.11.0 writes only v5 audit files, and the v4 route this build still
configures (`setAuditLogTrackerConfig`, `postAuditLogTrackerUpdate`) rejects them. The v4 config
is kept only to drain v4 files 0.10.4 left behind. **Audit evidence recorded on 0.11.0 does not
leave the device yet**; configuring `setAuditOtlpConfigV5` and moving the manual upload to
`postAuditLogTrackerUpdateV5` is the follow-up.

Diagnostics does not report an empty v4 upload as success: it says "No audit logs uploaded."

## Polls

Kind-1068 polls render as a notice row, "📊 Poll: <question>" with "This poll can’t be displayed.",
and the chat list previews them as "📊 Poll: <question>". Showing results, voting and creating polls
are the follow-up; until then no poll is passed off as a plain message.
