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

# Run the unit tests
xcodebuild test-without-building -scheme whitenoise-mac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

There is no UI-test target (the empty `whitenoise-macUITests` target was removed).
Unit tests live in `whitenoise-macTests/` and use Swift Testing in a single
`@Suite(.serialized)` struct; the runner's per-test `-only-testing:` filter does
not reliably match individual functions in that serialized suite, so prefer
running the whole suite.

## Project structure is filesystem-synchronized

`whitenoise-mac.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup`, so source
files under `whitenoise-mac/` are picked up automatically by path. **Adding a new
`.swift` file requires no `project.pbxproj` edit** — just write it under the right
directory and it joins the target on the next build.

## The MarmotKit / darkmatter FFI boundary

- The Rust core lives in the [darkmatter](https://github.com/marmot-protocol/darkmatter)
  workspace, expected at `~/code/darkmatter` (override with `DARKMATTER_DIR`). The
  app consumes it through the vendored, generated `MarmotKit` Swift bindings in
  `Vendored/MarmotKit/` (committed as generated).
- To pull core changes: `git pull` in darkmatter, then
  `./scripts/sync-bindings.sh` (release Rust build + UniFFI generation + xcframework
  assembly; stamps `Vendored/MarmotKit/MARMOT_VERSION` with the darkmatter SHA).
  This is a multi-minute Rust build; run it in the background.
- `MarmotRuntime` (in `Core/MarmotClient.swift`) is the `nonisolated` protocol the
  app calls; the concrete `MarmotClient` forwards thinly to the generated `Marmot`
  object, and `FakeMarmotRuntime` in the tests mirrors it. **Adding an FFI method
  means updating all three.**
- FFI value records crossing the off-main boundary (`WorkspaceState.runOffMain`)
  need `@retroactive @unchecked Sendable` conformances in
  `Core/MarmotConcurrency.swift`. Conversions from FFI types into app view models
  live in `Core/MarmotMapping.swift`.
