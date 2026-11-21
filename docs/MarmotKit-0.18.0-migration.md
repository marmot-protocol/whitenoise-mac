# MarmotKit 0.18.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.18.0` at MDK commit
`34646a577807f2b112ee031f3c164ec58aa18b64`. The host-side contract is MDK's
`docs/integration/0.18.0.md`; the release notes are `docs/release/0.18.0.md`.

## Storage

- **Account databases migrate from schema 207 to 216** (migrations 0208–0216) on first open. 0208
  repairs retained NIP-22 comment parents, media and accepted author edits; the rest add tables
  (changes not delivered, sign-in removals, the attachment body-removal journal, link chat
  progress, epoch-gap visits, transport stall evidence) or, in 0216, only gate the new stored
  Welcome tags so an older binary refuses the database. No message history is rewritten.
- **The shared database moves from schema 4 to 5** (migration 0005, direct-follow availability
  journals), and **each account's directory cache from 2 to 3**.
- **No downgrade.** A 0.17.0 binary refuses either upgraded database (`UnsupportedSchemaVersion`),
  which locally is a `storage_backend` startup error after switching back to an older branch. To
  roll back, restore a copy of the whole Marmot data directory taken before upgrading while the app
  was not running (leave out `accounts/*/handoff/`). For local testing, prefer the development or
  staging flavor, whose data lives apart from production's.

## Device groups are always on

Every MarmotKit build now includes multi-device, and every constructor opens with it on; there is
no off switch. Until 0.17.0 it existed only in `dev-device-groups` builds, which the app reached
through `DeviceGroupsMode` (try `newWithExperimentalDeviceGroups` in Debug and staging, fall back
on `experimental_device_groups_unavailable`) and `scripts/dev-device-groups.sh`, which built a
capable library from an mdk clone. All of that is gone: `MarmotClient` opens with
`newWithConfiguration` and reports `deviceGroupsEnabled` as true, so Settings → Devices and the link
sheets show in every flavor, production included. `deviceGroupsEnabled` stays on `MarmotRuntime`
so tests can run the fake without linking.

A nonlast admin's Leave now steps down automatically (`requiresSelfDemoteBeforeLeave` reads
false); the app already takes that flag from MDK.

## Binding changes

- **New `MarmotKitError` cases**, with copy in `UserFacingError`:
  - `GroupCommitPending(groupIdHex:)`: the group's own last commit hasn't confirmed, so group
    changes, a member's leave and an invite decline are refused. No acknowledgement releases it,
    so it does not go through `GroupChangeAdvisoryRetry`; the copy asks to try again in a moment.
  - `NoUsableRelay`: MDK may send to none of the group's relays and nothing was sent (it was
    `Publish` before). The copy offers no retry, as MDK asks.
  - `ReactionNotFound`: a reaction removal found nothing to remove. `removeReaction` treats it as
    done and shows nothing; the copy exists only for exhaustiveness.
- **`GroupEventKindFfi.GroupChangeNotDelivered`**: a direct group change whose call answered
  `CompletionUnknown` was given up, and nothing sends it again. `RefusedIntentNoticesViewModel`
  shows it with the same toast as a refused queued change, with copy for the `not_delivered` and
  `refused` reasons. The event only notifies: a change given up while its account wasn't active,
  or while the app wasn't running, is never shown (see "Not adopted yet").
- **`OnboardingActionFfi.RemoveUnusableRelays`**: advice that readiness never depends on; the app
  doesn't offer it yet.
- **New record fields.** `AppMessageRecordFfi.invalidated` has no default, so the fake's fixture
  passes `false`. The others (`DeviceLinkSnapshotFfi.chatProgress`,
  `OnboardingDevicePackageFfi.client`, `OnboardingRelayTagChangeFfi.removalReason`,
  `OnboardingRepairProposalFfi.inconclusive`, `SelectedMessageDraftAttachmentFfi.fileBacked`,
  `AttachmentStorageUsageFfi.draftBytes`) are either defaulted or never constructed by the app.

## Behavior that changed with no API change

- **Usage-diagnostics consent asks again.** The registry gains `mdk_onboarding_summary`, so its
  revision changes and a 0.17.0 grant no longer covers it: a Mac that had said yes reads
  `acceptanceRequired` again (a decline stays declined). The Mac used to ask only when an identity first entered Chats, so a Mac that
  had said yes would have stopped sharing unasked. The launch task now asks too, as iOS does, once
  `bootstrap()` has returned and the account scope that draws the sheet is installed, and the sheet
  explains that the scope changed (`DiagnosticsSettingsViewModel.promptExplanation`).
- **Inconclusive relay checks.** A relay or inbox step whose check was inconclusive can now offer
  Use Default Relays, and the proposal it builds is marked `inconclusive`: a relay that may hold
  newer settings never answered. Use Default Relays no longer approves such a proposal in the
  same press, and Approve asks "Save these relays anyway?" first; `OnboardingCoordinator
  .approveRepair` refuses one without `acceptingInconclusiveCheck`.
- **`NoUsableRelay` in the poll composer** shows the relay message, not "Try again".
- Onboarding relay checks wait up to 8 s for an answer after a 5 s connect. The app puts no
  shorter watchdog in front of them.
- NIP-22 (kind 1111) comments get their parent projected by MDK, and 0208 repairs retained ones.
- Idle accounts no longer wake every 15 s; queued messages are prepared once across retries and
  restarts; sticker and emoji reads also use the configured relays.

## Not adopted yet

- `groupPendingCommit` (show a change still going out).
- `groupChangesNotDelivered` / `acknowledgeChangeNotDelivered`: reading the given-up changes on
  account start and clearing them once shown. The binding asks hosts to read them on start, since
  the events only notify; until the app does, a leave, removal or rename given up while its account
  wasn't active stays undone with no notice. A known limitation, left for a follow-up.
- Link `chatProgress` (a joining banner while a new device receives its chats).
- Onboarding `RemoveUnusableRelays`.
- Direct-follow availability, file-backed draft attachments, `unreactFromMessageMatching`,
  `startDirectConversationWithOptions` and `attachmentRemovals`.
- Removing the `deviceGroupsEnabled` gating now that it is always true.
