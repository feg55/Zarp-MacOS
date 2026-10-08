import Foundation

/// Things only the UI layer can do, which the engine needs an answer to mid-operation (Windows
/// `Engine.AskContinueWithVpn` and its siblings). Both are optional: with no hook the engine takes
/// the conservative default (don't continue / don't accept).
public struct EngineHooks: Sendable {
    /// Another VPN is active; WARP traffic would ride through it and a scan's results would be
    /// wrong. Return `true` to carry on anyway.
    public var askContinueWithVPN: (@Sendable ([String]) async -> Bool)?
    /// Zarp needs a WARP account and has none: ask the user to accept Cloudflare's terms before one
    /// is registered on their behalf. Return `true` if they accept.
    public var askAcceptWarpTerms: (@Sendable () async -> Bool)?

    public init(askContinueWithVPN: (@Sendable ([String]) async -> Bool)? = nil,
                askAcceptWarpTerms: (@Sendable () async -> Bool)? = nil) {
        self.askContinueWithVPN = askContinueWithVPN
        self.askAcceptWarpTerms = askAcceptWarpTerms
    }
}

/// Everything the UI shows, captured in one actor hop so the pieces are consistent with each other
/// (reading them with seven separate `await`s can straddle a state change).
public struct EngineSnapshot: Sendable {
    public let state: EngineState
    public let detail: Msg
    public let progressDone: Int
    public let progressTotal: Int
    public let strategies: [Strategy]
    public let results: [String: TestResult]
    public let selectedStrategyId: String?
    public let isBusy: Bool
}

/// What `reconcileConnection()` found.
public enum ReconcileOutcome: Sendable, Equatable {
    case unchanged
    /// A tunnel the engine didn't know about is now shown as connected.
    case adopted
    /// The tunnel the engine believed in is gone; the engine is idle again (the associated value
    /// is the reason, if the backend gave one).
    case lost(String?)
    /// The backend couldn't be asked.
    case daemonUnreachable
}

