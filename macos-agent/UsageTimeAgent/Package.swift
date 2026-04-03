// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageTimeAgent",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "UsageTimeAgent",
            dependencies: [],
            path: "Sources/UsageTimeAgent"
        ),
    ]
)
