# Agent Notes

Notes for automated agents working in this repo. Keep this file current when the
build/test workflow or the MarmotKit boundary changes.

## Running the app

- When validating the macOS app, keep exactly one `White Noise Dev` instance running (the Debug
  build; an installed `White Noise` and the `White Noise Staging` app are separate processes and
  may run alongside it). Do not use `open -n`; before relaunching, quit or terminate the existing
  `White Noise Dev` process, then launch a single replacement through Xcode or `just run`.
  Never quit or relaunch an installed `White Noise`: it is the user's real app.

## Build flavors

The app builds as **production** (scheme `whitenoise-mac (Production)`, configuration `Release`,
`dev.ipf.whitenoise.mac`), **development** (scheme `whitenoise-mac (Production)`, configuration `Debug`,
`dev.ipf.whitenoise.mac.dev`, product `White Noise Dev`) or **staging** (scheme
`whitenoise-mac (Staging)`, configurations `Debug-Staging`/`Release-Staging`,
`dev.ipf.whitenoise.mac.staging`, product `White Noise Staging`). Flavor values live in
`Config/AppBuild.xcconfig` (production defaults), `Config/Development.xcconfig` and
`Config/Staging.xcconfig`; the app reads its flavor from the `WhiteNoiseBuildFlavor` Info.plist key
through `Core/AppFlavor.swift`.

- Production's bundle id, product name, Application Support directory (`White Noise`), keychain
  services and URL scheme (`marmot`) are what existing installs use. Never change them.
- A new on-disk root or keychain service must be named through `AppFlavor`, not a literal: an
  unsigned build (`just run`) is unsandboxed and the login keychain is shared by service name, so
  the bundle id alone does not keep staging or development off production's data.
- Debug is never production, so a Debug build (Xcode, `just run`, the unit-test host, a
  `-uiFixture` launch) cannot read or write a real install. Debugging against real data needs a
  Release build.
- Unit tests run against the development flavor (`AppFlavorTests` asserts the host is
  development). The test host never bootstraps its own workspace (`AppLaunchConfiguration
  .isUnitTestHost`): it opens no Marmot root and connects to no relay, and every test builds its
  own workspace on a fake runtime.
- `just run` / `just reset-dev` build and wipe the development app, `just run-staging` /
  `just reset-staging` the staging app; `just sanity` asserts all three flavors' identities.
- Build, run and test as the development flavor by default (`just run`, the main scheme's Debug,
  `just test`): it is the one flavor whose data belongs to no tester or user, so it is safe on any
  Mac whatever else is installed. Use staging only for a reason — a second instance beside
  `White Noise Dev` (two devices of one account, for linking), or checking a staging build — and
  never run production to develop or test.

## Building and testing

The project builds and tests with `xcodebuild` against the `whitenoise-mac (Production)`
scheme (Apple Silicon / `arch=arm64`, code signing disabled for CI/local checks):

```sh
# Build the app
xcodebuild -scheme "whitenoise-mac (Production)" -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Build the unit-test target (catches test-only breakage without running)
xcodebuild -scheme "whitenoise-mac (Production)" -configuration Debug build-for-testing CODE_SIGNING_ALLOWED=NO

# Run the unit tests in the PR test plan
xcodebuild test-without-building -scheme "whitenoise-mac (Production)" -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO

# Run UI performance tests (requires macOS UI automation permissions)
xcodebuild test -scheme "whitenoise-mac (Production)" -configuration Debug -testPlan UIPerformance \
  -destination 'platform=macOS,arch=arm64'
```

Unit tests live in `whitenoise-macTests/`, split by domain across `TimelineTests`,
`ChatListTests`, `GroupsTests`, `MediaTests`, `SettingsTests`, `AccountTests` and
smaller focused suites, with shared fakes and helpers in
`whitenoise-macTests/Support/`. `-only-testing:` **does** select an individual
test function, which is how you iterate without paying for the full suite:

```sh
xcodebuild test-without-building -scheme "whitenoise-mac (Production)" -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -testPlan PR CODE_SIGNING_ALLOWED=NO \
  -only-testing:'whitenoise-macTests/TimelineTests/someTestName()'
```

Three details decide whether that filter matches anything, and only one of them
is loud when it is wrong:

- The **target** is hyphenated — `whitenoise-macTests`. The underscored spelling
  fails the build outright.
