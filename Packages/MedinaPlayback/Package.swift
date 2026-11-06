// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MedinaPlayback",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedinaPlayback", targets: ["MedinaPlayback"])],
    dependencies: [
        .package(url: "https://github.com/harflabs/SwiftVLC.git", exact: "1.1.0-beta.14")
    ],
    targets: [
        .target(name: "MedinaPlayback", dependencies: [
            .product(name: "SwiftVLC", package: "SwiftVLC")
        ]),
        .testTarget(name: "MedinaPlaybackTests", dependencies: ["MedinaPlayback"])
    ]
)
