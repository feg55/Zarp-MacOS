// swift-tools-version:5.9
import PackageDescription

// Platform-independent part of Zarp for macOS: strategy model and catalog, scan/scoring/self-heal
// state machine, settings, localization and logging. Foundation only, so `swift test` also runs on
// Linux. Deliberately excludes anything that touches live network traffic — see
// `Sources/ZarpCore/Engine/EngineProtocols.swift` for the boundary.
//
// `ZarpdIPC` is the one piece that does talk to something: the client for the `zarpd` daemon's Unix
// socket (`zarpd/ipc/protocol.go`). It is its own target — macOS-only, POSIX sockets — so the
// engine's package stays free of it, and so it can be tested here (against a fake daemon) instead of
// only ever being exercised by running the whole app.
let package = Package(
    name: "ZarpCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZarpCore", targets: ["ZarpCore"]),
        .library(name: "ZarpdIPC", targets: ["ZarpdIPC"]),
    ],
    targets: [
        .target(name: "ZarpCore"),
        .target(name: "ZarpdIPC", dependencies: ["ZarpCore"]),
        .testTarget(name: "ZarpCoreTests", dependencies: ["ZarpCore"]),
        .testTarget(name: "ZarpdIPCTests", dependencies: ["ZarpdIPC", "ZarpCore"]),
    ]
)
