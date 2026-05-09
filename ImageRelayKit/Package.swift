// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageRelayKit",
    // macOS 15 keeps CI on macos-latest (Xcode 16 / Swift 6.0). iOS 18 is the minimum
    // for the iOS host app + File Provider extension. Hosts target newer SDKs via
    // Project.yml / xcodebuild (macOS 26 / iOS 18).
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ImageRelayKit", targets: ["ImageRelayKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "ImageRelayKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "ImageRelayKitTests",
            dependencies: ["ImageRelayKit"]
        ),
    ]
)