- The **suite** is the Swift type — `TimelineTests`, or `whitenoise_macTests`
  (underscored) for what remains of the original serialized suite. A wrong suite
  name exits **0** with `Executed 0 tests`, which looks exactly like a pass.
- The function name **keeps its trailing `()`**, quoted so the shell does not
  glob it. Without the parentheses the filter selects nothing, silently.

`-testPlan PR` is required: the scheme's default plan does not contain the test
target. Never trust the exit code of a filtered run — grep the log for
`Executed [0-9]* test` and confirm the count is what you asked for. Run the whole
suite once before handing work off; the remaining serialized tests share global
state, and order-dependent breakage only shows up in a full pass.

UI performance tests live in `whitenoise-macUITests/`, are isolated in the
`UIPerformance` test plan, and launch the app with the DEBUG-only
`-uiFixture heavy-chat` argument for deterministic chat/search/media data. The fixture
(`Core/UIFixtureWorkspace.swift`) runs the app's real bootstrap, account scope and
conversation window over `FakeMarmotRuntime`, so it opens on the heavy chat's transcript. The
transcript is an `NSTableView`: find it as `app.tables["conversation.transcript"]`.

## Test isolation on disk

Tests write real files, so every on-disk root a test double hands out is isolated
per test and per process by default — see `whitenoise-macTests/Support/TestStorageRoot.swift`.

- `FakeMarmotRuntime(accounts:)` reports a `storageRootPath` unique to the running
  test. `WorkspaceState` builds a `HiddenMessageFileStore`, `PinnedChatFileStore`,
  `ContactNicknameFileStore` and `DirectPeerMemoryFileStore` under it for every store
  the test did not inject, so a test that forgets to inject one now reads an empty
  directory instead of another test's records. Two doubles built during the *same*
  test still share a root, which is what a relaunch test needs. Pass
  `storageRoot: .explicit(path)` only to share a directory on purpose.
- `MessageMediaDiskCache.shared` — the default for `WorkspaceState`'s `mediaDiskCache`
  parameter, which almost no test overrides — resolves to a per-process temporary
  directory and a fixed in-memory key under a test run, never to the user's real
  Application Support directory or Keychain. A test that asserts on cache contents
  should still build its own with `MessageMediaDiskCache.makeIsolated()`.
- The outgoing-attachment scratch (`PickedMediaFile`, `MediaUploadSourceFiles`) likewise resolves
  to a per-process temporary root under a test run, and `MediaUploadScratch.purge()` — which every
  `bootstrap()` calls — does nothing there, since parallel suites stage into it. Test the purge
  through `purge(directories:)`.
- Do not reintroduce a fixed shared path. Isolation that has to be remembered is
  isolation that gets forgotten; `StorageRootIsolationTests` guards these properties.

## Localization

All user-facing strings live in the single String Catalog
`whitenoise-mac/Localizable.xcstrings` (source language `en`; the target
languages are whatever `knownRegions` in `project.pbxproj` lists). Edit it
through Xcode's catalog editor — it is machine-owned, and hand-editing the
nested `substitutions` of a plural entry corrupts it easily.

`just locales` (CI step "Localization coverage", part of `just precommit`) fails
when any language is incomplete. It reports a per-language coverage percentage
and flags entries that are missing, still `state: "new"`, empty, `stale`, or
have a broken plural `substitutions` set; `needsReview` is a warning unless you
pass `--strict`. Keys with no words in them (`"%lld / %lld"`, `"99+"`) are
skipped automatically — `just locales --verbose` lists them — and marking a key
"Don't Translate" in Xcode (`shouldTranslate: false`) also excludes it.

## Test coverage

`just coverage` (CI job "Coverage", part of `just precommit`) reports Swift line
coverage for the app target, read out of the `TestResults.xcresult` bundle that
`just test` leaves behind. Only first-party source under `whitenoise-mac/`
counts; the MarmotKit bindings and the test bundle are separate targets and are
filtered out. A file whose header carries `// coverage:ignore-file` is excluded
entirely — reach for that only when a file genuinely cannot be exercised from a
test, not to make a number go up.

