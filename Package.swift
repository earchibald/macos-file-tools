// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mft",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mft", targets: ["mft"]),
        .library(name: "MFTCore", targets: ["MFTCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Everything the tools share: option groups, failures, output, the version store.
        .target(
            name: "MFTCore",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        // One multi-call binary. Each tool is a subcommand and also a symlink name.
        .executableTarget(
            name: "mft",
            dependencies: ["MFTCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        // Drives the built binary and checks the interface contract.
        .testTarget(name: "MFTTests", dependencies: ["mft"]),
    ]
)
