# MarmotKit 0.17.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.17.0` at MDK commit
`4df811aea99269b437a6023be9446a5141e93cbe`. The host-side contract is MDK's
`docs/integration/0.17.0.md`; the release notes are `docs/release/0.17.0.md`.

## Storage

- **Account databases migrate from schema 201 to 207** (migrations 0202–0207) on first open:
  sticker-pack relay hints, retained member reports for prepared-image creates, removal of the
  timeline rows of failed sends that were then deleted (0204), storage-parked downloads, the
  committed-roster tables, and `cgka_commit_refusals`. No message history is rewritten; 0204 deletes
  only the affected timeline rows.
- **The shared database is unchanged** (schema 4, as in 0.16.0).
- **No downgrade.** A 0.16.0 binary refuses an upgraded account database. Locally that is a startup
  error after switching back to an older branch. To roll back, restore a copy of the whole Marmot
  data directory taken before upgrading while the app was not running. For local testing, prefer the
  staging flavor (`just run-staging`), whose data lives apart from production's.

## Binding changes

- **Partial creates and invites.** `createGroup` returns `GroupCreationResultFfi` (optional
  `groupIdHex`, `memberOutcomes`) and `inviteMembersDetailed` returns `GroupInviteResultFfi`
  (`invite.summary` optional, `invite.memberOutcomes`, `details`, `managementState`). MDK now goes
  ahead with the members it can reach and reports every requested account, in request order, as
  `selected`, `missingKeyPackage`, `obsoleteKeyPackage`, `invalidKeyPackage`,
  `incompatibleKeyPackage`, `missingInboxRoute` or `incomplete`. A nonempty request with nobody
  available creates no group and makes no commit. There is no all-or-nothing option over the FFI.

  The app used to learn a roster's unreachable members before anything was created: create and
  invite stopped at the first member with no usable KeyPackage, so `createGroupResolvingEveryRefusal`
  and its invite twin spent one refused attempt per member, pinning the last refusal to keep each
  follow-up failing. That machinery is gone, because under 0.17.0 the first attempt succeeds with
  whoever is available. `MemberResolutionReport` reads the outcomes instead:

  - **Nothing created / invited.** The compose panel and the add-members sheet mark the unreachable
    members ("Not on White Noise yet") and stay open, as before. A one-to-one attempt offers the
    invite prompt. Outdated members get the "needs to update" line, and `incomplete` members (MDK's
    relay reads did not finish) are told to try again and are *not* marked.
  - **Created / invited with some left out.** The compose flow checks KeyPackages before anyone is
    added, so this should be rare and is treated as a plain problem: the chat opens (or the sheet
    closes) and the banner says "Couldn’t add Bob and Carol to the group." The Create button is
    unchanged.

  `startDirectConversation` keeps its signature and stays all-or-nothing, so the one-to-one
  "Message" path still maps `MissingKeyPackage` through `ChatCreationFailure`.
- **Audit source.** `setAuditLogTrackerConfig` and `AuditLogTrackerConfigV4Ffi` are gone; the app
  calls `setAuditLogSource(AuditLogSourceFfi)` with the same `hardwareModel` (`hw.model`), `platform`
  and flavor-stamped `appVersion` (`TelemetryBuildConfig.auditLogSource()`). It is applied in
  `configureObservabilityRuntime`, which bootstrap runs before `bringRuntimeOnline`, so every launch
  sets it before accounts open. The v4 whole-file upload is removed: `AuditLogTrackerUpdateResultV5Ffi`
  drops `v4Uploaded` and `v4SkippedReason`, and the Diagnostics upload status reports v5 only.
- **`MarmotKitError.CreatedGroupMemberReportUnavailable`.** Mapped in `UserFacingError`. Reachable
  only from a prepared-image create, which the app does not use.
- **`AppPerformanceSnapshotFfi.accountGroupReadSnapshot`** is removed. The app never read it.
- **`GroupCommitDeliveryFfi.refusedRelays`.** The app does not read `groupCommitDelivery`. A relay's
  lasting refusal of a confirmed change makes group changes fail with `GroupCommitUndelivered` at
  once, which the existing advisory flow (`GroupChangeAdvisoryRetry`) already handles: its
  acknowledgement now also dismisses the refusal for good.
- **`HistoryNoticeCauseFfi.unprovenHistory`** is no longer emitted. It stays in the switch.
- **`nextCancellable()`**: no new generated adapters, so `CancellableProjectionNext.swift` is
  unchanged.

## Behavior that changed with no API change

- Account and group reads (members, roster, MLS state, quarantined groups, KeyPackage status,
  maintenance) answer from the worker's published read state instead of queuing behind sends and
  catch-up. Startup still waits for a group awaiting hydration.
- "History may be incomplete" notices need evidence of missing messages or a rejoin; the coverage
  ledger no longer raises them.
- Attachments download four at a time, on-screen first (the bubbles already call
  `requestAutomaticAttachment` as they appear), and a download short of disk space parks as
  `storageBlocked`, which the attachment UI already handles.
- A failed own send that is deleted leaves the timeline.
- A commit over 64 KiB is not sent to a relay of unknown limit; the White Noise preset lists 2 MiB
  for its relays, so its groups are unaffected.
- Bare `note1`, `nevent1` and `naddr1` references become `NostrUri` tokens, which
  `MarkdownDisplayModel` already renders as links.
- New White Noise groups no longer list `cdn.hzrd149.com` as a media endpoint.

## Adopted 0.17.0 features

- **`discardFailedSend`.** A failed own send's menu offers **Remove** in place of Delete: the row is
  discarded on this device and nothing is published, with no confirmation (as for a staged send
  that never got out). `ConversationViewModel.discardFailedSend` owns the call; `stillSending` asks
  the user to try again, `notFailedSend` (retried or delivered since the menu opened) does nothing,
  and a discarded send that carried media clears the host media cache, as Manage Storage does,
  because the cache cannot be purged by ciphertext hash alone.
- **`createTaggedPoll` / `sendTaggedSticker`.** They replace `createPoll` / `sendSticker` on
  `MarmotRuntime`. A poll or sticker sent while a reply is open carries the reply's `e`/`q` tags
  (`MessageReplyTags`) and spends the reply, as a text send does.
- **`stickerPackShareLink`.** The sticker pack page has **Copy Link**, which copies MDK's offline
  Sonar link (up to eight relay hints) via `StickerLibrary.shareLink(for:)`.

## Not adopted yet

- **A standing commit-refusal warning** from `groupCommitDelivery().refusedRelays`, rather than only
  at the next group change.
- Carried over from 0.16.0: relay liveness, NIP-46 remote signers, audit delivery status (#1012).
