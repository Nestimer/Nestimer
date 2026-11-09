// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NesTimerCore",
    platforms: [.iOS("17.4"), .macOS(.v14)],
    products: [.library(name: "NesTimerCore", targets: ["NesTimerCore"])],
    targets: [
        .target(name: "NesTimerCore"),
        .testTarget(name: "NesTimerCoreTests", dependencies: ["NesTimerCore"]),
    ]
)
