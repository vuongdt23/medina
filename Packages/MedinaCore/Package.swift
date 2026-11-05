// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedinaCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MedinaCore", targets: ["MedinaCore"])],
    targets: [
        .target(name: "MedinaCore"),
        .testTarget(name: "MedinaCoreTests", dependencies: ["MedinaCore"])
    ]
)
