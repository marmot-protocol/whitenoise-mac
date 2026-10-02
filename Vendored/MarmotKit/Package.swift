// swift-tools-version:6.0
import PackageDescription

// Keep the release identifier, immutable tag, checksum, and generated Swift
// source synchronized. `scripts/sync-bindings.sh` updates them together from a
// published MarmotKit release.
let marmotKitReleaseID = "0.12.0"
let marmotKitReleaseTag = "marmotkit-v0.12.0"
let marmotKitChecksum = "344251a65ec7afcdcce8b7bb0cbf26bfcf398983a99a11bfc93181a0069621a5"
let marmotKitBinaryURL =
    "https://github.com/marmot-protocol/mdk/releases/download/\(marmotKitReleaseTag)/MarmotKitFFI-macos-\(marmotKitReleaseID).xcframework.zip"

let package = Package(
    name: "MarmotKit",
    platforms: [
        // The published macOS artifact is built for a 15.0 floor; mdk's
        // DISTRIBUTION.md requires consumers to declare 15.0 or newer.
        .macOS(.v15)
    ],
    products: [
        .library(name: "MarmotKit", targets: ["MarmotKit"])
    ],
    targets: [
        .binaryTarget(
            name: "MarmotKitFFI",
            url: marmotKitBinaryURL,
            checksum: marmotKitChecksum
        ),
        .target(
            name: "MarmotKit",
            dependencies: ["MarmotKitFFI"],
            path: "Sources/MarmotKit",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            // UniFFI's generated Swift relies on file-scope `let`/`var`
            // globals that don't satisfy Swift 6's strict concurrency
            // checking. The handle maps are protected internally by Rust-
            // side locks, so compiling this target as Swift 5 is safe and
            // doesn't infect the rest of the app.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
