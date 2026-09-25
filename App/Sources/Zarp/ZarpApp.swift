import AppKit
import SwiftUI
import ZarpCore

/// App entry point: wires `AppViewModel` to real file-backed stores and a real log file, then
/// shows the main window and a menu bar item.
///
/// UNVERIFIED: never built or run (no Xcode/macOS in the environment this was written in — see
/// `docs/IMPLEMENTATION_PLAN.md`). In particular, `Localization.load`'s search path for
/// `Resources/Lang` depends on how Xcode bundles the top-level `Resources/Lang` folder (a "folder
/// reference" blue-folder build phase entry is the usual way to get
/// `Bundle.main.resourceURL?.appendingPathComponent("Lang")` to resolve; `project.yml` at the repo
/// root sets this up, but XcodeGen has not been run against it on a real Mac yet).
///
/// Also unverified: intercepting the titlebar red-button close specifically (as opposed to the
/// menu bar Quit item and ⌘Q below, which do go through `AppViewModel.requestClose`) — see
/// `CloseConfirmationView.swift`'s doc comment for what that still needs.
@main
@MainActor
struct ZarpApp: App {
    // Marking the type @MainActor (rather than relying on `App.body`'s own @MainActor requirement
    // to carry over) is the belt-and-suspenders choice here: `@StateObject`'s default-value
    // expression below runs as part of this struct's synthesized `init()`, a different
    // declaration than `body`, and property initializers can't use `await` if that turned out to
    // need it — TODO(real Mac): confirm this is even necessary once it can actually be compiled;
    // it may be redundant with SwiftUI's own inference.
    @StateObject private var vm = ZarpApp.makeViewModel()

    var body: some Scene {
        Window("Zarp", id: "main") {
            MainWindowView(vm: vm)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Zarp") { requestClose() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra("Zarp", systemImage: menuBarIcon) {
            Button(vm.localization.string("tray.open")) { NSApp.activate(ignoringOtherApps: true) }
            Button(menuToggleTitle) { vm.connectButtonTapped() }
            Divider()
            Button(vm.localization.string("tray.settings")) {
                // TODO(real Mac): this only raises the main window, which itself opens Settings
                // as a sheet. A direct-to-Settings menu action would need `@Environment(\.openWindow)`
                // with Settings as its own `Window` scene instead of a sheet — worth reconsidering
                // once this is actually running and the current approach can be judged on-screen.
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button(vm.localization.string("tray.exit")) { requestClose() }
        }
    }

    private var menuBarIcon: String {
        switch vm.state {
        case .connected: return "bolt.fill"
        case .idle: return "bolt.slash"
        default: return "bolt"
        }
    }

    private var menuToggleTitle: String {
        if vm.isBusy { return vm.localization.string("tray.cancel") }
        return vm.state == .connected ? vm.localization.string("tray.disconnect") : vm.localization.string("tray.connect")
    }

    private func requestClose() {
        vm.requestClose(hide: { NSApp.hide(nil) }, terminate: { NSApp.terminate(nil) })
    }

    // MARK: - Wiring

    @MainActor
    private static func makeViewModel() -> AppViewModel {
        let dataDir = dataDirectory()
        let log = LogBus()
        log.attachFile(logDirectory().appendingPathComponent("zarp.log"))

        let localization = Localization.load(languageFilesDirectory: languageFilesDirectory())

        return AppViewModel(
            settingsStore: JSONFileSettingsStore(url: dataDir.appendingPathComponent("zarp.json")),
            strategyStore: FileCustomStrategyStore(url: dataDir.appendingPathComponent(CustomStrategyFile.fileName)),
            localization: localization,
            log: log
        )
    }

    private static func dataDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Zarp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func logDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Logs/Zarp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// TODO(real Mac): confirm this resolves once `project.yml` is generated and the app is
    /// built — see the type-level doc comment. Falls back to the repo-relative path so
    /// `swift run`-style development before there's an app bundle at all still finds real
    /// translations instead of only ever seeing English fallback text.
    private static func languageFilesDirectory() -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Lang"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath) // App/Sources/Zarp/ZarpApp.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Lang")
    }
}
