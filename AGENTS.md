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

Unit tests live in `whitenoise-macTests/` and use Swift Testing in a single
`@Suite(.serialized)` struct; the runner's per-test `-only-testing:` filter does
not reliably match individual functions in that serialized suite, so prefer
running the whole suite. UI performance tests live in `whitenoise-macUITests/`,
are isolated in the `UIPerformance` test plan, and launch the app with the
DEBUG-only `-uiFixture heavy-chat` argument for deterministic chat/search/media
data.

## Never test by reading source

**A test must never open a `.swift` file and assert on its text.** No `String(contentsOf:)` over
`whitenoise-mac/`, no `source.contains("Button(action: performPrimaryAction)")`, no slicing a
declaration out of a file to check what it does or does not mention. There used to be 41 of these
and they are all gone; `whitenoise-macTests/Support/SourceContract.swift`, the helper that made them
convenient, is deleted. Do not bring it back.

They are not cheap tests, they are expensive ones that fail for the wrong reasons:

- **They fail on edits that change nothing.** Renaming a local, reflowing an argument list, moving a
  struct to another file, or `swift-format` rewrapping a line all break an assertion about text.
  Every one of those was a red CI run about a change nobody made.
- **They pass while the app is broken.** `source.contains(".buttonStyle(.plain)")` is satisfied by
  the string appearing *anywhere* in the slice — including inside a branch that is never taken, or
  on the neighbouring control. Asserting on absence is worse: it passes for a view that draws
  nothing at all.
- **They freeze the implementation instead of the promise.** "Both rows call `MessageAudioRow(`" is
  one way to hold "the bubble does not reflow when the download lands". Writing that way down turns
  a refactor into a test failure, and stops the test from noticing the day the rows drift apart
  while still sharing a call.

### What to write instead

When a decision is not observable from a test, that is a fact about the code, not about testing.
Move the decision out of the view and into a plain type the test can call — the pattern the tree is
already full of (`MessageVisualMediaTileInteraction`, `MessageBubbleLayout`, `MessagesLayout`,
`WNButtonMetrics`, `SignOutSheetDecisions`, `MessageImageGalleryNavigation`,
`AutomaticMediaDownloadCoordinator`, `MessageAudioPlaybackController`). In order of preference:

1. **Drive the model.** Call the workspace/controller method the control calls and assert on the
   state or the runtime double it moved.
2. **Hoist the decision.** An order, a gate, a table, a label — put it in a `nonisolated enum` or a
   small value type, build the view from it, and test the value. Building the view from it is not
   optional: a type nothing renders from is a test of nothing.
3. **Lay it out and measure it.** `HostedView.fittingSize(of:)` answers "do these two rows occupy
   the same space"; `HostedView.render(_:appearance:)` answers colour, tint and where something
   landed. Both are in `whitenoise-macTests/Support/HostedView.swift`.
4. **Make it structural.** Two hand-matched copies that must agree become one shared view
   (`DetailsPaneHeader`), and then nothing is left to test — a compile error replaces the assertion.

SwiftUI builds no accessibility tree unless an assistive client is attached, so a hosted view cannot
be queried for labels or pressed from a test. Do not spend time trying; hoist the decision instead.

If after all that some chrome genuinely has no observable consequence — an absent context menu, a
deleted file staying deleted — **write no test for it.** A source contract asserting the absence is
not a weaker test than nothing, it is a worse one: it will fail for an unrelated edit long before it
ever catches the thing it was written for.

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
  Conversions from FFI types into app view models live in
  `Core/MarmotMapping.swift`.
