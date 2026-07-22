// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BackgroundAway",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BackgroundAway", targets: ["BackgroundAway"])
    ],
    targets: [
        .executableTarget(
            name: "BackgroundAway",
            path: "Sources/BackgroundAway"
        ),
        .testTarget(
            name: "BackgroundAwayTests",
            dependencies: ["BackgroundAway"],
            path: "Tests/BackgroundAwayTests"
        )
    ]
)