CI does one thing more than the local recipe: it compares the run's coverage
against the number from master's most recent green run and **fails the PR when
coverage drops by more than 0.10 percentage points**. There is no baseline file
in the repo to update — every green run publishes its own coverage as the
`mac-coverage` artifact, and pull requests read master's. When no baseline is
reachable (nothing green on master inside the 90-day retention window) the
check reports the bare number and passes.

Two things the number will not tell you. Files xccov never reports are *not*
counted as 0%: they are compiled into no instrumented target, which is a target
membership problem rather than a testing one, so `just coverage` warns about
them separately. And coverage says nothing about whether a test asserts on
behavior — see the note on source-scraping tests above.

## Project structure is filesystem-synchronized

`whitenoise-mac.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup`, so source
files under `whitenoise-mac/`, `whitenoise-macTests/`, and
`whitenoise-macUITests/` are picked up automatically by path. **Adding a new
`.swift` file under one of those roots requires no `project.pbxproj` edit** —
just write it under the right directory and it joins the target on the next
build.

## The MarmotKit / MDK FFI boundary

- The Rust core lives in the [mdk](https://github.com/marmot-protocol/mdk)
  workspace (formerly "darkmatter"). The app consumes it through one pinned,
  published release: `Vendored/MarmotKit/Package.swift` declares the macOS
  XCFramework as a remote `binaryTarget` (URL + SwiftPM checksum), and the
  generated UniFFI Swift bindings are tracked next to it. **No mdk checkout is
  needed to build**, and nothing binary is committed.
- To move to another core release: `just sync-bindings <version-or-full-sha>`.
  The script verifies the binary checksum, generated Swift source hash,
  separately checksummed privacy manifest, and the release manifest's
  `source_sha` and distribution metadata before installing anything, then
  rewrites the pin and stamps `Vendored/MarmotKit/MARMOT_VERSION`. `just sanity`
  cross-checks every stamp, re-hashes the vendored `MarmotKit.swift` and
  `PrivacyInfo.xcprivacy`, and verifies the Swift package resource declaration
  — so never hand-edit generated release artifacts, re-run the sync instead.
- Device linking (Settings → Devices and the link sheets, `Features/Devices/`) runs on MDK's device
  groups, which every MarmotKit open has on since 0.18.0 (`newWithConfiguration`; there is no off
  switch). `MarmotRuntime.deviceGroupsEnabled` is always true for `MarmotClient` and exists so
  tests can run the fake without linking. `White Noise Dev` and `White Noise Staging` keep separate roots and keychain services, so the two
  can sign in to one account on one Mac and link to each other.
- A dated nightly installs the same way (`just sync-bindings 0.14.0-nightly.20261022`). Nightlies
  are for testing only and upstream deletes them after 30 days; pin a formal release before
  shipping.
- Every `Marmot` construction, tests included, passes White Noise's deployment (required since
  0.14.0): the app goes through `AppFlavor.current.marmotDeployment()`, which is
  `marmotDeploymentWhiteNoise()` untouched for production. Its keychain service is
  `com.marmot.whitenoise`, the one existing installs and `MarmotAccountKeychain` use, so never
  substitute the neutral deployment; staging only moves it to `com.marmot.whitenoise.staging`.
  `MarmotStorageRoot` excludes the Marmot root from backups: MDK keeps device-bound account
  databases and encrypted `media/` files there, and a restored copy is unreadable.
- Group changes (invite, remove, admin, profile, image, retention, and the admin step-down before
  a leave) can fail with the advisory `GroupCatchingUp` or `GroupCommitUndelivered`. Run them
  through `GroupChangeAdvisoryRetry` (`Core/GroupChangeAdvisory.swift`): ask, acknowledge only
  after consent, retry once. Acknowledgements admit one attempt and are not persisted; choosing
  Wait is a note, not an error. Each `GroupChangeAdvisoryPrompter` has exactly one alert host —
  the account's shared one (`AccountScope.groupChangeAdvisory`) is hosted in `ContentView` for
  pane changes, and a sheet that makes a change owns and hosts its own, because a window cannot
  alert from under a sheet and an unanswered prompt holds the change open.
