// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rebes",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "RebesCore",
            dependencies: [],
            path: "Sources/RebesCore"
        ),
        .executableTarget(
            name: "Rebes",
            dependencies: ["RebesCore"],
            path: "Sources/Rebes"
        ),
        .executableTarget(
            name: "RebesHelper",
            dependencies: ["RebesCore"],
            path: "Sources/RebesHelper"
        ),
        .executableTarget(
            name: "RebesSelfTest",
            dependencies: ["RebesCore"],
            path: "Sources/RebesSelfTest"
        ),
        .testTarget(
            name: "RebesTests",
            dependencies: ["RebesCore"],
            path: "Tests/RebesTests"
        )
    ]
)
