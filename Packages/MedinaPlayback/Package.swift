// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MedinaPlayback",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedinaPlayback", targets: ["MedinaPlayback"])],
    dependencies: [],
    targets: [
        .systemLibrary(name: "CMpvSystem", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .target(name: "CMpvShim", dependencies: ["CMpvSystem"], publicHeadersPath: "include",
               linkerSettings: [.linkedFramework("OpenGL")]),
        .target(name: "MedinaPlayback", dependencies: ["CMpvShim", "CMpvSystem"]),
        .testTarget(name: "MedinaPlaybackTests", dependencies: ["MedinaPlayback"])
    ]
)