- Group reports (`reportMessage`) are visible to the group's members, so a direct chat has none.
  Report (in groups *and* direct chats) and Block and Report also send a private copy to the White
  Noise team through `submitModerationReport` (`Features/Safety/ModerationReporter.swift`), only on
  explicit user action. MDK sends only the reported key, the reason and the optional explanation;
  never add message, group or relay ids. Block and Report sends `other` with no explanation, and
  only once the block is confirmed. The destination is the `WN_MODERATION_REPORT_PUBKEY` build
  setting (staging key in Debug, production in Release), installed with
  `configureModerationReporting` so a bad key hides the options instead of failing startup. Gate
  every report-to-White-Noise affordance on `ModerationReporter.isAvailable`; Block itself never
  depends on it. Retained outcomes (`AcceptedPending`, `CompletionUnknown`) are queued and retried
  by MDK: show them as waiting, never resubmit, and never report to the group twice on a retry.
- Since 0.17.0 `createGroup` and `inviteMembersDetailed` go ahead with the members MDK can reach and
  report every requested account in `memberOutcomes`; there is no all-or-nothing mode over the FFI,
  so never probe the roster with repeated attempts. Read the result through
  `MemberResolutionReport` (`Core/MemberResolutionReport.swift`): a missing group id / invite summary
  means nothing changed (mark the unreachable, keep the composer or sheet open); otherwise open the
  chat and name the people left out. `incomplete` is a relay read that did not finish, never an
  "unreachable" mark. `startDirectConversation` stays all-or-nothing and still throws.
- `MissingKeyPackage` (and the `obsoleteKeyPackage` outcome) carries a reason: `obsoleteOnly`
  recipients are on White Noise with an outdated app, so they get "needs to update" copy
  (`ChatCreationFailure.needsAppUpdate`), never the invite prompt or the "not on White Noise yet"
  mark.
- The audit source (`setAuditLogSource`, `TelemetryBuildConfig.auditLogSource()`) is held in memory
  only and a recorder keeps the source it opened with, so it is set on every launch before accounts
  come online. The v4 whole-file upload is gone since 0.17.0.
- Documents open in another app (and Shared Media → Save As copies) from MDK's
  `openAttachmentHandoff` lease on the original slot (`Core/AttachmentHandoff.swift`), not a host
  plaintext export; in-app display and playback stay on `readAttachmentAsset`. Release the lease
  once the surface is done (idempotent; retry `Io`/`StorageClosed` on whichever runtime is open).
  Cancel a copy only through its `MediaFileTransferControlFfi`, never by cancelling the awaiting
  task. Only bytes MDK holds no slot for (an own send still going out) use the host export.
- Outgoing attachments may reach MDK's 512 MiB blob limit (`Core/MediaFileUpload.swift`). Read
  picked files through `PickedMediaFile` (an unlinked, mapped clone), never into resident memory;
  images keep the 50 MB `maxImageSourceBytes` because they are decoded. The composer refuses an
  attachment that would take one send past `maxFileMediaCiphertextBytes()`. MDK's draft API copies
  every attachment on each save, so until marmot-protocol/mdk#3431 lands, attachments over
  `maxDraftAttachmentBytes` are left out of saved drafts, are not uploaded ahead of Send, skip the
  host media cache, and their message goes through `uploadMediaFilesWithClientToken` (anything
  smaller keeps the byte upload).
- Settings → Storage → Manage Storage (`ManageStorageViewModel`) reads MDK's attachment storage
  figures and removes in bulk. Bulk removals report counts, not hashes, so every removal runs the
  shell's `attachmentsDidChange` hook, which clears the host media cache.
- The account list (`WorkspaceState.accounts`) is MDK's, mirrored by `AccountRoster`
  (`Core/AccountRoster.swift`), its only writer. After changing an account, call
  `accountRoster.reload(from:)` instead of reading `listAccounts` and saving the result: reloads
  install in order, so a read taken before MDK changed an account (an unlink from another device,
  say) can never land after a newer one. Decide what to show next from `accounts` after the reload,
  not from a list you read yourself.
- Show a `MarmotKitError` to the user through `UserFacingError.message(for:)`, never its
  `localizedDescription`. Its switch is exhaustive on purpose: a new core error case fails the
  build until it has copy.
- Custom emoji (`Features/CustomEmoji/`) are the one place an uploaded media reference is sent
  later rather than in the upload call: upload with `send: false`, then `sendTaggedMedia` /
  `reactWithMedia` naming each image with an `["emoji", shortcode, locators[0]]` tag. Never fetch a
  tag URL, never reuse a reference in another chat, and re-encrypt once on `MediaReferenceStaleEpoch`.
  Stickers (`sendSticker`) and emoji sets live on `AccountScope`. Loading a sticker or a set preview
  contacts a server the author chose, so that happens only on a deliberate action or for an installed
  pack.
