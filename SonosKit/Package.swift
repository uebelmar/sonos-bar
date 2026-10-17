// swift-tools-version: 6.2
import PackageDescription

// All app code (Sonos client, store, views, AppDelegate) lives here. The Xcode
// project only holds the @main entry, Info.plist, entitlements and signing —
// so `swift test` covers the logic without an Xcode test target.
let appSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "SonosKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonosKit", targets: ["SonosKit"]),
    ],
    targets: [
        .target(name: "SonosKit", swiftSettings: appSettings),
        .testTarget(
            name: "SonosKitTests",
            dependencies: ["SonosKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: appSettings
        ),
    ]
)
