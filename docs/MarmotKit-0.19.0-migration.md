# MarmotKit 0.19.0 migration boundary

White Noise for macOS now pins `marmotkit-v0.19.0` at MDK commit
`3fce95465cdea1edc8456dbd1c6691d1c8dc1f2e`. The host-side contract is MDK's
`docs/integration/0.19.0.md`; the release notes are `docs/release/0.19.0.md`, and the reply and
thread contract is `docs/marmot-architecture/overview/thread-messages.md`.

## Storage

- **Account databases migrate from schema 216 to 218** on first open. 0217 repairs older White
  Noise Linux kind-1111 thread messages that carry a lowercase `e` and no numeric `k` (their
  parent, media, author edits and media-key references); 0218 drops the agent text stream tables,
  the stream timeline column and the kind-1200 stream-start rows. Durable kind-9 agent replies
  survive. Chat-list projection version 5 also rebuilds every list row once, so the first open of
  a large account takes longer.
- **The shared database (5) and directory cache (3) keep their 0.18.0 schemas.**
- **No downgrade.** A 0.18.0 binary refuses a migrated account database
  (`UnsupportedSchemaVersion`, locally a `storage_backend` startup error after switching back to an
  older branch). To roll back, restore a copy of the whole Marmot data directory taken before
  upgrading while the app was not running (leave out `accounts/*/handoff/`). For local testing,
  prefer the development or staging flavor.

## Binding changes

- **Agent text stream removed.** `startAgentTextStream`, `watchAgentTextStream`,
  `openAgentPublisher`, their handles and DTOs, `MarmotEventFfi.agentStreamActivity`,
  `MessageUpdateFfi.agentStreamStarted`, both stream triggers of `TimelineUpdateTriggerFfi` and
  `agentTextStreamJson` on timeline records and reply previews are gone. The app only drew the
  kind-1200 start row, so `MessagePresentation.agentStreamStart`, its two "Agent started…" strings
  and the transcript export's `agent_text_stream_json` field go with it. A kind 1200 that still
  reaches the app falls to the unsupported row; MDK no longer surfaces any.
- **Thread placement.** `TimelineMessageRecordFfi` and `TimelineReplyPreviewFfi` gain
  `thread: TimelineThreadRefFfi?` (root and parent), and reply previews gain their own
  `replyToMessageIdHex`. The transcript export writes `thread_root_message_id_hex` and
  `thread_parent_message_id_hex` in place of the stream field.
