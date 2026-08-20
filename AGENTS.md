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
