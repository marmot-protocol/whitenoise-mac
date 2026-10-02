# MarmotKit 0.12.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.12.0` at MDK commit
`122bd90ffac60bb6311346e228d0f609a18521ee`. The host-side contract is MDK's
`docs/integration/0.12.0.md`; the release notes are `docs/release/0.12.0.md`.

## Storage

The first open of each account database runs MDK migrations 99–101. They add a column, a trigger
and two small tables (missing-key attachment deferrals, explicit attachment priority, sent-file
retention) and rewrite no message history. As with 0.11.0 this is a one-way boundary: a 0.11.0
binary refuses the upgraded database, which locally shows up as a `storage_backend` startup error
after switching back to an older branch. Use a separate container, or restore a copy.

## Binding changes

- `ConversationReactionFfi.reactionMessageIdHex` has no binding default; the test fixtures that
  build reactions pass `nil`.
- `MarmotKitError.InvalidAppComponent` is returned only by the app-component methods, which the app
  does not call. Nothing switches exhaustively over `MarmotKitError`.
- `createIdentityWithProfile` and `login` gained `inboxRelays`, and `OnboardingOptionsFfi` gained
  `inboxRelays`. The app passes all three explicitly (see below).

## Separate inbox relays for new accounts

New accounts and imports declare different lists:

- NIP-65 (kind 10002): `MarmotClient.accountRelays` — the White Noise seed relays plus
  `nos.lol`, `relay.primal.net` and `whitenoise.nostrdev.com`. White Noise relays accept only the
  event kinds White Noise needs, so other Nostr clients need the general-purpose ones.
- Inbox (kind 10050): `MarmotClient.seedRelays` only.
- Bootstrap and discovery stay on the seed relays.

This matches the iOS app. `OnboardingOptionsFfi` carries the same split, so the account-setup
"Use Default Relays" repair recommends `accountRelays` for the relay list and the seed relays for
the inbox. Settings' "Restore default relays" restores each list to its own default
(`RelayRole.defaultRelays`), so an existing account whose lists both hold only the seed relays no
longer counts as the default configuration.

## Explicit attachment requests

Tapping or saving an attachment in the shared-media views now calls `requestExplicitAttachment`,
which promotes live or not-yet-requested work without resetting its retry budget, backoff or
partial progress. MDK leaves cancelled, removed, failed and exhausted work to a deliberate
download-again, so `AttachmentViewModel.downloadExplicitly` still calls `downloadAttachmentAgain`
for those states (and for policy-blocked or no-longer-retained sources); otherwise the tap would do
nothing. The overflow menu's Retry stays on `controlAttachment(.retry)`.

## Changed defaults, accepted as-is

- **Muted chats notify on direct mentions.** A durable mute still silences ordinary messages, but
  a direct mention of the account now reaches the notification subscription with
  `isMention = true`. Blocked senders stay silent. The app does not filter on mute itself, so
  mentions in muted chats now post a banner. This is deliberate; no mute copy promises total
  silence.
- **Sent files are retained locally** for the sender, best-effort and bounded, so they reopen
  without downloading again.
- **Missing-key attachment deferrals fail** after about eight minutes instead of retrying forever.
- **Recovery parks behind a dead relay** and raises the existing "history may be incomplete"
  notice, which `HistoryNoticesViewModel` already surfaces.

## Not adopted yet

- **NIP-30 custom emoji** (upstream: strongly recommended). Peers on 0.12.0 can send them; until the
  app renders them, chats and reaction chips show the literal `:shortcode:`. Rendering — the
  `emoji` tags already reach `MessageItem.tags`, and reaction images resolve through
  `reactionMessageIdHex` and `listMedia` — is the next PR. Sending needs a product decision on where
  a user's custom emoji come from.
- **Per-voter poll results** (`pollVotes`): a follow-up "View votes" sheet. Polls are not anonymous;
  that sheet must say so.
- **Application-owned group components**: no current use.

MDK #2086 is still open: a large catch-up can strand undecryptable messages without raising a
notice.
