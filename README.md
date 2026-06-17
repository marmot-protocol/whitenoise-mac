# White Noise for macOS

A native macOS client for **Marmot Protocol** — MLS-based end-to-end encrypted
group messaging over Nostr. White Noise is a SwiftUI app that wraps the
[darkmatter](https://github.com/marmot-protocol/darkmatter) Rust core (the MLS/CGKA
engine) through a vendored `MarmotKit` framework, giving you sovereign, private
communications in a single-window Mac experience.

> Bundle identifier: `dev.ipf.whitenoise.mac` · Display name: **White Noise**

## Status

Early-stage client. The UI surface (chat list, conversations, composer,
settings) is functional and driven by a single shared workspace state; the
cryptographic and protocol heavy lifting lives in the Rust core surfaced via
`MarmotKit`.

## Requirements

- **macOS 15.6+** (deployment target; the app is sandboxed and arm64-only)
- **Xcode** with the Swift 6 toolchain (project compiles in Swift 5 language
  mode against the Swift 6 tools)
- Apple Silicon Mac — the vendored `MarmotKit.xcframework` ships
  `aarch64-apple-darwin` artifacts only
- A checkout of the [darkmatter](https://github.com/marmot-protocol/darkmatter) Rust
  workspace *only if you need to regenerate the MarmotKit bindings* (see below)

## Repository structure

```text
.
├── AGENTS.md                  Notes for automated agents working in this repo
├── Config/                    Build settings and app metadata
│   ├── AppBuild.xcconfig       Shared non-secret Debug/Release build settings
│   ├── AppSecrets.xcconfig.example  Template for optional non-secret local settings
│   └── Info.plist              App bundle metadata + non-secret telemetry keys
├── scripts/
│   └── sync-bindings.sh        Rebuilds & re-vendors MarmotKit from darkmatter
├── Vendored/
│   └── MarmotKit/              SwiftPM binary target wrapping the Rust core
│       ├── Package.swift        Kept in git; the rest is generated/gitignored
│       ├── MarmotKit.xcframework/   Compiled Rust static lib + headers (generated)
│       ├── Sources/MarmotKit/   Generated UniFFI Swift bindings (generated)
│       └── MARMOT_VERSION        Provenance stamp of the vendored core (generated)
├── whitenoise-mac/            App target source
│   ├── whitenoise_macApp.swift  @main entry; single `Window` scene
│   ├── ContentView.swift        Root view
│   ├── Core/                    App services & the bridge to MarmotKit
│   ├── Models/                  View models / data types (MessengerModels.swift)
│   ├── Views/                   SwiftUI views (MessengerShellView.swift)
│   ├── Assets.xcassets          Colors, accent color, image assets
│   ├── AppIcon.icon             App icon source
│   ├── Localizable.xcstrings     String catalog (localization)
│   └── whitenoise-mac.entitlements  App sandbox + network client entitlements
├── whitenoise-macTests/       Unit tests
├── whitenoise-macUITests/     UI tests
└── whitenoise-mac.xcodeproj/  Xcode project
```

### Core layer (`whitenoise-mac/Core/`)

| File | Responsibility |
| --- | --- |
| `MarmotClient.swift` | Bridge protocol/runtime into the Rust core; `nonisolated` so FFI calls run off the main thread. |
| `WorkspaceState.swift` | The single observable app state (selection, search, drafts, reply context, sheet flags). Drives the whole UI. |
| `MarmotMapping.swift` | Maps Rust/FFI value types into app view models. |
| `MarmotConcurrency.swift` | `@retroactive` unchecked-`Sendable` conformances for UniFFI value records crossing the off-main boundary. |
| `RemoteImageLoader.swift` | Off-main remote image loading + downsampling + caching (an `AsyncImage` replacement). |
| `AppLanguage.swift` / `L10n.swift` | In-app language selection and localized string lookup. |
| `NativeAppearanceController.swift` | Light/dark appearance control. |
| `TelemetryBuildConfig.swift` | OTLP telemetry + audit-log runtime configuration. Bearer credentials are launch-environment only and are never bundled. |
| `ConversationTranscriptExport.swift` | Chronological JSON export of inner Marmot/Nostr events for debugging. |

## Building and running

1. **Clone the repo** and open it in Xcode:

   ```sh
   git clone https://github.com/marmot-protocol/whitenoise-mac.git
   cd whitenoise-mac
   open whitenoise-mac.xcodeproj
   ```

   The vendored `MarmotKit.xcframework` is committed-as-generated and resolved
   through the local SwiftPM package in `Vendored/MarmotKit`, so a fresh clone
   builds without a darkmatter checkout in the common case.

2. **(Optional) configure local observability.** Telemetry/audit-log bearer
   tokens are runtime credentials, not build settings. To test uploads locally,
   add launch environment variables in the Xcode scheme (or launch the app from
   a shell with them set):

   ```sh
   DARKMATTER_OTLP_BEARER_TOKEN=...
   DARKMATTER_AUDIT_LOG_BEARER_TOKEN=...
   ```

   The built app bundle intentionally does not contain bearer tokens. Use
   `Config/AppSecrets.xcconfig` only for non-secret local build settings.

3. **Select the `whitenoise-mac` scheme** and build/run (⌘R) on a "My Mac"
   destination.

> The app uses a single `Window` scene (not `WindowGroup`) intentionally — the
> whole UI is driven by one shared `WorkspaceState`, so multi-window is
> disabled by design (no ⌘N).

## Regenerating MarmotKit bindings

The contents of `Vendored/MarmotKit/` (the `.xcframework`, the generated Swift
bindings, and `MARMOT_VERSION`) are produced from the `marmot-uniffi` crate in
the darkmatter Rust workspace. To rebuild them after a core change:

```sh
# Assumes darkmatter is checked out at ~/code/darkmatter; override with DARKMATTER_DIR.
DARKMATTER_DIR=/path/to/darkmatter ./scripts/sync-bindings.sh
```

The script builds the Rust crate in release mode, generates the UniFFI Swift
bindings, assembles the `MarmotKit.xcframework`, and stamps `MARMOT_VERSION`
with the darkmatter commit SHA, branch, and build time. A `-dirty` suffix in
`MARMOT_VERSION` means the darkmatter working tree had uncommitted changes at
build time. Requires the Rust toolchain (`cargo`) and Xcode command-line tools.

## Testing

Run the tests from Xcode (⌘U) or via `xcodebuild`:

```sh
xcodebuild test \
  -project whitenoise-mac.xcodeproj \
  -scheme whitenoise-mac \
  -destination 'platform=macOS'
```

- `whitenoise-macTests/` — unit tests (run by the shared scheme above)
- `whitenoise-macUITests/` — UI tests (the `whitenoise-macUITests` target is
  marked skipped in the shared scheme, so the command above runs the unit
  target only; enable it in the scheme's Test action, or pass
  `-only-testing:whitenoise-macUITests`, to run the UI suite)

When validating the running app, keep exactly one `White Noise` instance alive
(see `AGENTS.md`): do not use `open -n`; quit/terminate the existing process
before relaunching.

## Security & privacy

White Noise runs in the macOS **App Sandbox** with a minimal entitlement set:
network client access (for Nostr relays) and read-only access to user-selected
files. End-to-end encryption, group state, and key management are handled by
the Marmot/MLS core in `MarmotKit` rather than in app code.

## License

No license file is currently present in this repository. Until one is added,
all rights are reserved by the project authors.