- The built-in emoji (`CustomEmojiBuiltins`: `:marmot:`, `:wn:` and the `:marmot_*:` expressions)
  ship as asset data sets with the same PNG bytes as White Noise for iOS. `:marmot:` and the
  expressions are 128 px pixel art; `:marmot_classic:` is the previous 72 px `:marmot:`. Keep them
  byte-identical with iOS, never revert to match a client still on the classic image. Product
  names (Marmot, White Noise) are spoken untranslated; the expressions' VoiceOver names are catalog
  keys.
- The published macOS XCFramework is `aarch64-apple-darwin` only — there is no
  Intel or universal build upstream, so the app stays arm64-only.
- `MarmotRuntime` (in `Core/MarmotClient.swift`) is the `nonisolated` protocol the
  app calls; the concrete `MarmotClient` forwards thinly to the generated `Marmot`
  object, and `FakeMarmotRuntime` mirrors it. **Adding an FFI method means updating all
  three.** The fake and the test support it needs live in `whitenoise-mac/DebugSupport/`,
  compiled into DEBUG builds only (and ignored by coverage) so the UI fixture can run on it;
  the tests use it through `FakeMarmotRuntime(accounts:)`, which keeps the per-test storage root.
- Projection subscriptions are owned below `Session/AccountScope.swift` and use
  cancellation-aware `nextCancellable()` bridges. Since 0.16.0 MarmotKit generates five of them
  (chat list, chat-list window, account attention, conversation window, block list); the
  vendored `CancellableProjectionNext.swift` keeps only the ones it does not, and each must be
  deleted there when the generated source starts declaring it. Prepared chat rows, account
  attention, conversation windows, transfer snapshots, block lists, and
  onboarding snapshots are complete replacements; do not merge them with an
  older snapshot or restart per-row enrichment.
- MarmotKit 0.10.4 upgrades account databases through migrations 57–89, 0.11.0
  through 90–98, 0.12.0 through 99–101, 0.13.0 through 102–107, 0.14.0 through 108–116
  (plus the directory cache from schema 1 to 2), and 0.15.0 through 117–153, 160–180, 200 and 201
  (schema 116 → 201). 0.16.0 leaves account databases alone but moves `shared.sqlite3` from
  schema 3 to 4, which 0.15.0 refuses. 0.17.0 moves account databases through 202–207 (schema
  201 → 207), which 0.16.0 refuses. 0.18.0 moves account databases through 208–216 (schema
  207 → 216), `shared.sqlite3` from 4 to 5 and the directory cache from 2 to 3, which 0.17.0
  refuses. 0.19.0 moves account databases through 217–218 (schema 216 → 218), which 0.18.0
  refuses. An older app must not
  reopen an upgraded database (0.10.4 refuses a 0.11.0 one with `UnsupportedSchemaVersion`; locally that
  shows as a `storage_backend` startup error after a branch switch). 0.14.0 also rekeys every
  database once to a raw SQLCipher key, which 0.13.0 cannot open at all, so the only way back is a
  copy of the account directory taken before the upgrade; see
  `docs/MarmotKit-0.10.4-migration.md`, `docs/MarmotKit-0.11.0-migration.md`,
  `docs/MarmotKit-0.12.0-migration.md`, `docs/MarmotKit-0.14.0-migration.md`,
  `docs/MarmotKit-0.15.0-migration.md`, `docs/MarmotKit-0.16.0-migration.md`,
  `docs/MarmotKit-0.17.0-migration.md`, `docs/MarmotKit-0.18.0-migration.md` and
  `docs/MarmotKit-0.19.0-migration.md`.
- NIP-22 thread messages (kind 1111) are chat. MDK marks each one with `thread` (root and parent,
  kept on a deleted row) on timeline records and reply previews, and counts it wherever kind 9
  counts: unread, mentions, read position, notifications, search, author edits. Recognise one by
  `MessageItem.isThreadMessage(kind:thread:)`, never by parsing its tags; a kind 1111 without
  `thread` is a custom event. The Mac has no thread view, so it draws a thread message as an inline
  reply and answers any row with `replyToMessage`, not `sendThreadMessage`. Admin removal stays
  kind 9 only.
