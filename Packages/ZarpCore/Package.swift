// swift-tools-version:5.9
import PackageDescription

// Platform-independent part of Zarp for macOS: strategy model and catalog, scan/scoring/self-heal
// state machine, settings, localization and logging. Foundation only, so `swift test` also runs on
// Linux. Deliberately excludes anything that touches live network traffic — see
// `Sources/ZarpCore/Engine/EngineProtocols.swift` for the boundary and `docs/MACOS_NETWORK_RESEARCH.md`
// for why that part is not implemented yet.
let package = Package(
    name: "ZarpCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZarpCore", targets: ["ZarpCore"]),
    ],
    targets: [
        .target(name: "ZarpCore"),
        .testTarget(name: "ZarpCoreTests", dependencies: ["ZarpCore"]),
    ]
)
