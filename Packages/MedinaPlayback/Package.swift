// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedinaPlayback",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MedinaPlayback", targets: ["MedinaPlayback"])],
    targets: [
        .target(name: "MedinaPlayback"),
        .testTarget(name: "MedinaPlaybackTests", dependencies: ["MedinaPlayback"])
    ]
)
