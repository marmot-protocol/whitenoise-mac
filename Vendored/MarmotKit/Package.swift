// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MarmotKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MarmotKit", targets: ["MarmotKit"])
    ],
    targets: [
        .binaryTarget(
            name: "MarmotKitFFI",
            path: "MarmotKit.xcframework"
        ),
        .target(
            name: "MarmotKit",
            dependencies: ["MarmotKitFFI"],
            path: "Sources/MarmotKit",
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
