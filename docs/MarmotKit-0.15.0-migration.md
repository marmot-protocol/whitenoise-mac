# MarmotKit 0.15.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.15.0` at MDK commit
`827687ba7fdbb05ec1b8f17667ad919fedde7266`. The host-side contract is MDK's
`docs/integration/0.15.0.md`; the release notes are `docs/release/0.15.0.md`.

## Storage

- **Schema migrations.** The first open of each account database runs MDK migrations 0117–0153,
  0160–0180, 0200 and 0201 (schema 116 → 201; the gaps are unused numbers). Each runs in its own
  transaction, so an interrupted upgrade resumes where it stopped. None copies `app_events` or
  `message_timeline`, but several scan history-sized tables once, so a large account's first open
  is slower and needs temporary disk for the WAL and new indexes. MDK has not measured it on a large
  account. Account startup now gives up only after 45 seconds *without progress*, so a slow
  migration no longer fails startup.
- **Chat-list presentation rebuild.** 0141 rebuilds the chat-list projection of almost every
  account, and 0200 invalidates every stored chat presentation once. Rows keep their last value
  while the presentation worker rewrites them.
- **Delivery backfill.** 0173 marks failed own sends that a peer has reacted to as delivered
  (`recipientConfirmed`, below).
- **Undecodable rows refuse to open.** 0175 aborts, and the account does not open, if a saved
  outbound fanout or group evolution cannot be decoded, rather than risk reusing a reference.
- **Push re-share.** With native push on, 0117 queues one push-registration share per joined group.
- **Directory cache and shared store.** `app-cache.sqlite3` stays at schema 2 and `shared.sqlite3`
  is unchanged.
- **No downgrade.** A 0.14.0 binary refuses a migrated database with `UnsupportedSchemaVersion`
  (locally, a `storage_backend` startup error after switching back to an older branch). Re-upgrade,
  or restore a device-local copy of the whole account directory taken before upgrading (databases
  with their WAL, the `.salt` sidecars, `media/` and the Keychain credentials). Restoring rewinds MLS
  state, so prefer re-upgrading. For local testing, use a separate container.

## Behavior that changed with no API change

- **Account devices.** Every 0.15 build advertises `marmot.group.account-devices.v1`. A new group
  whose founding devices all advertise it requires it permanently, so a 0.14.0 or older client can
  never be invited into it later. Groups with a 0.14.0 founder are created as before.
- **Every device is invited.** Creating a group or inviting adds every device of each recipient
  account (up to 20 KeyPackages from the last 30 days). Member rows, `memberCount`, admin counts and
  direct-chat detection count accounts, not devices; member rows carry `deviceCount`.
- **KeyPackages.** New KeyPackages are valid for 30 days instead of 84, and each device replaces its
  own every 6 to 7 days. Sign-out with `deleteKeyPackages` deletes only this device's slot with one
  kind-5 deletion, so `keyPackagesDeleted` is now 1 or 0.
- **Recovery.** The recovery runner owns account history. A group's newer live messages wait until
  its fetched backlog is admitted, so they can appear slightly later after a reconnect. Account
  workers rejoin an `Unrecoverable` group copy automatically through an admin device.
- **Admin invitees.** `requiresSelfDemoteBeforeLeave` is now also true for an admin with a pending
  invitation, whose `declineGroupInvite` fails with `AdminCannotSelfRemove` until
  `selfDemoteAdmin`.
- **Typed errors.** Busy, closed or full storage and a rejected external signer that used to arrive
  as `Runtime` now arrive as `StorageBusy`, `StorageClosed`, `StorageFull` and
  `ExternalSignerRejected`. An event every relay refused for size arrives as `EventTooLarge`.
- **Offline sends.** Every text send queued while offline publishes on reconnect, in order.

## Binding changes

- `TimelineMessageQueryFfi` gains `sender`, `since`, `until` and `cursorGroupId` with no binding
  default (plus `attachmentType` and `searchWallClock`, which have defaults). Every caller passes
  them as `nil`, so the queries are unchanged.
- `SelfMembershipFfi` gains `DeviceRemoved`: this device left a chat that the account stays in
  through another device. MDK shows no "removed" notice for it.
