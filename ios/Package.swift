// swift-tools-version: 5.9
import PackageDescription

// Pure-logic modules that run on any macOS/Linux toolchain without a simulator.
// Keeping them out of the app target is what lets CI run "swift test" in seconds.
let package = Package(
    name: "DSHCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DSHPairing", targets: ["DSHPairing"]),
        .library(name: "DSHTrust", targets: ["DSHTrust"]),
        .library(name: "DSHTransport", targets: ["DSHTransport"]),
        .library(name: "DSHDeviceStore", targets: ["DSHDeviceStore"]),
    ],
    targets: [
        .target(
            name: "DSHPairing",
            path: "Sources/DSHPairing"
        ),
        .target(
            name: "DSHTrust",
            path: "Sources/DSHTrust"
        ),
        .testTarget(
            name: "DSHPairingTests",
            dependencies: ["DSHPairing"],
            path: "Tests/DSHPairingTests"
        ),
        .target(
            name: "DSHTransport",
            dependencies: ["DSHPairing"],
            path: "Sources/DSHTransport"
        ),
        .testTarget(
            name: "DSHTrustTests",
            dependencies: ["DSHTrust"],
            path: "Tests/DSHTrustTests"
        ),
        .target(
            name: "DSHDeviceStore",
            path: "Sources/DSHDeviceStore"
        ),
        .testTarget(
            name: "DSHTransportTests",
            dependencies: ["DSHTransport", "DSHPairing"],
            path: "Tests/DSHTransportTests"
        ),
        .testTarget(
            name: "DSHDeviceStoreTests",
            dependencies: ["DSHDeviceStore"],
            path: "Tests/DSHDeviceStoreTests"
        ),
    ]
)
