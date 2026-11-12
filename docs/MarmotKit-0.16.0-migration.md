# MarmotKit 0.16.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.16.0` at MDK commit
`a2e0558a634bbd20607cdd5afb93abc6220ee58d`. The host-side contract is MDK's
`docs/integration/0.16.0.md`; the release notes are `docs/release/0.16.0.md`.

## Storage

- **Account databases are not migrated.** They stay at schema 201.
- **Shared database.** `shared.sqlite3` runs migration 0004 (`0004_audit_log_retention`, schema
  3 → 4) on first open: one small table. The local v5 audit delivery cursor
  (`local-delivery.json`) moves from version 1 to 2, and a new
  `audit-otlp-delivery-v5/delivery-status.json` records each delivery attempt.
- **No downgrade.** A 0.15.0 binary refuses the shared database
  (`UnsupportedSchemaVersion { found: 4, latest_supported: 3 }`) and the version-2 cursor. Locally
  that is a startup error after switching back to an older branch. To roll back, restore a copy of
  the whole Marmot data directory taken before upgrading while the app was not running. For local
  testing, prefer the staging flavor (`just run-staging`), whose data lives apart from production's.

## Behavior that changed with no API change

- **OpenMLS security fixes** (GHSA-gc79-23g3-8g52, GHSA-p276-g3f3-wwgh). Stored groups load
  unchanged and 0.15.0 and 0.16.0 members interoperate.
- **Relay size limits.** MDK no longer sends an event to a relay known to refuse it for size. The
  White Noise deployment preset (`marmotDeploymentWhiteNoise()`, which `AppFlavor` passes through
  untouched) sets 2 MiB on `relay.eu.whitenoise.chat` and `relay.us.whitenoise.chat`, and for events
  over 64 KiB a relay's NIP-11 `max_message_length` also counts. The app lists no extra limits
  (`relayEventLimits` stays as the preset sets it).
- **`EventTooLarge` in more places.** KeyPackage rotate/republish and setup's publish, block and
  unblock, sticker sync, and profile, follow-list and relay-list publishes now fail as
  `EventTooLarge { artifact: .other }` when every relay refuses for size, where they used to be
  `Runtime`, `BlockListUnavailable` or `StickerNetwork`. A group create or invite whose Welcome fits
  none of an invitee's inbox relays fails up front as `EventTooLarge { artifact: .welcome }` with
  nothing created or sent. Copy for both is in `UserFacingError.eventTooLargeMessage`: `.other` now
  says "your relays" (these are account publishes, not the chat's), and `.welcome` says the
  invitation was not sent.
- **Stuck chats.** A chat no longer stops receiving after its live subscriptions are rebuilt; joining
  several groups quickly no longer records history loss; a leave blocked by a rival branch is
  re-driven, so sign-out no longer waits out its 30 s deadline.
- **Declines.** A `declineGroupInvite` that timed out while still queued no longer leaves the group
  later. One the worker had already started still completes.

## Binding changes

- **`nextCancellable()` moved upstream for five subscriptions.** The generated `MarmotKit.swift`
  now declares it on `PresentedChatListSubscription`, `ChatListWindowSubscription`,
  `AccountAttentionSubscription`, `ConversationWindowSubscription` and `BlockListSubscription`, so
  the app's copies were deleted from `Vendored/MarmotKit/Sources/MarmotKit/CancellableProjectionNext.swift`.
  That file keeps the adapters MDK does not ship (`AttachmentTransferSubscription`,
  `OnboardingSubscription`, `EventsSubscription`), with its helper aligned to MDK's: a cancellation
  that races a typed error wins, every Rust buffer is freed on every path, and a Rust panic surfaces
  its message. Delete each remaining adapter once the generated source declares it.
- **`AppGroupHydrationQuarantineReasonFfi.rewindRestoreFailed`.** Only the next account open can
  restore it; `retryHydrateQuarantinedGroup` always answers `false`. Settings → Developer Mode →
  Quarantined Groups shows the reason with "Quit and reopen White Noise" instead of a Retry button
  (`QuarantinedGroupReason.canRetry`).
- **`GroupEventKindFfi.queuedIntentRefused`** gains `artifact` and `sizeClass`, set only for reason
  `event_too_large`. `RefusedIntentNoticesViewModel` passes the artifact through, and
  `RefusedIntentPresentation` words a refused Welcome and a refused commit separately.
- **`MarmotKitError.Nip46(reason:)`.** Mapped in `UserFacingError.nip46Message`. The app has no
  NIP-46 sign-in, so this is reachable only for an account another client set up.
- **`MarmotDeploymentFfi.relayEventLimits`** — see relay size limits above.

## Adopted 0.16.0 features

- **`startDirectConversation`.** `WorkspaceState.startDirectChat` (the reusing path, which every
  "Message" entry point takes) now calls it instead of `createGroup` followed by a best-effort
  `promoteAdminDetailed`. MDK founds the chat with both accounts as admins in one step on the
  account worker, and a retry after a timeout or cancellation reuses the same group rather than
  creating a second. The New chat chooser's "Start new conversation" (`reusingExisting: false`)
  still uses `createGroup` + promote, because `startDirectConversation` would hand back the existing
  chat the user just asked to bypass.

- **Relay liveness** (`subscribeRelayLiveness`, `reconnectRelay`). Settings → Relays shows each
  relay's connection and the relay detail page has a Connection section with Reconnect
  (`RelayLivenessViewModel`). The subscription lives in the page's own task; leaving the page
  calls `cancel()`, which wakes MDK's pending `next()` and never disconnects a relay.

## Not adopted yet

- **NIP-46 remote signers** (`nip46New`, `nip46Login`, …).
- **Audit delivery status and retention** (`auditDeliveryStatusV5`, `auditLogRetention`,
  `setAuditLogRetention`). The 256 MiB per-account default budget applies.
- **Media sent as a reply.** `uploadMediaWithClientToken(send: true)` now keeps a reply target named
  by an `e`/`q` message tag; the app sends no reply tags with media today.