- `HistoryNoticeCauseFfi` gains `UnprovenHistory` and `BeforeRejoin`, worded as on iOS
  (`HistoryNoticePresentation`).
- `TimelineMessageRecordFfi.recipientConfirmed` is true when a peer reacted to an own send that
  failed with no relay acceptance on record. Such a row keeps a nil `sourceMessageIdHex`, so
  `MessageItem` reads it as delivered rather than "Not delivered".
- Records the tests build gain fields with no binding default: `AccountSummaryFfi.unlinked`,
  `leaveBlocked` / `canCancelLeave`, `sticker` on message, preview and timeline records,
  `recipientConfirmed`, `importedFrom` and `historyImportProvenance`.
- `MarmotKitError` gains 22 cases and `MarmotEventFfi` 8. `UserFacingError` switches exhaustively
  over `MarmotKitError` with no `default`, so the next release's new cases fail the build until they
  have copy. Every `MarmotEventFfi` case except `RecoveryStatusChanged` belongs to experimental
  device groups, which this app does not enable.
- `MediaAttachmentReferenceFfi.sourceEpochIdentity` binds an upload to its epoch branch. Ordinary
  media uploads and sends in one call (`uploadMediaWithClientToken(send: true)`) and forwards by
  uploading again. Custom emoji are the one place a reference is uploaded (`send: false`) and sent
  later (`sendTaggedMedia`, `reactWithMedia`): `ConversationCustomEmojiSender` keeps it only for
  its own chat, and drops it and re-encrypts once when MDK answers `MediaReferenceStaleEpoch` or
  `InvalidMediaReference`.

## Adopted 0.15.0 features

- **Errors.** `UserFacingError` (`Core/UserFacingError.swift`) maps every `MarmotKitError` case to
  copy, using iOS wording where it exists. Internal faults read "Something went wrong"; raw core
  details never reach the UI. Non-Marmot errors are shown sanitized (nsec and long hex redacted).
- **Blocked leave.** A chat whose leave MDK parked (`leaveBlocked`) says so in its header and, when
  `canCancelLeave`, offers Cancel (`BlockedLeave.swift`).
- **Admin invitee decline.** Declining an invite that made you an admin asks first, then steps
  down (`selfDemoteAdmin`) and declines (`AdminInviteDecline.swift`). A member invitee is never
  asked.
- **This device removed.** `DeviceRemoved` reads "This device is no longer in this chat".
- **Refused queued sends.** `QueuedIntentRefused` shows a toast (`RefusedIntentNoticesViewModel`).
- **Catching up.** `RecoveryStatusChanged` drives "Catching up…" under the chat title and under the
  chat-list header (`AccountRecoveryStatusViewModel`).
- **Single-device onboarding** uses MDK's new text.
- **Custom emoji reactions** draw their image from `reactionAttachment`, one reaction at a time,
  instead of scanning `listMedia`. A miss is retried after 30 seconds, not on every render.
- **Stickers.** Sonar sticker packs (kind 30031) are found, browsed, installed and removed from the
  composer's + menu, and sent with `sendSticker`. A received sticker draws on its own; an image
  loads automatically only for your own stickers and installed packs, otherwise on a click, because
  loading contacts the pack author's server. `StickerLibrary` lives on `AccountScope`.
- **Emoji sets and custom emoji sending.** NIP-51 emoji sets (kind 30030) are browsed, previewed,
  installed with progress and Cancel, updated and removed from the emoji picker's Emoji Sets page
  (`EmojiSetLibrary`, on `AccountScope`). The composer and reaction pickers offer the built-in
  `:marmot:` and `:wn:`, installed set emoji, and emoji already in the chat. A draft using one is
  sent with `sendTaggedMedia`, each image re-encrypted into the chat and named by an
  `["emoji", shortcode, url]` tag. The draft stays until MDK accepts it, and a failure explains
  itself above the composer. A custom reaction goes out with `reactWithMedia`. The built-ins are
  drawn only where a message tags them. Untagged `:wn:` text is not drawn from the bundle yet.
- **Not adopted:** multi-device features beyond MDK's defaults, and the chat-list filters and
  search filters that open pull requests #989 and #990 cover.
