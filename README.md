# White Noise for macOS

A native macOS client for **Marmot Protocol** — MLS-based end-to-end encrypted
group messaging over Nostr. White Noise is a SwiftUI app that wraps the
[mdk](https://github.com/marmot-protocol/mdk) Rust core (the MLS/CGKA
engine) through the `MarmotKit` framework, giving you sovereign, private
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
- Apple Silicon Mac — the published `MarmotKit` XCFramework ships
  `aarch64-apple-darwin` only; there is no Intel or universal build upstream
- Network access on the first build, to fetch the pinned `MarmotKit`
  XCFramework. **No mdk checkout is needed** — see
  [Updating MarmotKit bindings](#updating-marmotkit-bindings).

## Repository structure

```text
.
├── AGENTS.md                  Notes for automated agents working in this repo
├── Config/                    Build settings & secrets (xcconfig + Info.plist)
│   ├── AppBuild.xcconfig       Shared Debug/Release build settings
│   ├── AppSecrets.xcconfig.example  Template for local-only secrets (gitignored copy)
│   └── Info.plist              App bundle metadata + telemetry keys
├── scripts/
│   └── sync-bindings.sh        Repins MarmotKit to a published mdk release
├── Vendored/
│   └── MarmotKit/              SwiftPM package wrapping the Rust core
│       ├── Package.swift        Pins the remote XCFramework by URL + checksum
│       ├── Sources/MarmotKit/   Generated UniFFI Swift bindings (tracked)
│       └── MARMOT_VERSION        Provenance of the pinned release (tracked)
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
└── whitenoise-mac.xcodeproj/  Xcode project
```

### Core layer (`whitenoise-mac/Core/`)

| File | Responsibility |
| --- | --- |
| `MarmotClient.swift` | Bridge protocol/runtime into the Rust core; `nonisolated` so FFI calls run off the main thread. |
| `WorkspaceState.swift` | The single observable app state (selection, search, drafts, reply context, sheet flags). Drives the whole UI. |
| `MarmotMapping.swift` | Maps Rust/FFI value types into app view models. |
| `RemoteImageLoader.swift` | Off-main remote image loading + downsampling + caching (an `AsyncImage` replacement). |
| `AppLanguage.swift` / `L10n.swift` | In-app language selection and localized string lookup. |
| `NativeAppearanceController.swift` | Light/dark appearance control. |
| `TelemetryBuildConfig.swift` | OTLP telemetry + audit-log build configuration (tokens injected at build time). |
| `ConversationTranscriptExport.swift` | Chronological JSON export of inner Marmot/Nostr events for debugging. |

## Building and running

1. **Clone the repo** and open it in Xcode:

   ```sh
   git clone https://github.com/marmot-protocol/whitenoise-mac.git
   cd whitenoise-mac
   open whitenoise-mac.xcodeproj
   ```

   `MarmotKit` resolves through the local SwiftPM package in
   `Vendored/MarmotKit`, whose binary target points at a pinned, checksummed
   XCFramework on the mdk releases page. SwiftPM downloads it on the first
   build and caches it, so a fresh clone builds with no mdk checkout at all.

2. **(Optional) configure local secrets.** Telemetry/audit-log tokens are
   build-time secrets. Copy the example and fill in values if you have them —
   the real file is gitignored and the app builds fine without it:

   ```sh
   cp Config/AppSecrets.xcconfig.example Config/AppSecrets.xcconfig
   # edit Config/AppSecrets.xcconfig
   ```

3. **Select the `whitenoise-mac` scheme** and build/run (⌘R) on a "My Mac"
   destination.

> The app uses a single `Window` scene (not `WindowGroup`) intentionally — the
> whole UI is driven by one shared `WorkspaceState`, so multi-window is
> disabled by design (no ⌘N).

## Updating MarmotKit bindings

Nothing is built locally and nothing binary is committed. `Vendored/MarmotKit`
pins one immutable, published mdk release: `Package.swift` carries the release
id, tag, and SwiftPM checksum of the macOS XCFramework, and the generated
UniFFI Swift bindings are tracked alongside it. To move to another release:

```sh
just sync-bindings 0.9.14                                    # a tagged version
just sync-bindings 235c8ade2920414679e59d7a5f1a0e78651756a4  # a master snapshot
```

The script downloads the macOS XCFramework, the shared generated Swift source,
and the release manifest, then refuses to install anything unless two checks
pass: `swift package compute-checksum` matches the published
`.swiftpm-checksum`, and the Swift source matches its `sha256` in
`checksums.txt`. Given a full SHA rather than a version, it additionally
requires the manifest's `source_sha` to equal the SHA you asked for — a tagged
version carries no SHA to compare against, so that check only applies to the
snapshot form. It then rewrites the pin in `Package.swift` and stamps
`MARMOT_VERSION` and `MarmotKitVersion.swift` from the manifest.

Requires only `curl` and Xcode command-line tools — no Rust toolchain, no mdk
checkout. `scripts/ci/macos-sanity-checks.sh` verifies that the pin in
`Package.swift` and the provenance in `MARMOT_VERSION` still agree, and that
the vendored `MarmotKit.swift` still hashes to the `swift-vendored-sha256`
stamped next to it, so hand-editing either the pin or the generated source
fails CI.

The generated `MarmotKit.swift` is platform-independent: it is the same source
`whitenoise-ios` vendors from the same release, save for the trailing
whitespace the install step strips.

## Testing

Run the tests from Xcode (⌘U) or via `xcodebuild`:

```sh
xcodebuild test \
  -project whitenoise-mac.xcodeproj \
  -scheme whitenoise-mac \
  -destination 'platform=macOS'
```

- `whitenoise-macTests/` — the unit-test target run by the shared scheme above.

When validating the running app, keep exactly one `White Noise` instance alive
(see `AGENTS.md`): do not use `open -n`; quit/terminate the existing process
before relaunching.

## Security & privacy

White Noise runs in the macOS **App Sandbox** with a minimal entitlement set:
network client access (for Nostr relays) and read/write access to user-selected
files. End-to-end encryption, group state, and key management are handled by
the Marmot/MLS core in `MarmotKit` rather than in app code.

## License

This project is licensed under the GNU Affero General Public License v3.0
(AGPL-3.0). See [LICENSE](LICENSE) for the full text.
