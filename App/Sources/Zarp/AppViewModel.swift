import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import ZarpCore
import ZarpdIPC

/// Bridges the `ZarpEngine` actor (plus `Localization` and `LogBus`) to SwiftUI state, and owns
/// the concrete wiring the App target is responsible for.
///
/// `connections`/`probe` default to `ZarpdClient` (docs/ARCHITECTURE.md §5, `zarpd/ipc`) — real
/// IPC to the `zarpd` LaunchDaemon, installed from Settings via `SMAppService`
/// (`ZarpdInstaller.swift`). `network` is `SystemNetworkInspector`, the real foreign-VPN check.
///
/// Besides forwarding the UI's actions, this type runs the app's heartbeat (`monitorTick`, every few
/// seconds): it pings the daemon, lets the engine reconcile what it believes with what the daemon
/// reports — which is how a tunnel that died on its own stops being shown as "Connected" — and pulls
/// the daemon's log lines into the app's own log.
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
    /// Set by the menu bar item's "Settings" entry; the main window opens its Settings sheet in
    /// response and clears it.
    @Published var settingsRequested = false

    /// `zarpd` installed via `SMAppService.daemon` (`ZarpdInstaller.swift`). `daemonState` answers
    /// "is it *installed*"; `daemonPing`/`daemonPingError` separately answer "is it actually up and
    /// responding right now" (`ZarpdClient.ping()`) — a daemon can be registered+enabled and still
    /// not be the one currently listening (crashed and mid-restart, a stale build before a
    /// re-approval, etc.), so neither signal substitutes for the other.
    let installer = ZarpdInstaller()
    @Published private(set) var daemonState: ZarpdInstaller.State = .notInstalled
    @Published private(set) var daemonPing: PingResult?
    @Published private(set) var daemonPingError: String?
    @Published private(set) var daemonActionError: String?
    /// The running daemon is an older build than this app (it survived an app update). It is
    /// restarted automatically once when nothing is in progress; this stays true if that didn't help.
    @Published private(set) var daemonStale = false
    /// Whether "Start with macOS" is on (`SMAppService.mainApp`).
    @Published private(set) var autostartEnabled = false
    private let zarpdClient: ZarpdClient?

    private var started = false
    private var monitorTask: Task<Void, Never>?
    private var daemonLogCursor: UInt64 = 0
    private var daemonLogPrimed = false
    private var staleRestartAttempted = false

    static let monitorInterval: UInt64 = 4_000_000_000
    /// Same cap as `LogBus` itself, so the view's copy can't grow without bound in a long session.
    private static let maxLogLines = 2000
    /// How long quitting waits for a scan to unwind and the tunnel to close before giving up.
    private static let terminationGrace: UInt64 = 8_000_000_000

    init(
        settingsStore: SettingsStore, strategyStore: CustomStrategyStore, localization: Localization, log: LogBus,
        connections: WarpConnectionProvider = ZarpdClient(), probe: WarpProbe? = nil,
        network: NetworkInspector = SystemNetworkInspector()
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
            Task { @MainActor in self?.appendLogLine(entry) }
        }
        localization.onChanged = { [weak self] in
            Task { @MainActor in self?.languageCode = localization.currentCode }
        }
    }

    private func appendLogLine(_ entry: LogEntry) {
        logLines.append(entry)
        if logLines.count > Self.maxLogLines { logLines.removeFirst(logLines.count - Self.maxLogLines) }
    }

    /// Call once at launch (calling it again is a no-op: SwiftUI's `.task` can re-run when a view
    /// reappears).
    func start() async {
        guard !started else { return }
        started = true
        await engine.setOnChanged { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        await engine.setHooks(EngineHooks(
            askContinueWithVPN: { [localization] names in await Self.confirmContinueWithVPN(names, localization) },
            askAcceptWarpTerms: { [localization] in await Self.confirmWarpTerms(localization) }
        ))
        await engine.load()
        settings = await engine.currentSettings
        let systemCode = Self.systemLanguageCode()
        localization.setLanguage(localization.resolve(setting: settings.language, systemCode: systemCode))
        await refresh()
        refreshDaemonState()
        refreshAutostart()
        await pingDaemon() // also adopts a tunnel that outlived a previous GUI session
        isReady = true
        startMonitoring()
        if settings.autoConnectOnStart { await autoConnectOnLaunch() }
    }

    /// "Connect when Zarp starts". Only when the daemon is actually answering and nothing else is
    /// going on — an adopted tunnel counts as already connected.
    private func autoConnectOnLaunch() async {
        guard daemonPing != nil else {
            log.write(localization.string("log.error", ["zarpd is not responding — not connecting automatically"]))
            return
        }
        guard state == .idle, !isBusy else { return }
        _ = await engine.connect()
    }

    // MARK: - Heartbeat

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.monitorInterval)
                guard !Task.isCancelled, let self else { return }
                await self.monitorTick()
            }
        }
    }

    private func monitorTick() async {
        await pingDaemon()
        await engine.reconcileConnection()
        await pullDaemonLogs()
        refreshDaemonState()
    }

    // MARK: - zarpd daemon install/status

    func refreshDaemonState() {
        installer.refresh()
        if daemonState != installer.state { daemonState = installer.state }
    }

    func installDaemon() {
        daemonActionError = nil
        do {
            try installer.install()
            daemonState = installer.state
        } catch let error as ZarpdInstaller.BadInstallLocation {
            switch error.problem {
            case .mountedVolume, .translocated: daemonActionError = localization.string("daemon.badLocation")
            case .notInApplications: daemonActionError = localization.string("daemon.badLocationApplications")
            }
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
    /// response can race the process actually exiting. A tunnel that was up is closed by the
    /// restart; the next heartbeat notices (and reconnects, if the user wants that) instead of
    /// continuing to display "Connected".
    func restartDaemon() async {
        guard let zarpdClient else { return }
        daemonActionError = nil
        _ = try? await zarpdClient.restart()
        daemonPing = nil
        daemonLogPrimed = false
        try? await Task.sleep(nanoseconds: 800_000_000)
        await pingDaemon()
    }

    /// Pings the daemon and records the answer. A ping that succeeds *after one that didn't*
    /// (including the very first one, at launch — the GUI-relaunch case) also makes the engine adopt
    /// whatever tunnel the daemon already has running.
    func pingDaemon() async {
        guard let zarpdClient else { return }
        let wasResponding = daemonPing != nil
        do {
            let ping = try await zarpdClient.ping()
            daemonPing = ping
            daemonPingError = nil
            if !wasResponding { await engine.adoptExistingConnection() }
            await checkDaemonVersion(ping)
        } catch {
            daemonPing = nil
            daemonPingError = (error as? WarpConnectionError)?.message ?? String(describing: error)
        }
    }

    /// A daemon left over from before an app update (the LaunchDaemon outlives the app bundle being
    /// replaced) speaks an older protocol or runs older code. Restart it once, when that can't hurt
    /// anything in progress; otherwise just say so in Settings.
    private func checkDaemonVersion(_ ping: PingResult) async {
        let stale = ping.effectiveProtocol < ZarpdClient.protocolVersion
            || (ping.version != "dev" && ping.version != Self.appVersion)
        if stale != daemonStale { daemonStale = stale }
        guard stale, !staleRestartAttempted, state == .idle, !isBusy else { return }
        staleRestartAttempted = true
        log.write(localization.string("daemon.restartingStale", [ping.version, Self.appVersion]))
        await restartDaemon()
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Imports the daemon's new log lines into the app's log (prefixed so it's clear where they
    /// came from). The first pull only sets the cursor: what the daemon logged before this session
    /// isn't replayed into the panel. If the daemon restarted, its sequence numbers start over and
    /// the new process's log is imported from the beginning.
    private func pullDaemonLogs() async {
        guard let zarpdClient, daemonPing != nil else { return }
        guard let result = try? await zarpdClient.logs(since: daemonLogCursor) else { return }
        if result.next < daemonLogCursor {
            guard let fresh = try? await zarpdClient.logs(since: 0) else { return }
            importDaemonLogs(fresh)
            daemonLogCursor = fresh.next
            return
        }
        if !daemonLogPrimed {
            daemonLogPrimed = true
            daemonLogCursor = result.next
            return
        }
        importDaemonLogs(result)
        daemonLogCursor = result.next
    }

    private func importDaemonLogs(_ logs: DaemonLogs) {
        for line in logs.lines ?? [] {
            log.write("zarpd: " + line.text, at: Date(timeIntervalSince1970: Double(line.timeMs) / 1000))
        }
    }

    // MARK: - Start with macOS (SMAppService.mainApp)

    func refreshAutostart() {
        let status = SMAppService.mainApp.status
        let on = status == .enabled || status == .requiresApproval
        if autostartEnabled != on { autostartEnabled = on }
    }

    func setAutostart(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log.write(localization.string("log.autostartOn"))
            } else {
                try SMAppService.mainApp.unregister()
                log.write(localization.string("log.autostartOff"))
            }
        } catch {
            log.write(localization.string("log.autostartFailed", [error.localizedDescription]))
        }
        refreshAutostart()
    }

    // MARK: - Engine state

    /// Waits for whatever operation is in flight to finish — used when the app is quitting
    /// (Windows `Engine.ShutdownAsync`).
    func waitUntilIdle() async {
        await engine.waitUntilIdle()
    }

    private func refresh() async {
        let snapshot = await engine.snapshot()
        state = snapshot.state
        detail = snapshot.detail
        progressDone = snapshot.progressDone
        progressTotal = snapshot.progressTotal
        strategies = snapshot.strategies
        results = snapshot.results
        selectedStrategyId = snapshot.selectedStrategyId
        isBusy = snapshot.isBusy
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

    /// The text for the custom-strategies editor.
    func customStrategiesText() async -> String {
        await engine.customStrategiesText()
    }

    /// Saves the editor's text; returns the lines that were skipped as malformed, or the error that
    /// kept the file from being written.
    func saveCustomStrategies(_ text: String) async -> Result<[String], Error> {
        do {
            let skipped = try await engine.saveCustomStrategies(text)
            await refresh()
            return .success(skipped)
        } catch {
            log.write(localization.string("log.customSaveFailed", [CustomStrategyFile.fileName, error.localizedDescription]))
            return .failure(error)
        }
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
    /// this type doesn't need AppKit's `NSApp` itself — `ZarpApp.swift` passes `NSApp.hide(nil)` /
    /// `NSApp.terminate(nil)`. Terminating runs `ZarpAppDelegate.applicationShouldTerminate`, which
    /// calls `prepareForTermination()` — so the shutdown sequence is the same however the app is
    /// asked to quit (⌘Q, the menu bar, the Dock's Quit, logging out).
    func requestClose(hide: @escaping () -> Void, terminate: @escaping () -> Void) {
        if settings.askBeforeClose {
            showingCloseConfirmation = true
        } else if settings.minimizeToMenuBar {
            hide()
        } else {
            terminate()
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
            terminate()
        }
    }

    func cancelClose() { showingCloseConfirmation = false }

    /// The shutdown sequence (Windows `Engine.FinishShutdownAsync`): cancel whatever might be
    /// running (e.g. a scan) so quitting doesn't sit through it to natural completion, wait for that
    /// cancellation to actually finish tearing down, and only then disconnect if asked to.
    /// `disconnect()`/`cancel()` on the engine only confirm an operation *started* — they are not
    /// themselves awaitable to completion, which is exactly why `waitUntilIdle()` follows each one
    /// here rather than being trusted to have already happened.
    ///
    /// Bounded: a daemon that has stopped answering must not be able to keep the app from quitting
    /// (or a logout from completing), so after a grace period the app goes ahead regardless.
    func prepareForTermination() async {
        monitorTask?.cancel()
        let engine = self.engine
        let disconnect = settings.disconnectOnExit
        let grace = Self.terminationGrace
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Two *unstructured* tasks race. A task group would not do: leaving it waits for every
            // child, including the stuck one the timeout exists to abandon.
            let once = OneShot()
            Task {
                await engine.cancel()
                await engine.waitUntilIdle()
                if disconnect {
                    _ = await engine.disconnect()
                    await engine.waitUntilIdle()
                }
                if once.fire() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: grace)
                if once.fire() { continuation.resume() }
            }
        }
    }

    // MARK: - Dialogs the engine asks for

    /// Windows' `dlg.vpn`: another VPN is on; carrying on means measuring (or fighting) its tunnel.
    /// "Cancel" is the default button — the message itself says turning the VPN off is better.
    private static func confirmContinueWithVPN(_ names: [String], _ loc: Localization) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Zarp"
        alert.informativeText = loc.string("dlg.vpn", [names.joined(separator: "\n")])
        alert.addButton(withTitle: loc.string("btn.cancel"))
        alert.addButton(withTitle: loc.string("dlg.vpnContinue"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Zarp registers an anonymous WARP account with Cloudflare, which means accepting Cloudflare's
    /// terms for the user: that happens only after they say so here.
    private static func confirmWarpTerms(_ loc: Localization) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = loc.string("dlg.termsTitle")
        alert.informativeText = loc.string("dlg.terms")
        alert.addButton(withTitle: loc.string("dlg.termsAccept"))
        alert.addButton(withTitle: loc.string("btn.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Licenses

    /// Windows `Licenses.Extract`: puts the notices that must accompany the distributed binaries
    /// (this app's own, the Go components inside `zarpd`, the zapret2 blobs) where the user can
    /// read them, and reveals them.
    func revealLicenses() {
        let fm = FileManager.default
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true),
              fm.fileExists(atPath: bundled.path) else {
            log.write(localization.string("log.licenseFailed", ["Licenses", "not found in the app bundle"]))
            return
        }
        let target = Self.dataDirectory().appendingPathComponent("Licenses", isDirectory: true)
        do {
            try? fm.removeItem(at: target)
            try fm.copyItem(at: bundled, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target.appendingPathComponent("THIRD_PARTY_NOTICES.md")])
        } catch {
            log.write(localization.string("log.licenseFailed", ["Licenses", error.localizedDescription]))
        }
    }

    static func dataDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Zarp", isDirectory: true)
    }

    /// Windows follows `CultureInfo.CurrentUICulture`; this is the SwiftUI/Foundation
    /// equivalent — `Locale`, not a networking API.
    private static func systemLanguageCode() -> String {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? Localization.fallbackCode
    }
}

/// Fires exactly once, from whichever caller gets there first.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
