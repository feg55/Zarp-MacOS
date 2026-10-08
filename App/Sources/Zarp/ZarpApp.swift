import AppKit
import SwiftUI
import ZarpCore

/// App entry point: wires `AppViewModel` to real file-backed stores and a real log file, then
/// shows the main window and a menu bar item.
///
/// The titlebar red-button close, the menu bar Quit item, and ⌘Q all funnel into the same
/// `AppViewModel.requestClose` path: SwiftUI's `Window` scene has no direct hook for
/// `windowShouldClose(_:)`, so `WindowCloseInterceptor` below attaches a plain `NSWindowDelegate`
/// to the underlying `NSWindow` once it exists, and always answers `false` — `requestClose` decides
/// asynchronously (it may show `CloseConfirmationView` as a sheet first) and itself calls
/// `NSApp.hide`/`NSApp.terminate` when it has an answer, exactly as the other two paths already do.
///
/// *Actually* terminating — by any route, including ones that never pass through `requestClose`
/// (the Dock's Quit, logging out, shutting down, `osascript`) — goes through
/// `ZarpAppDelegate.applicationShouldTerminate`, which unwinds a running scan and disconnects if the
/// user asked for that before the process exits.
@main
@MainActor
struct ZarpApp: App {
    @NSApplicationDelegateAdaptor(ZarpAppDelegate.self) private var appDelegate

    // The view model is a process-wide singleton (`AppServices`) so the app delegate — which AppKit
    // creates on its own — talks to the very same instance the views observe.
    @StateObject private var vm = AppServices.viewModel

    var body: some Scene {
        Window("Zarp", id: "main") {
            MainWindowView(vm: vm)
                .background(WindowCloseInterceptor(onShouldClose: requestClose))
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(vm.localization.string("tray.quit")) { requestClose() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra("Zarp", systemImage: menuBarIcon) {
            Button(vm.localization.string("tray.open")) { NSApp.activate(ignoringOtherApps: true) }
            Button(menuToggleTitle) { vm.connectButtonTapped() }
            Divider()
            Button(vm.localization.string("tray.settings")) {
                // The Settings screen is a sheet of the main window: raise the window, and ask it to
                // present the sheet.
                NSApp.activate(ignoringOtherApps: true)
                vm.settingsRequested = true
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
}

/// Creates the one `AppViewModel` on first use, with real file-backed stores and a real log file.
@MainActor
enum AppServices {
    static let viewModel: AppViewModel = makeViewModel()

    private static func makeViewModel() -> AppViewModel {
        let dataDir = dataDirectory()
        let log = LogBus()
        log.attachFile(logDirectory().appendingPathComponent("zarp.log"))

        let localization = Localization.load(languageFilesDirectory: languageFilesDirectory())

        // Problems reading or writing zarp.json go to the log in the user's language (Windows
        // `log.configBroken` / `log.configSaveFailed`) instead of vanishing.
        let settingsStore = JSONFileSettingsStore(url: dataDir.appendingPathComponent("zarp.json")) { problem in
            switch problem {
            case .corrupt(let reason): log.write(localization.string("log.configBroken", [reason]))
            case .saveFailed(let reason): log.write(localization.string("log.configSaveFailed", [reason]))
            }
        }

        return AppViewModel(
            settingsStore: settingsStore,
            strategyStore: FileCustomStrategyStore(url: dataDir.appendingPathComponent(CustomStrategyFile.fileName)),
            localization: localization,
            log: log
        )
    }

    private static func dataDirectory() -> URL {
        let dir = AppViewModel.dataDirectory()
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

    /// The bundled `Resources/Lang` folder. Falls back to the repo-relative path so
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

/// Makes quitting safe however it is requested. Closing the window never reaches here (the window
/// delegate swallows it); `NSApp.terminate` does — from ⌘Q and the menu bar via `requestClose`, and
/// directly from the Dock's Quit, a logout or a shutdown, which never see `requestClose` at all.
final class ZarpAppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second request while the first is unwinding must not start a second sequence.
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await AppServices.viewModel.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Invisible helper view: on insertion, finds its enclosing `NSWindow` and makes itself that
/// window's delegate purely to intercept `windowShouldClose(_:)`. The window has no other delegate
/// of its own to preserve (plain SwiftUI `Window` scenes don't set one), so this doesn't need to
/// forward other delegate methods anywhere.
private struct WindowCloseInterceptor: NSViewRepresentable {
    let onShouldClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(via: view, onShouldClose: onShouldClose) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(via: nsView, onShouldClose: onShouldClose)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private var onShouldClose: (() -> Void)?

        func attach(via view: NSView, onShouldClose: @escaping () -> Void) {
            self.onShouldClose = onShouldClose
            guard let window = view.window, window !== self.window else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            onShouldClose?()
            return false
        }
    }
}
