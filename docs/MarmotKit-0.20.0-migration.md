# MarmotKit 0.20.0 migration boundary

`develop` pins the Release Candidate `marmotkit-v0.20.0-rc.2` at MDK commit
`a3228a2c572f2c91bbc5948160bbe890f20888a2` (verified `origin/canary`, `minor` against `v0.19.0`) for
AI agent support (marmot-agents kinds 1201 and 1202). It replaces the dated nightly
`0.20.0-nightly.20261126` (`ca52a04`), which it contains. RCs are deleted upstream after 30 days,
so `master` takes Stable 0.20.0 once MDK promotes it (`just promote-stable`; see
[release-flow.md](release-flow.md)). MDK's own notes for the whole step:
[rc/integration-notes.md](https://github.com/marmot-protocol/mdk/blob/rc-meta/rc/integration-notes.md).

## Storage

- **Account databases migrate from schema 218 to 227** on first open (0219–0227: agent item order,
  which also drops every kind-1202 timeline row, chat activity creation fallback, expired agent
  item targets, small-state broadcast devices, local deletion invitation, epoch-gap evidence floor,
  welcome delivery ledger, refused local submissions, welcome expiry mark). A new, empty account
  database now starts from a migration baseline instead of replaying every migration.
- **No downgrade.** A 0.19.0 binary refuses a migrated account database (`UnsupportedSchemaVersion`,
  locally a `storage_backend` startup error after switching back to an older branch). Test with the
  development or staging flavor.
- A database the nightly took to 226 moves on to 227 under the RC.

## Binding changes

- **Agent items.** `TimelineMessageRecordFfi` gains `agentItem: AgentItemFfi?` (the item's latest
  version: state, title, type, `fieldsJson`, `settles`, `alerts`…) and
  `agentItemFirstEventMissing`; `TimelineUpdateTriggerFfi` gains `.agentItem`. MDK keeps no row for
  kind 1202. The app reads items in `Core/AgentItem.swift` and draws them in `Features/Agents/`.
- **`sendCustomEventWithClientToken`** sends kind 1202 answers and controls crash-safely; it joins
  `MarmotRuntime`, `MarmotClient` and `FakeMarmotRuntime`.
- **`LocalSendStatusFfi`** names the event on `.queued(messageIdHex:)` and `.engineOwned`, and adds
  `.refusedNewMembers` (not sent: the group gained a member the send leaves out; final). The app
  treats it like `.rejected`.
- **`MarmotKitError.IncompatibleKeyPackage`** asks the recipient to update; it gets the existing
  out-of-date copy. **`MarmotKitError.RelayCheckRunning`** (a relay check is already running) gets
  its own line; the app does not start relay checks yet.
- **`OnboardingIssueFfi.rateLimited`**: a relay is rate limiting; account setup shows it under its
  step.
- **`TimelineReplyPreviewFfi`** carries the quoted message's pinned retention
  (`retentionSeconds`, `retentionExpiresAt`); the app does not read it yet.
- **Added, not yet used:** `accountRelayHealth`/`checkAccountRelays` (inbox relay health),
  `inviteDeliveries`, the `submitTagged*`/`submitThreadMessage` crash-safe sends, and
  `OnboardingSnapshotFfi.createdInboxList`.
- **Generated cancellable `next`.** `OnboardingSubscription` and `EventsSubscription` now ship
  `nextCancellable()`, so their hand-written adapters left `CancellableProjectionNext.swift`.
