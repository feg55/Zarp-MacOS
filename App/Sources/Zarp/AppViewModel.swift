import Foundation
import SwiftUI
import ZarpCore

/// Bridges the `ZarpEngine` actor (plus `Localization` and `LogBus`) to SwiftUI state, and owns
/// the concrete wiring the App target is responsible for.
///
/// `connections`/`probe` default to `ZarpdClient` (docs/ARCHITECTURE.md §9.4, `zarpd/ipc`) — real
/// IPC to the `zarpd` daemon, which must already be running (`sudo zarpd`; `SMAppService`
/// installation is `docs/IMPLEMENTATION_PLAN.md` phase 8, not built yet) for Connect/Scan to work.
/// `network` is still `UnimplementedNetworkInspector` — that piece is real, separate, smaller work
/// (`getifaddrs`), not blocking Connect/Scan, so it isn't done yet either; this view model does
/// not paper over that with a fake implementation to make the UI "look done" in the meantime.
@MainActor
final class AppViewModel: ObservableObject {
    let engine: ZarpEngine
    let localization: Localization
    let log: LogBus

    @Published private(set) var state: EngineState = .idle
    @Published private(set) var detail: Msg = Msg("detail.noStrategy")
    @Published private(set) var progressDone: Int = 0
    @Published private(set) var progressTotal: Int = 0
    @Published private(set) var strategies: [Strategy] = []
    @Published private(set) var results: [String: TestResult] = [:]
    @Published private(set) var selectedStrategyId: String?
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var settings: AppSettings = AppSettings()
    @Published private(set) var logLines: [LogEntry] = []
    @Published private(set) var languageCode: String = Localization.fallbackCode
    @Published private(set) var isReady = false
    /// Drives `CloseConfirmationView`'s presentation. Kept here (not in `ZarpApp`/AppKit code) so
    /// both the main window and the menu bar item can trigger and observe it without threading an
    /// extra binding through the Scene hierarchy.
    @Published var showingCloseConfirmation = false

    /// Phase 8: `zarpd` installed via `SMAppService.daemon` (`ZarpdInstaller.swift`) rather than
    /// requiring a manual `sudo zarpd` in a Terminal. `daemonState` answers "is it *installed*";
    /// `daemonPing`/`daemonPingError` separately answer "is it actually up and responding right
    /// now" (`ZarpdClient.ping()`) — a daemon can be registered+enabled and still not be the one
    /// currently listening (crashed and mid-restart, a stale build before a re-approval, etc.), so
    /// neither signal substitutes for the other.
    let installer = ZarpdInstaller()
    @Published private(set) var daemonState: ZarpdInstaller.State = .notInstalled
    @Published private(set) var daemonPing: PingResult?
    @Published private(set) var daemonPingError: String?
    @Published private(set) var daemonActionError: String?
    private let zarpdClient: ZarpdClient?

    init(
        settingsStore: SettingsStore, strategyStore: CustomStrategyStore, localization: Localization, log: LogBus,
        connections: WarpConnectionProvider = ZarpdClient(), probe: WarpProbe? = nil,
        network: NetworkInspector = UnimplementedNetworkInspector()
    ) {
        self.localization = localization
        self.log = log
        // WarpProbe defaults to the same ZarpdClient instance as WarpConnectionProvider when the
        // caller doesn't pass its own (the common case) — one socket-speaking object, not two —
        // but can't share that default with the `connections` parameter above directly since a
        // caller providing a custom `connections` (a fake, in a future test) shouldn't silently
        // still get a real ZarpdClient for probing.
        let resolvedProbe = probe ?? (connections as? ZarpdClient) ?? ZarpdClient()
        self.zarpdClient = (connections as? ZarpdClient) ?? (resolvedProbe as? ZarpdClient)
        self.engine = ZarpEngine(
            settingsStore: settingsStore,
            strategyStore: strategyStore,
            connections: connections,
            probe: resolvedProbe,
            network: network,
            log: log,
            localization: localization
        )
        self.languageCode = localization.currentCode
        self.logLines = log.snapshot()

        log.onAppend = { [weak self] entry in
            Task { @MainActor in self?.logLines.append(entry) }
        }
        localization.onChanged = { [weak self] in
            Task { @MainActor in self?.languageCode = localization.currentCode }
        }
    }