/// Strategy scan/connect/self-heal state machine. Direct port of Windows Zarp's `Engine`
/// (`Core/Engine.cs`) and Android Zarp's `ZarpEngine` (`core/ZarpEngine.kt`): same states, same
/// two-phase scan (walk the list, then independently re-check every candidate on a fresh
/// endpoint), same scoring, same self-healing order (saved strategy → other confirmed strategies,
/// best first → Quick Scan).
///
/// This type knows nothing about how a WARP connection actually gets made — that is entirely
/// `WarpConnectionProvider`'s job (see `EngineProtocols.swift`).
///
/// Cancellation follows Windows' model (`CancellationToken` threaded through every step): `cancel()`
/// is honored by *every* operation — mid-dial, mid-connect, between strategies — and a cancelled
/// operation always ends by tearing down whatever it had opened and reporting "Cancelled".
public actor ZarpEngine {
    public private(set) var state: EngineState = .idle
    public private(set) var detail: Msg = Msg("detail.noStrategy")
    public private(set) var progressDone: Int = 0
    public private(set) var progressTotal: Int = 0
    public private(set) var strategies: [Strategy] = StrategyCatalog.builtIn
    public private(set) var results: [String: TestResult] = [:]
    public private(set) var selectedStrategyId: String?

    /// Called after any state/detail/progress/results change, from whatever task is running —
    /// same role as Windows `Engine.Changed`. UI layers hop back to the main actor themselves.
    public var onChanged: (@Sendable () -> Void)?

    private let settingsStore: SettingsStore
    private let strategyStore: CustomStrategyStore
    private let connections: WarpConnectionProvider
    private let probe: WarpProbe
    private let network: NetworkInspector
    private let log: LogBus
    private let loc: Localization

    private var settings: AppSettings
    private var hooks = EngineHooks()
    private var endpointSeq: Int = 0
    private var activeConnection: WarpConnectionHandle?
    private var runningTask: Task<Void, Never>?
    private var busy = false
    private var stopRequested = false
    /// Bumped on every state transition and every operation start/finish. An answer from the
    /// backend is only valid if the epoch is unchanged since the question was asked: actors are
    /// re-entrant, so while `adoptExistingConnection`/`reconcileConnection` wait for the backend a
    /// whole connect can start *and finish* — checking `busy` afterwards would not notice, and the
    /// stale answer would overwrite the newer state.
    private var epoch = 0

    /// Consecutive failed attempts to reach the backend while the engine believes it is connected.
    private var unreachableCount = 0
    /// When automatic reconnect cycles began, newest last — a limit against a tunnel that keeps
    /// dying (flapping network) turning into an endless connect loop.
    private var reconnectCycles: [Date] = []
    private let reconnectBackoff: [Double]
    private static let reconnectAttemptsPerCycle = 3
    private static let reconnectCyclesPerWindow = 3
    private static let reconnectWindow: TimeInterval = 600

    /// - Parameter reconnectBackoff: seconds to wait before each automatic reconnect attempt
    ///   (the first, then the second, ...). Tests pass zeros.
    public init(settingsStore: SettingsStore, strategyStore: CustomStrategyStore,
                connections: WarpConnectionProvider, probe: WarpProbe, network: NetworkInspector,
                log: LogBus, localization: Localization, reconnectBackoff: [Double] = [2, 10, 30]) {
        self.settingsStore = settingsStore
        self.strategyStore = strategyStore
        self.connections = connections
        self.probe = probe
        self.network = network
        self.log = log
        self.loc = localization
        self.reconnectBackoff = reconnectBackoff.isEmpty ? [0] : reconnectBackoff
        self.settings = settingsStore.load()
    }

    // MARK: - Lifecycle

    /// Loads settings and the strategy list. Call once at startup (Windows `Engine`'s constructor
    /// + Android `ZarpEngine.load`).
    public func load() {
        settings = settingsStore.load()
        reloadStrategies()
        let known = Set(strategies.map(\.id))
        results = settings.results.filter { known.contains($0.key) }
        selectedStrategyId = settings.selectedStrategyId
        // An older build sent strategies it couldn't perform to the daemon as plain direct
        // connections and recorded them as working. Those results (and a saved selection of such a
        // strategy) are wrong; they must not stay in the table or be picked by self-healing.
        for s in strategies where s.unsupportedReason != nil {
            results[s.id] = nil
            if selectedStrategyId == s.id {
                selectedStrategyId = nil
                settings.selectedStrategyId = nil
            }
        }
        detail = selected.map { Msg("detail.strategy", $0.name(using: loc)) } ?? Msg("detail.noStrategy")
        notify()
    }

    /// Installs the UI callbacks the engine may need mid-operation.
    public func setHooks(_ hooks: EngineHooks) {
        self.hooks = hooks
    }

    /// Reconciles with a tunnel the backend already has open that this engine instance didn't
    /// itself start — most concretely, the GUI crashed or was quit and relaunched while `zarpd`
    /// (a fully independent daemon) kept running. Without this, a freshly-launched engine has no
    /// way to tell "genuinely idle" apart from "a real tunnel is up, I just don't know about it
    /// yet," and would show Disconnected while traffic keeps flowing underneath — worse, a user
    /// pressing Connect in that state would open a *second* tunnel alongside the first rather than
    /// using or replacing it.
    ///
    /// A no-op if this engine already knows about an active connection (`state == .connected`) or
    /// is busy with something else — never overwrites a connection the engine itself is already
    /// tracking, and never races a scan/connect. Errors (the backend isn't reachable at all) are
    /// swallowed: this is best-effort reconciliation, not a user-facing action.
    public func adoptExistingConnection() async {
        guard !busy, state != .connected else { return }
        let asked = epoch
        guard let snapshot = try? await connections.connectionSnapshot(), let live = snapshot.live else { return }
        // An actor method that awaits can be re-entered: a connect/scan may have started (and even
        // finished) while the backend was being asked. The answer is only valid if nothing changed
        // in the meantime.
        guard epoch == asked, !busy, state != .connected else { return }
        await adopt(live)
    }

    /// Compares what the engine believes with what the backend reports and corrects the engine —
    /// the UI calls this every few seconds. This is what makes a dead tunnel stop being displayed
    /// as "Connected": the daemon tears a tunnel down when its data plane dies, and the next call
    /// here notices, returns to idle, and (if the user wants it) starts a reconnect.
    @discardableResult
    public func reconcileConnection() async -> ReconcileOutcome {
        guard !busy else { return .unchanged }
        let asked = epoch
        let snapshot: ConnectionSnapshot
        do {
            snapshot = try await connections.connectionSnapshot()
        } catch {
            // A failure that arrives after something else already happened says nothing about
            // the engine's current state.
            guard epoch == asked, !busy else { return .unchanged }
            unreachableCount += 1
            // One missed answer is a hiccup; two in a row while "connected" means the daemon
            // (and with it the tunnel) is gone — a restart closes every tunnel.
            guard state == .connected, unreachableCount >= 2 else { return .daemonUnreachable }
            await connectionLost(reason: loc.string("err.daemonGone"), closeHandle: false)
            return .lost(nil)
        }
        // A snapshot taken before a connect/scan/disconnect that has since run is stale — even if
        // that operation already finished (busy is false again).
        guard epoch == asked, !busy else { return .unchanged }
        unreachableCount = 0

        switch (state, snapshot.live) {
        case (.connected, .some(let live)):
            if live.handle.id != activeConnection?.id {
                await adopt(live)
                return .adopted
            }
            return .unchanged
        case (.connected, .none):
            let reason = snapshot.lastLoss?.reason
            await connectionLost(reason: reason ?? loc.string("err.unknownLoss"), closeHandle: false)
            return .lost(reason)
        case (.idle, .some(let live)):
            await adopt(live)
            return .adopted
        default:
            return .unchanged
        }
    }

    public func reloadStrategies() {
        strategyStore.writeTemplateIfMissing()
        strategies = StrategyCatalog.load(customText: strategyStore.loadText()) { [log, loc] line in
            log.write(loc.string("log.customSkipped", [CustomStrategyFile.fileName, line]))
        }
    }

    /// The user's `strategies.txt` as it is now (the template, if it didn't exist yet).
    public func customStrategiesText() -> String {
        strategyStore.writeTemplateIfMissing()
        return strategyStore.loadText()
    }

    /// Saves the in-app editor's text to `strategies.txt` and reloads the list. Returns the lines
    /// that were skipped as malformed (so the editor can tell the user right away); throws if the
    /// file couldn't be written.
    @discardableResult
    public func saveCustomStrategies(_ text: String) throws -> [String] {
        try strategyStore.saveText(text)
        var skipped: [String] = []
        _ = CustomStrategyFile.parse(text) { skipped.append($0) }
        reloadStrategies()
        // A custom strategy that was removed or renamed no longer has a meaningful result.
        let known = Set(strategies.map(\.id))
        results = results.filter { known.contains($0.key) }
        if let id = selectedStrategyId, !known.contains(id) {
            selectedStrategyId = nil
            settings.selectedStrategyId = nil
        }
        saveResults()
        notify()
        return skipped
    }

    public var selected: Strategy? { strategies.first { $0.id == selectedStrategyId } }
    public var isBusy: Bool { busy }
    /// Quick Scan stops after this many working strategies (Windows `Engine.QuickStopAfter`).
    public var quickStopAfter: Int { max(1, settings.stopAfterWorking) }
    public var currentSettings: AppSettings { settings }

    /// A consistent view of everything the UI displays.
    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(state: state, detail: detail, progressDone: progressDone, progressTotal: progressTotal,
                       strategies: strategies, results: results, selectedStrategyId: selectedStrategyId, isBusy: busy)
    }

    /// `new` comes from the UI's own `AppSettings` snapshot, which only ever changes user
    /// preference fields — so the scan state (`results`, `selectedStrategyId`) is taken from the
    /// engine's own live values rather than accepted from `new`. Otherwise any Settings-screen
    /// toggle after a scan would silently roll discovered/verified strategy state back to whatever
    /// it was when the UI last saw it, even though nothing scan- or connection-related was being
    /// changed. Likewise the saved acceptance of Cloudflare's terms is never un-set by a stale copy.
    public func updateSettings(_ new: AppSettings) {
        var merged = new.normalized()
        merged.results = results
        merged.selectedStrategyId = selectedStrategyId
        merged.warpTermsAccepted = new.warpTermsAccepted || settings.warpTermsAccepted
        settings = merged
        settingsStore.save(settings)
    }

    /// Registers the change callback (Windows `Engine.Changed`), replacing any previous one. A
    /// method rather than exposing `onChanged` for direct cross-actor assignment, so callers have
    /// one unambiguous `await engine.setOnChanged { ... }` call site.
    public func setOnChanged(_ callback: @escaping @Sendable () -> Void) {
        onChanged = callback
    }

    // MARK: - Top-level actions (each returns `false` if the engine was already busy)

    /// Main button: connect with the saved strategy, fall back to other confirmed strategies, then
    /// to a Quick Scan — same order as Windows `Engine.ConnectAsync`.
    @discardableResult
    public func connect() -> Bool {
        run { [self] in
            guard await prepare() else { return }
            if let s = await selected {
                switch await apply(s) {
                case .connected: return
                case .cancelled: await cancelledExit(); return
                case .failed: break
                }
                await markFailed(s)
                let others = await confirmedStrategies(except: s)
                if !others.isEmpty {
                    log.write(loc.string("log.savedFailed", [s.name(using: loc)]))
                    switch await applyFirstWorking(others) {
                    case .connected: return
                    case .cancelled: await cancelledExit(); return
                    case .failed: break
                    }
                }
                log.write(loc.string("log.verifiedFailed"))
            }
            await searchAndApply(strategies, stopAfter: quickStopAfter,
                                  title: loc.string("log.searchQuick", [String(strategies.count), String(quickStopAfter)]))
        }
    }

    /// Quick Scan stops after `quickStopAfter` working strategies; Full Scan tests all of them —
    /// same as Windows `Engine.SearchAsync`.
    @discardableResult
    public func search(full: Bool) -> Bool {
        run { [self] in
            guard await prepare() else { return }
            let list = await strategies
            if full {
                await searchAndApply(list, stopAfter: 0, title: loc.string("log.searchFull", [String(list.count)]))
            } else {
                await searchAndApply(list, stopAfter: quickStopAfter,
                                      title: loc.string("log.searchQuick", [String(list.count), String(quickStopAfter)]))
            }
        }
    }

    /// Tests only the given strategies, all of them, no early stop (Windows `Engine.TestStrategiesAsync`).
    @discardableResult
    public func testStrategies(_ only: [Strategy]) -> Bool {
        run { [self] in
            guard await prepare() else { return }
            await searchAndApply(only, stopAfter: 0, title: loc.string("log.searchSelected", [String(only.count)]))
        }
    }

    /// Connects with a specific strategy and remembers it (Windows `Engine.UseStrategyAsync`).
    @discardableResult
    public func use(_ strategy: Strategy) -> Bool {
        run { [self] in
            guard await prepare() else { return }
            switch await apply(strategy) {
            case .connected: await saveSelected(strategy)
            case .cancelled: await cancelledExit()
            case .failed: break
            }
        }
    }

    @discardableResult
    public func disconnect() -> Bool {
        run { [self] in
            await setState(.disconnecting, Msg("detail.disconnecting"))
            await stopAll()
            await setState(.idle, Msg("detail.disconnected"))
        }
    }

    /// Cancels the running operation, if any. Honored everywhere: loop bodies check it between
    /// steps, and real Swift task cancellation reaches whatever `connections.open`/`probe.measure`
    /// are waiting on. Whatever the operation had opened is torn down and the engine ends up idle
    /// with "Cancelled".
    public func cancel() {
        stopRequested = true
        runningTask?.cancel()
    }

    /// Waits for the current operation, if any, to finish. Windows Zarp waits the same way before
    /// quitting (`Engine.FinishShutdownAsync`'s `_busy.WaitAsync()`), so a shutdown never races a
    /// scan that's mid-flight; returns immediately if nothing is running.
    public func waitUntilIdle() async {
        await runningTask?.value
    }

    // MARK: - Task orchestration

    /// Runs `body` if nothing else is running; returns whether it started. Matches the
    /// "one operation at a time" rule from Windows `Engine.Run` (`SemaphoreSlim(1,1)`) and Android
    /// `ZarpEngine.launchOp` (`Mutex.tryLock`).
    private func run(_ body: @escaping @Sendable () async -> Void) -> Bool {
        guard !busy else { return false }
        busy = true
        epoch += 1
        stopRequested = false
        runningTask = Task { [weak self] in
            await body()
            await self?.finishRun()
        }
        return true
    }

    private func finishRun() {
        progressTotal = 0
        progressDone = 0
        busy = false
        epoch += 1
        runningTask = nil
        notify()
    }

    /// True once the user asked to stop — through `cancel()` or through Swift task cancellation.
    private var cancelled: Bool { stopRequested || Task.isCancelled }

    private func notify() { onChanged?() }

    private func setState(_ s: EngineState, _ d: Msg? = nil) {
        epoch += 1
        state = s
        if let d { detail = d }
        notify()
    }

    private func setProgress(_ done: Int, _ total: Int) {
        progressDone = done
        progressTotal = total
        notify()
    }

    /// The common ending of a cancelled operation (Windows `Run`'s `OperationCanceledException`
    /// handler): close whatever is open, say so, and go idle.
    private func cancelledExit() async {
        await stopAll()
        log.write(loc.string("log.cancelled"))
        setState(.idle, Msg("detail.cancelled"))
    }

    // MARK: - Steps

    /// Checks everything a scan or connect depends on before it starts, and answers `false` — with
    /// the engine back to idle and a reason on screen — if it can't go ahead.
    private func prepare() async -> Bool {
        setState(.preparing, Msg("detail.preparing"))

        // Scans measure through a tunnel of their own, and only one tunnel can exist: whatever is
        // open — the connection this engine holds, or one the daemon still has from a previous
        // session — has to go first (Windows `TestAsync` also starts with a disconnect). Doing it
        // before the VPN check also keeps Zarp's own tunnel from being reported as a foreign VPN.
        await stopAll()
        if let snapshot = try? await connections.connectionSnapshot(), let live = snapshot.live {
            await live.handle.close()
        }
        if cancelled { await cancelledExit(); return false }

        let foreign = network.foreignVPNInterfaceNames()
        if !foreign.isEmpty {
            for name in foreign { log.write(loc.string("log.otherVpn", [name])) }
            log.write(loc.string("log.vpnAdvice"))
            if let ask = hooks.askContinueWithVPN, !(await ask(foreign)) {
                setState(.idle, Msg("detail.vpnOff"))
                return false
            }
        }

        do {
            if !(try await connections.isAccountRegistered()) {
                // Nothing registers with Cloudflare until the user has accepted its terms.
                let accepted: Bool
                if settings.warpTermsAccepted {
                    accepted = true
                } else if let ask = hooks.askAcceptWarpTerms {
                    accepted = await ask()
                } else {
                    accepted = false
                }
                guard accepted else {
                    setState(.idle, Msg("detail.termsDeclined"))
                    return false
                }
                log.write(loc.string("log.warpRegistering"))
                do {
                    try await connections.registerAccount()
                } catch {
                    log.write(loc.string("log.warpRegisterFailed", [describe(error)]))
                    setState(.idle, Msg("detail.registerFailed"))
                    return false
                }
                settings.warpTermsAccepted = true
                settingsStore.save(settings)
                log.write(loc.string("log.warpRegistered"))
            }
        } catch {
            // The backend itself couldn't be asked (not installed, not running).
            log.write(loc.string("log.error", [describe(error)]))
            setState(.idle, Msg("detail.error", describe(error)))
            return false
        }
        if cancelled { await cancelledExit(); return false }
        return true
    }

    private enum TestOutcome {
        case result(TestResult)
        case cancelled
    }

    /// Tests one strategy on a fresh WARP endpoint so it cannot inherit DPI state from a previous
    /// successful connection (Windows `Engine.TestAsync`, Android `ZarpEngine.test`).
    private func test(_ s: Strategy) async -> TestOutcome {
        // A strategy this port can't perform is a failed test, instantly and without touching the
        // network — never a connection that silently runs without its technique and "passes".
        if let reason = s.unsupportedReason {
            return .result(.failed(strategyId: s.id, error: reason))
        }
        // (No tunnel can be open here: prepare() closed whatever was, and every test closes its own
        // connection — so a throwaway test always starts from a clean slate.)
        let endpoint = settings.isolateTests ? nextEndpoint() : nil
        let handle: WarpConnectionHandle
        do {
            handle = try await connections.open(strategy: s, endpoint: endpoint, timeoutMs: settings.testTimeoutSec * 1000,
                                                 persistent: false, routing: .testRouteOnly)
        } catch let error as WarpConnectionError {
            if error.isCancelled || cancelled { return .cancelled }
            return error.timedOut
                ? .result(.failed(strategyId: s.id, error: Msg("err.timeout", String(settings.testTimeoutSec)), endpoint: endpoint))
                : .result(.failedRaw(strategyId: s.id, error: describe(error), endpoint: endpoint))
        } catch {
            if cancelled || error is CancellationError { return .cancelled }
            return .result(.failedRaw(strategyId: s.id, error: String(describing: error), endpoint: endpoint))
        }

        if cancelled {
            await handle.close()
            return .cancelled
        }

        let result: TestResult
        do {
            switch try await probe.measure(connection: handle, samples: 3) {
            case .ok(let pingMs, _):
                result = TestResult(strategyId: s.id, ok: true, connectMs: handle.connectMs, pingMs: pingMs, endpoint: handle.endpoint)
            case .notWarp(let warp):
                // Windows doesn't distinguish "connected but not WARP" from "no traffic at all";
                // this port keeps that one user-facing message and records the raw detail for diagnostics.
                var r = TestResult.failed(strategyId: s.id, error: Msg("err.noTraffic"), endpoint: handle.endpoint)
                r.error = "warp=\(warp ?? "?")"
                result = r
            case .noTraffic(let lastError):
                var r = TestResult.failed(strategyId: s.id, error: Msg("err.noTraffic"), endpoint: handle.endpoint)
                r.error = lastError
                result = r
            }
        } catch {
            await handle.close()
            if cancelled || error is CancellationError || (error as? WarpConnectionError)?.isCancelled == true { return .cancelled }
            return .result(.failedRaw(strategyId: s.id, error: describe(error), endpoint: handle.endpoint))
        }
        await handle.close()
        return .result(result)
    }

    /// - Parameter stopAfter: stop phase 1 after this many working strategies; 0 = test all.
    private func searchAndApply(_ list: [Strategy], stopAfter: Int, title: String) async {
        var candidates: [(Strategy, TestResult)] = []
        log.write(title)
        setProgress(0, list.count)

        // ---- phase 1: walk the list
        for s in list {
            if cancelled { break }
            setState(.searching, Msg("detail.testing", String(progressDone + 1), String(list.count), s.name(using: loc)))
            // A test interrupted by Cancel yields no result at all: recording it would overwrite
            // what the user already knew about this strategy with a failure that never happened.
            guard case .result(let r) = await test(s) else { break }
            putResult(r)
            setProgress(progressDone + 1, list.count)
            log.write("  " + (r.ok
                ? loc.string("log.testOk", [s.name(using: loc), String(r.connectMs), String(r.pingMs)])
                : loc.string("log.testFail", [s.name(using: loc), r.displayError(using: loc)])))
            if r.ok {
                candidates.append((s, r))
                if stopAfter > 0 && candidates.count >= stopAfter { break }
            }
        }
        saveResults()

        // ---- phase 2: independent re-check of every candidate (a different endpoint — the daemon
        // rotates through its pool for every "isolated-N" token — and a fresh attempt). Weeds out
        // strategies that "passed" only because of a previous successful connection.
        if !candidates.isEmpty && !cancelled {
            log.write(loc.string("log.recheck", [String(candidates.count)]))
            let ordered = candidates.sorted { $0.1.score < $1.1.score }
            setProgress(0, ordered.count)
            for (i, pair) in ordered.enumerated() {
                if cancelled { break }
                let (s, r1) = pair
                setState(.searching, Msg("detail.rechecking", String(i + 1), String(ordered.count), s.name(using: loc)))
                guard case .result(let r2) = await test(s) else { break }
                setProgress(i + 1, ordered.count)
                if r2.ok {
                    let merged = TestResult.confirmed(r1, r2)
                    putResult(merged)
                    log.write("  " + loc.string("log.recheckOk", [s.name(using: loc), String(r2.connectMs), String(r2.pingMs)]))
                } else {
                    var failed = r2
                    failed.rechecked = true
                    putResult(failed)
                    log.write("  " + loc.string("log.testFail", [s.name(using: loc), failed.displayError(using: loc)]))
                }
                saveResults()
            }
        }

        if cancelled {
            await cancelledExit()
            return
        }

        let confirmed = confirmedStrategies(except: nil)
        guard !confirmed.isEmpty else {
            await stopAll()
            log.write(candidates.isEmpty ? loc.string("log.noneWorked", [CustomStrategyFile.fileName]) : loc.string("log.candidatesFailed"))
            setState(.idle, Msg("detail.notFound"))
            return
        }

        setProgress(0, 0)
        let best = confirmed[0]
        if let br = results[best.id] {
            log.write(loc.string("log.best", [best.name(using: loc), String(br.connectMs), String(br.pingMs)]))
        }
        switch await applyFirstWorking(confirmed) {
        case .connected: break
        case .cancelled: await cancelledExit()
        case .failed: setState(.idle, Msg("detail.foundButFailed"))
        }
    }

    /// Confirmed strategies, best (lowest score) first (Windows `Engine.ConfirmedStrategies`).
    public func confirmedStrategies(except: Strategy?) -> [Strategy] {
        strategies
            .filter { $0.id != except?.id && (results[$0.id]?.ok ?? false) && (results[$0.id]?.confirmed ?? false) }
            .sorted { results[$0.id]!.score < results[$1.id]!.score }
    }

    private enum ApplyOutcome {
        case connected
        case failed
        case cancelled
    }

    /// Connects with the first strategy in the list that actually connects, and remembers it
    /// (Windows `Engine.ApplyFirstWorkingAsync`).
    private func applyFirstWorking(_ ordered: [Strategy]) async -> ApplyOutcome {
        for s in ordered {
            if cancelled { return .cancelled }
            switch await apply(s) {
            case .connected:
                await saveSelected(s)
                return .connected
            case .cancelled:
                return .cancelled
            case .failed:
                await markFailed(s)
                log.write(loc.string("log.tryNext", [s.name(using: loc)]))
            }
        }
        return .failed
    }

    private func markFailed(_ s: Strategy) async {
        putResult(.failed(strategyId: s.id, error: Msg("result.applyFailed")))
        saveResults()
    }

    /// What a persistent connection should carry, from the user's settings.
    private var routing: TunnelRouting {
        TunnelRouting(routeAll: settings.routeAllTraffic, overrideDNS: settings.overrideDNS)
    }

    private func connectedDetail(_ name: String, routeAll: Bool) -> Msg {
        Msg(routeAll ? "detail.strategy" : "detail.strategyTestRoute", name)
    }

    /// Connects with the given strategy and keeps the connection (Windows `Engine.ApplyAsync`).
    /// Does not record a failure in `results` — whether a failed apply should count against the
    /// strategy is the caller's decision (an automatic reconnect after a network blip must not).
    private func apply(_ s: Strategy) async -> ApplyOutcome {
        setState(.connecting, Msg("detail.connectingTo", s.name(using: loc)))
        log.write(loc.string("log.connectingWith", [s.name(using: loc)]))
        await stopAll()
        if cancelled { return .cancelled }

        if let reason = s.unsupportedReason {
            log.write(loc.string("log.unsupportedStrategy", [s.name(using: loc), reason.text(using: loc)]))
            setState(.idle, Msg("detail.unsupported"))
            return .failed
        }

        let timeoutMs = max(30, settings.testTimeoutSec * 2) * 1000
        var opened: WarpConnectionHandle?
        do {
            let handle = try await connections.open(strategy: s, endpoint: nil, timeoutMs: timeoutMs, persistent: true, routing: routing)
            opened = handle
            for warning in handle.warnings { log.write("zarpd: " + warning) }
            if cancelled {
                await handle.close()
                return .cancelled
            }
            switch try await probe.measure(connection: handle, samples: 1) {
            case .ok:
                activeConnection = handle
                unreachableCount = 0
                log.write(loc.string("log.warpConnectedIn", [String(handle.connectMs)]))
                setState(.connected, connectedDetail(s.name(using: loc), routeAll: routing.routeAll))
                return .connected
            case .notWarp, .noTraffic:
                await handle.close()
                log.write(loc.string("err.noTraffic"))
            }
        } catch {
            // Reached when the connection came up but measuring it threw (the backend went away
            // mid-call): the connection must not be left behind with nobody holding its handle —
            // it would keep its routes, and block every later connect, until the daemon restarted.
            if let handle = opened { await handle.close() }
            if cancelled || error is CancellationError || (error as? WarpConnectionError)?.isCancelled == true { return .cancelled }
            log.write(loc.string("log.warpNotConnected"))
            log.write(describe(error))
        }
        setState(.idle, Msg("detail.connectFailed"))
        return .failed
    }

    private func stopAll() async {
        if let c = activeConnection {
            activeConnection = nil
            await c.close()
        }
    }

    // MARK: - Reconciliation helpers

    private func adopt(_ live: LiveConnectionStatus) async {
        activeConnection = live.handle
        if let strategyId = live.strategyId, let match = strategies.first(where: { $0.id == strategyId }) {
            selectedStrategyId = strategyId
            await saveSelected(match)
            setState(.connected, connectedDetail(match.name(using: loc), routeAll: live.routeAll))
        } else {
            setState(.connected, connectedDetail(live.strategyId ?? "?", routeAll: live.routeAll))
        }
    }

    /// The tunnel the engine believed in is gone: say so, go idle, and — if the user wants — start
    /// a quiet reconnect.
    private func connectionLost(reason: String, closeHandle: Bool) async {
        let handle = activeConnection
        activeConnection = nil
        if closeHandle, let handle { await handle.close() }
        log.write(loc.string("log.connectionLost", [reason]))
        setState(.idle, Msg("detail.connectionLost"))
        scheduleReconnect()
    }

    /// After an unrequested loss: reconnect with the same strategy, a few attempts with growing
    /// pauses (covers the network coming back after sleep). Never a rescan, and never recorded as
    /// a failure of the strategy — the strategy didn't fail, the network did.
    private func scheduleReconnect() {
        guard settings.reconnectOnLoss, let strategy = selected, strategy.unsupportedReason == nil else { return }
        let now = Date()
        reconnectCycles = reconnectCycles.filter { now.timeIntervalSince($0) < Self.reconnectWindow }
        guard reconnectCycles.count < Self.reconnectCyclesPerWindow else {
            log.write(loc.string("log.reconnectGiveUp"))
            return
        }
        reconnectCycles.append(now)
        let backoff = reconnectBackoff
        _ = run { [self] in
            for attempt in 1...Self.reconnectAttemptsPerCycle {
                let delay = backoff[min(attempt - 1, backoff.count - 1)]
                log.write(loc.string("log.reconnecting", [String(attempt), String(Self.reconnectAttemptsPerCycle), strategy.name(using: loc)]))
                await setState(.connecting, Msg("detail.connectingTo", strategy.name(using: loc)))
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                if await cancelled { await cancelledExit(); return }
                switch await apply(strategy) {
                case .connected: return
                case .cancelled: await cancelledExit(); return
                case .failed: continue
                }
            }
            // Out of attempts: apply() left the engine idle with "could not connect".
            log.write(loc.string("log.reconnectGiveUp"))
        }
    }

    // MARK: - State helpers

    private func saveSelected(_ s: Strategy) async {
        selectedStrategyId = s.id
        settings.selectedStrategyId = s.id
        settingsStore.save(settings)
    }

    private func putResult(_ r: TestResult) {
        results[r.strategyId] = r
    }

    private func saveResults() {
        settings.results = results
        settingsStore.save(settings)
    }

    /// The message to show for a backend error: a localized sentence for the codes the engine
    /// knows, the backend's own text otherwise.
    private func describe(_ error: Error) -> String {
        guard let e = error as? WarpConnectionError else { return String(describing: error) }
        switch e.code {
        case "foreign_vpn": return loc.string("err.foreignVpn")
        case "no_account": return loc.string("err.noAccount")
        default: return e.message
        }
    }

    /// A distinct token per attempt. The backend maps it onto its own endpoint rotation (zarpd:
    /// the same pool Windows Zarp's `Warp.NextEndpoint` walks), so consecutive attempts — a test and
    /// the independent re-check that follows it — leave from different endpoints.
    private func nextEndpoint() -> String {
        defer { endpointSeq += 1 }
        return "isolated-\(endpointSeq)"
    }
}