- **`MessageDraftAttachmentInputFfi.removed(id:)`** and keep-unnamed semantics for
  `saveMessageDraftInputsIfRevision`. The app now saves every draft this way (see "File-backed
  draft attachments").
- **`sendThreadMessage`** is for clients with a thread view. The Mac has none, so, as MDK asks,
  it keeps answering every row, thread messages included, with `replyToMessage` (a kind-9 inline
  reply).

## Thread messages are chat

Since 0.18.0 the app drew a NIP-22 comment as a reply when it carried a numeric `k` tag, MDK's
rule at the time, and kept it out of read tracking. 0.19.0 replaces that rule: MDK marks every
thread message with `thread`, a deleted one too, and treats it as chat everywhere kind 9 counts
(chat-list order and preview, unread, mentions, the sender's read position, notifications, search,
author edits). Hosts are told never to parse the tags. The app now follows that:

- `MessageItem.isThreadMessage(kind:thread:)` is kind 1111 with `thread` set. Such a row draws as a
  chat bubble quoting its parent, search finds it and its author's edits apply live. A kind 1111
  without `thread` (no parent, or no NIP-22 marks) stays an app-defined event, whatever its tags.
- A deleted thread message keeps its `thread`, so it stays its author's deleted bubble; the old
  `replyToMessageIdHex` fallback is gone.
- A reply preview of a thread message reads its `thread` the same way, and a chat-list preview of a
  kind 1111 is always one (MDK previews chat activity only).
- `countsAsReadActivity` now counts thread messages: MDK accepts one as the read-marker target
  (`chat_list_activity_filter_sql`: kind 1111 with a reply target), so reading one marks the chat
  read up to it.
- Admin removal stays kind 9 only, unchanged.

## File-backed draft attachments

MDK has held draft attachments as files since 0.18.0 (mdk#3431), and 0.19.0's keep-unnamed save
makes them safe to use; the app adopts both. Before, MDK's draft API copied every attachment's
bytes on each save, so anything over 50 MB was left out of saved drafts and a relaunch lost it.

- `ComposerDraftStore` owns the draft's persistence. An attachment over `maxInlineAttachmentBytes`
  (the renamed `maxDraftAttachmentBytes`, still 50 MB) is copied into the draft as a file as soon
  as it joins the composer (`stageMessageDraftAttachmentFile`, from a scratch copy removed once the
  call returns). Smaller ones still go in inline, on their first save only.
- Every save, debounced or at termination, is `saveMessageDraftInputsIfRevision`: a held
  attachment is `.retained` (never copied again), a new small one `.inline`, a large one still
  copying is left unnamed (so the save cannot drop it), and one the composer dropped is
  `.removed`. A revision conflict re-reads the draft and retries, up to three times.
- The copy runs as the attachment's task in `pendingMediaUploadTasks`, so removing the attachment,
  sending, or dropping the draft cancels it. Once a copy lands the app saves again, which names
  the file or, if the user removed the attachment meanwhile, removes it. A clear (empty composer or
  Send) discards a copy still in flight; that conflict is silent.
- The async flush (sign-out, account switch) waits for copies still landing before it saves. The
  termination flush cannot wait, so quitting while a file is still copying saves the draft without
  it, as every large attachment was before this change.
- Before copying, the app removes the stored attachments the composer no longer holds, since MDK
  measures the copy against everything the draft holds (a replaced audio file would count twice).
- Restore reads a file-backed attachment through `openMessageDraftAttachmentHandoff`, clones and
  maps the handoff copy (`PickedMediaFile`) and releases the lease, so a large draft never becomes
  resident memory. It is not uploaded ahead of Send on restore either.
- Send is unchanged: it uploads from the composer's own mapped bytes
  (`uploadMediaFilesWithClientToken`) rather than `uploadMessageDraftAttachments` /
  `sendMessageDraft`, and clearing the sent draft releases its files.
- `MarmotRuntime` swaps `saveMessageDraftIfRevision` for `saveMessageDraftInputsIfRevision` and
  gains `stageMessageDraftAttachmentFile` and `openMessageDraftAttachmentHandoff`.

## Linked devices

The 0.19.0 device-group fixes are inside MDK and need no app change; the app shows invitation state
from MDK's projections and has no retry loop of its own:

- An invitation answer whose device-group update, or the commit carrying it, lost a fork between
  linked devices is sent again on the worker's next turn (mdk#3573, mdk#3594). Before, the other
  device could keep showing the invitation as pending.
- A sign-out held by a device removal no longer wakes maintenance every 15 s until the hold lifts.

## Behavior that changed with no API change

- Every account republishes its KeyPackage once, dropping the retired stream `send` and `fanout`
  roles. New groups omit the stream component (`0x8006`); existing groups that require it keep
  working.
- A fresh thread message can bring back a locally deleted chat, as a fresh kind-9 message does.
- `url` 2.5.9 in MDK's lockfile (RUSTSEC-2026-0592).

## Not adopted yet

- A thread view and `sendThreadMessage` (mdk#2787 covers thread graphs and windows).
- Sending a draft through `uploadMessageDraftAttachments` and `sendMessageDraftWithClientToken`,
  which would upload a large attachment from the file the draft already holds.
- Everything listed under "Not adopted yet" in `docs/MarmotKit-0.18.0-migration.md`.
