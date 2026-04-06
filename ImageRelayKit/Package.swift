// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImageRelayKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImageRelayKit", targets: ["ImageRelayKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
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
