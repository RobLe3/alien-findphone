// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "findphone",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "findphone",
            path: "Sources/findphone",
            resources: [
                .copy("Resources/alien_original_motion_tracker.m4a")
            ]
        ),
        .testTarget(
            name: "findphoneTests",
            dependencies: ["findphone"],
            path: "Tests/findphoneTests"
        )
    ]
)