- Start a direct chat with `startDirectConversation` (both accounts founding admins, retry-safe),
  not `createGroup` plus a promotion. The one exception is an explicitly requested *additional*
  direct chat with someone, which that call would answer with the existing one.
- 0.11.0 hosts must surface and let the user dismiss "history may be incomplete"
  notices: a parked loss keeps the account's transport cursor fenced until dismissed.
  `HistoryNoticesViewModel` on `AccountScope` owns this, re-reading on the runtime's
  `historyNoticesChanged` event.
- FFI value records crossing the off-main boundary (`WorkspaceState.runOffMain`)
  no longer need app-side `Sendable` conformances: since UniFFI 0.29 the
  generated module declares (checked) `Sendable` on them itself, which is why
  `Core/MarmotConcurrency.swift` is gone. If a new FFI type is rejected as
  non-`Sendable`, check the generated `MarmotKit.swift` before adding a
  retroactive conformance here — a duplicate is a build warning, not a fix.
  Conversions from FFI types into the app's own value types live in
  `Core/MarmotMapping.swift` — those projections are `struct`s, not view models.

## Architecture

The app is mid-refactor out of a `WorkspaceState` god object. Everything below is a contract for
**new** code — existing code is migrated one feature at a time, never swept — and none of it is
gated. The migration order is: break the test monolith open, then `AccountScope`, then delete
`lastError` as a global channel, then Settings as the first feature/view-model/service slice, then
the view layer.

**The layer direction is `App → Session → Features → Core`, and nothing below reaches up.** `App` is
the shell that composes everything (`whitenoise_macApp`, `ContentView`). `Session` owns per-launch
and per-account lifetime. `Features` are self-contained panes that own their own state. `Core` is
view-agnostic services and value types. A `Core` type never imports a feature, and no layer reads
the layer above it.

Where the tree actually stands, measured at `04cf5e0` — quote these numbers rather than guessing,
and never write a rule's target as though it were already true:

| | Today |
| --- | --- |
| `WorkspaceState` family | 17,424 lines across 33 files (`WorkspaceState.swift` + 32 `WorkspaceState+*.swift`) |
| `@Environment(WorkspaceState.self)` reads | 121, spread over 51 files |
| computed `var …: some View` | 351 |
| `#Preview` blocks | 5, against 280 `View` structs |
| `…Generation` stored properties | 38 |
| view models | 0 |
| `Session/`, `Features/`, `AccountScope` | do not exist yet |

The rules, in the order they are most often broken:

- **`WorkspaceState` is frozen.** Never add a stored property to it, never add a feature method to
  it, and never add a 34th `WorkspaceState+*.swift` file — 33 is a ceiling, not a running total.
  New feature state goes on a `@MainActor @Observable final class <Feature>ViewModel` in its own
  file. *(No example in the tree yet; the Settings slice writes the first one.)*
- **Account-scoped state goes on `AccountScope`**, an object whose lifetime is one signed-in
  account, so switching accounts destroys the state instead of running a reset checklist against
  it. *(No example in the tree yet. Until there is one, do not grow
  `resetActiveAccountUIState()` and its private helper — 51 statements between them, and both are
  scheduled for deletion.)*
- **A new `…Generation` counter needs a written reason, at the declaration, why cancelling the
  owning scope's task cannot do the job.** Hand-rolled staleness tokens are a failure mode this
  refactor exists to remove: a trailing fire-and-forget task steals the counter, the test passes
  locally, and it flakes only in CI. There are 38 of them; the 39th without that comment is a
  review rejection.
- **A feature view takes its model through `init`** — `let model: RelaySettingsViewModel`, not
  `@Environment`. `@Environment(WorkspaceState.self)` is reserved for the app shell. A dependency
  that is invisible in the initialiser is one nobody can substitute, which is why views are
  currently untestable and unpreviewable.
- **Every new view gets a `#Preview`.** If you cannot write one, the view depends on something it
  should not; fix the dependency rather than skip the preview. This is the cheapest possible check
  that the rule above was actually followed.
- **No new computed `var …: some View`.** Extract a `View` struct instead. A computed property
  shares its parent's observation set, so it re-renders whenever anything the parent reads changes;
  a struct observes only what it is given.