    /// Call once at launch.
    func start() async {
        await engine.setOnChanged { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        await engine.load()
        settings = await engine.currentSettings
        let systemCode = Self.systemLanguageCode()
        localization.setLanguage(localization.resolve(setting: settings.language, systemCode: systemCode))
        await refresh()
        refreshDaemonState()
        await pingDaemon()
        isReady = true
    }

    // MARK: - zarpd daemon install/status (Phase 8)

    func refreshDaemonState() {
        installer.refresh()
        daemonState = installer.state
    }

    func installDaemon() {
        daemonActionError = nil
        do {
            try installer.install()
            daemonState = installer.state
        } catch {
            daemonActionError = String(describing: error)
        }
    }

    func uninstallDaemon() {
        daemonActionError = nil
        do {
            try installer.uninstall()
            daemonState = installer.state
        } catch {
            daemonActionError = String(describing: error)
        }
        daemonPing = nil
    }

    func openDaemonApprovalSettings() {
        installer.openSystemSettingsLoginItems()
    }

    /// See `ZarpdClient.restart()`'s doc comment: there's no unprivileged "stop and stay stopped
    /// but still installed" for a root daemon, so this is what "restart" means here. Re-pings
    /// after a delay rather than trusting the restart call's own success/failure, since the
    /// response can race the process actually exiting.
    func restartDaemon() async {
        guard let zarpdClient else { return }
        daemonActionError = nil
        _ = try? await zarpdClient.restart()
        daemonPing = nil
        try? await Task.sleep(nanoseconds: 800_000_000)
        await pingDaemon()
    }

    /// Also the closest thing this IPC design has to an explicit "reconnected" event — every call
    /// is already its own short-lived connect/disconnect, there's no persistent session to notice
    /// dropping and recovering — so a ping that succeeds *after one that didn't* (including the
    /// very first one, at launch, which is exactly the GUI-relaunch case) reconciles the engine
    /// with whatever the daemon actually has running (`ZarpEngine.adoptExistingConnection()`'s own
    /// doc comment). Deliberately not on every successful ping: that method is already a safe
    /// no-op once the engine knows it's connected, but skipping the redundant call when nothing
    /// could have changed keeps this from doing pointless work on every routine status refresh.
    func pingDaemon() async {
        guard let zarpdClient else { return }
        let wasResponding = daemonPing != nil
        do {
            daemonPing = try await zarpdClient.ping()
            daemonPingError = nil
            if !wasResponding {
                await engine.adoptExistingConnection()
            }
        } catch {
            daemonPing = nil
            daemonPingError = (error as? WarpConnectionError)?.message ?? String(describing: error)
        }
    }

    /// Waits for whatever operation is in flight to finish — used when the app is quitting
    /// (Windows `Engine.ShutdownAsync`).
    func waitUntilIdle() async {
        await engine.waitUntilIdle()
    }

    private func refresh() async {
        state = await engine.state
        detail = await engine.detail
        progressDone = await engine.progressDone
        progressTotal = await engine.progressTotal
        strategies = await engine.strategies
        results = await engine.results
        selectedStrategyId = await engine.selectedStrategyId
        isBusy = await engine.isBusy
    }

    // MARK: - Actions (fire-and-forget from the UI's point of view; state updates arrive via `refresh()`)

    func connectButtonTapped() {
        if isBusy {
            Task { await engine.cancel() }
            return
        }
        if state == .connected {
            Task { _ = await engine.disconnect() }
        } else {
            Task { _ = await engine.connect() }
        }
    }

    func quickScan() { Task { _ = await engine.search(full: false) } }
    func fullScan() { Task { _ = await engine.search(full: true) } }
    func testSelected(_ items: [Strategy]) { Task { _ = await engine.testStrategies(items) } }
    func use(_ strategy: Strategy) { Task { _ = await engine.use(strategy) } }
    func cancel() { Task { await engine.cancel() } }

    func reloadCustomStrategies() {
        Task { await engine.reloadStrategies(); await refresh() }
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
        Task { await engine.updateSettings(s) }
        if let lang = s.language {
            localization.setLanguage(lang)
        }
    }

    func setLanguage(_ code: String?) {
        updateSettings { $0.language = code }
        localization.setLanguage(code ?? Self.systemLanguageCode())
    }

    // MARK: - Close / quit (Windows `MainForm.OnFormClosing` + `CloseActionForm`)

    /// Call when the user asks to close the window or quit. `hide`/`terminate` are injected so
    /// this type doesn't need to import AppKit itself — `ZarpApp.swift` passes `NSApp.hide(nil)`
    /// / `NSApp.terminate(nil)`.
    func requestClose(hide: @escaping () -> Void, terminate: @escaping () -> Void) {
        if settings.askBeforeClose {
            showingCloseConfirmation = true
        } else if settings.minimizeToMenuBar {
            hide()
        } else {
            Task { await quit(terminate: terminate) }
        }
    }

    func confirmClose(minimizeToMenuBar: Bool, remember: Bool, hide: @escaping () -> Void, terminate: @escaping () -> Void) {
        showingCloseConfirmation = false
        if remember {
            updateSettings { s in
                s.askBeforeClose = false
                s.minimizeToMenuBar = minimizeToMenuBar
            }
        }
        if minimizeToMenuBar {
            hide()
        } else {
            Task { await quit(terminate: terminate) }
        }
    }

    func cancelClose() { showingCloseConfirmation = false }

    private func quit(terminate: @escaping () -> Void) async {
        // Matches Windows' shutdown order (`Engine.FinishShutdownAsync`): cancel whatever might be
        // running (e.g. a scan) so quitting doesn't sit through it to natural completion, wait for
        // that cancellation to actually finish tearing down, and only then disconnect if asked to.
        // `disconnect()`/`cancel()` on the engine only confirm an operation *started* — they are
        // not themselves awaitable to completion, which is exactly why `waitUntilIdle()` follows
        // each one here rather than being trusted to have already happened.
        await engine.cancel()
        await waitUntilIdle()
        if settings.disconnectOnExit {
            _ = await engine.disconnect()
            await waitUntilIdle()
        }
        terminate()
    }

    /// Windows follows `CultureInfo.CurrentUICulture`; this is the SwiftUI/Foundation
    /// equivalent — `Locale`, not a networking API.
    private static func systemLanguageCode() -> String {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? Localization.fallbackCode
    }
}
