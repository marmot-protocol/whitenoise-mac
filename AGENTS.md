# Agent Notes

Notes for automated agents working in this repo. Keep this file current when the
build/test workflow or the MarmotKit boundary changes.

## Running the app

- When validating the macOS app, keep exactly one `White Noise` instance running.
  Do not use `open -n`; before relaunching, quit or terminate the existing
  `White Noise` process, then launch a single replacement through Xcode or the
  built app.

## Building and testing

The project builds and tests with `xcodebuild` against the `whitenoise-mac`
scheme (Apple Silicon / `arch=arm64`, code signing disabled for CI/local checks):

```sh
# Build the app
xcodebuild -scheme whitenoise-mac -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Build the unit-test target (catches test-only breakage without running)
xcodebuild -scheme whitenoise-mac -configuration Debug build-for-testing CODE_SIGNING_ALLOWED=NO

# Run the unit tests in the PR test plan
xcodebuild test-without-building -scheme whitenoise-mac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO

# Run UI performance tests (requires macOS UI automation permissions)
xcodebuild test -scheme whitenoise-mac -configuration Debug -testPlan UIPerformance \
  -destination 'platform=macOS,arch=arm64'
```

Unit tests live in `whitenoise-macTests/`, split by domain across `TimelineTests`,
`ChatListTests`, `GroupsTests`, `MediaTests`, `SettingsTests`, `AccountTests` and
smaller focused suites, with shared fakes and helpers in
`whitenoise-macTests/Support/`. `-only-testing:` **does** select an individual
test function, which is how you iterate without paying for the full suite:

```sh
xcodebuild test-without-building -scheme whitenoise-mac -configuration Debug \
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
`-uiFixture heavy-chat` argument for deterministic chat/search/media data.

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
  The script verifies the binary checksum, the generated Swift source hash, and
  the manifest's `source_sha` before installing anything, then rewrites the pin
  and stamps `Vendored/MarmotKit/MARMOT_VERSION`. `just sanity` cross-checks
  that the pin and the stamp still agree, and re-hashes the vendored
  `MarmotKit.swift` against the stamp — so never hand-edit the generated
  source, re-run the sync instead.
- The published macOS XCFramework is `aarch64-apple-darwin` only — there is no
  Intel or universal build upstream, so the app stays arm64-only.
- `MarmotRuntime` (in `Core/MarmotClient.swift`) is the `nonisolated` protocol the
  app calls; the concrete `MarmotClient` forwards thinly to the generated `Marmot`
  object, and `FakeMarmotRuntime` in the tests mirrors it. **Adding an FFI method
  means updating all three.**
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
