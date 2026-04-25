// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageRelayKit",
    // macOS 15 minimum keeps CI working on macos-latest runners (Xcode 16 / Swift 6.0).
    // The host app and extension target macOS 26 via Project.yml / xcodebuild.
    platforms: [.macOS(.v15)],
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
