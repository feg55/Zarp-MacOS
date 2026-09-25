import Foundation
import SwiftUI
import ZarpCore

/// Bridges the `ZarpEngine` actor (plus `Localization` and `LogBus`) to SwiftUI state, and owns
/// the concrete wiring the App target is responsible for.
///
/// TODO(real-Mac PoC): `connections`/`probe`/`network` below are always the `Unimplemented*`
/// placeholders from `ZarpCore`'s `EngineProtocols.swift`. Every Connect/Scan action in this UI
/// will visibly fail with the raw `WarpConnectionError` message until those are replaced with a
/// real implementation — see `docs/IMPLEMENTATION_PLAN.md`. This view model does not paper over
/// that, and must not grow a fake implementation to make the UI "look done" in the meantime.
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

    init(settingsStore: SettingsStore, strategyStore: CustomStrategyStore, localization: Localization, log: LogBus) {
        self.localization = localization
        self.log = log
        self.engine = ZarpEngine(
            settingsStore: settingsStore,
            strategyStore: strategyStore,
            connections: UnimplementedWarpConnectionProvider(),
            probe: UnimplementedWarpProbe(),
            network: UnimplementedNetworkInspector(),
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
        isReady = true
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
            engine.cancel()
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
    func cancel() { engine.cancel() }

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
        engine.cancel()
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
