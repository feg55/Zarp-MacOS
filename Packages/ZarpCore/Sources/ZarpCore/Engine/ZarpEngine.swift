import Foundation

/// Strategy scan/connect/self-heal state machine. Direct port of Windows Zarp's `Engine`
/// (`Core/Engine.cs`) and Android Zarp's `ZarpEngine` (`core/ZarpEngine.kt`): same states, same
/// two-phase scan (walk the list, then independently re-check every candidate on a fresh
/// endpoint), same scoring, same self-healing order (saved strategy → other confirmed strategies,
/// best first → Quick Scan).
///
/// This type knows nothing about how a WARP connection actually gets made — that is entirely
/// `WarpConnectionProvider`'s job (see `EngineProtocols.swift`). Nothing here assumes which of the
/// two candidate macOS backends is behind it, and nothing here has been exercised against a real
/// network: `connections`/`probe`/`network` are injected, and the App target wires them to the
/// `Unimplemented*` placeholders until the real-Mac proof of concept replaces them.
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
    private var endpointSeq: Int = 0
    private var activeConnection: WarpConnectionHandle?
    private var runningTask: Task<Void, Never>?
    private var busy = false
    private var stopRequested = false

    public init(settingsStore: SettingsStore, strategyStore: CustomStrategyStore,
                connections: WarpConnectionProvider, probe: WarpProbe, network: NetworkInspector,
                log: LogBus, localization: Localization) {
        self.settingsStore = settingsStore
        self.strategyStore = strategyStore
        self.connections = connections
        self.probe = probe
        self.network = network
        self.log = log
        self.loc = localization
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
        detail = selected.map { Msg("detail.strategy", $0.name(using: loc)) } ?? Msg("detail.noStrategy")
        notify()
    }

    public func reloadStrategies() {
        strategyStore.writeTemplateIfMissing()
        strategies = StrategyCatalog.load(customText: strategyStore.loadText()) { [log, loc] line in
            log.write(loc.string("log.customSkipped", [CustomStrategyFile.fileName, line]))
        }
    }

    public var selected: Strategy? { strategies.first { $0.id == selectedStrategyId } }
    public var isBusy: Bool { busy }
    /// Quick Scan stops after this many working strategies (Windows `Engine.QuickStopAfter`).
    public var quickStopAfter: Int { max(1, settings.stopAfterWorking) }
    public var currentSettings: AppSettings { settings }

    public func updateSettings(_ new: AppSettings) {
        settings = new
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
                if await apply(s) { return }
                await markFailed(s)
                let others = await confirmedStrategies(except: s)
                if !others.isEmpty {
                    log.write(loc.string("log.savedFailed", [s.name(using: loc)]))
                    if await applyFirstWorking(others) { return }
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
            if await apply(strategy) { await saveSelected(strategy) }
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

    /// Cancels the running operation, if any. Loop bodies check `stopRequested` cooperatively
    /// (see `searchAndApply`); `runningTask?.cancel()` additionally propagates real Swift task
    /// cancellation into whatever `connections.open`/`probe.measure` are doing once a real
    /// implementation exists to honor it.
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
        runningTask = nil
        notify()
    }

    private func notify() { onChanged?() }

    private func setState(_ s: EngineState, _ d: Msg? = nil) {
        state = s
        if let d { detail = d }
        notify()
    }

    private func setProgress(_ done: Int, _ total: Int) {
        progressDone = done
        progressTotal = total
        notify()
    }

    // MARK: - Steps

    private func prepare() async -> Bool {
        setState(.preparing, Msg("detail.preparing"))
        let foreign = network.foreignVPNInterfaceNames()
        if !foreign.isEmpty {
            for name in foreign { log.write(loc.string("log.otherVpn", [name])) }
            log.write(loc.string("log.vpnAdvice"))
        }
        return true
    }

    /// Tests one strategy on a fresh WARP endpoint so it cannot inherit DPI state from a previous
    /// successful connection (Windows `Engine.TestAsync`, Android `ZarpEngine.test`).
    private func test(_ s: Strategy) async -> TestResult {
        let endpoint = settings.isolateTests ? nextEndpoint() : nil
        let handle: WarpConnectionHandle
        do {
            handle = try await connections.open(strategy: s, endpoint: endpoint,
                                                 timeoutMs: settings.testTimeoutSec * 1000, persistent: false)
        } catch let error as WarpConnectionError {
            return error.timedOut
                ? .failed(strategyId: s.id, error: Msg("err.timeout", String(settings.testTimeoutSec)), endpoint: endpoint)
                : .failedRaw(strategyId: s.id, error: error.message, endpoint: endpoint)
        } catch {
            return .failedRaw(strategyId: s.id, error: String(describing: error), endpoint: endpoint)
        }

        let result: TestResult
        do {
            switch try await probe.measure(samples: 3) {
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
            result = .failedRaw(strategyId: s.id, error: String(describing: error), endpoint: handle.endpoint)
        }
        await handle.close()
        return result
    }

    /// - Parameter stopAfter: stop phase 1 after this many working strategies; 0 = test all.
    private func searchAndApply(_ list: [Strategy], stopAfter: Int, title: String) async {
        var candidates: [(Strategy, TestResult)] = []
        log.write(title)
        setProgress(0, list.count)

        // ---- phase 1: walk the list
        for s in list {
            guard !stopRequested else { break }
            setState(.searching, Msg("detail.testing", String(progressDone + 1), String(list.count), s.name(using: loc)))
            let r = await test(s)
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

        // ---- phase 2: independent re-check of every candidate (different endpoint, fresh attempt).
        // Weeds out strategies that "passed" only because of a previous successful connection.
        if !candidates.isEmpty && !stopRequested {
            log.write(loc.string("log.recheck", [String(candidates.count)]))
            let ordered = candidates.sorted { $0.1.score < $1.1.score }
            setProgress(0, ordered.count)
            for (i, pair) in ordered.enumerated() {
                guard !stopRequested else { break }
                let (s, r1) = pair
                setState(.searching, Msg("detail.rechecking", String(i + 1), String(ordered.count), s.name(using: loc)))
                let r2 = await test(s)
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

        if stopRequested {
            await stopAll()
            setState(.idle, Msg("detail.cancelled"))
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
        if !(await applyFirstWorking(confirmed)) {
            setState(.idle, Msg("detail.foundButFailed"))
        }
    }

    /// Confirmed strategies, best (lowest score) first (Windows `Engine.ConfirmedStrategies`).
    public func confirmedStrategies(except: Strategy?) -> [Strategy] {
        strategies
            .filter { $0.id != except?.id && (results[$0.id]?.ok ?? false) && (results[$0.id]?.confirmed ?? false) }
            .sorted { results[$0.id]!.score < results[$1.id]!.score }
    }

    /// Connects with the first strategy in the list that actually connects, and remembers it
    /// (Windows `Engine.ApplyFirstWorkingAsync`).
    private func applyFirstWorking(_ ordered: [Strategy]) async -> Bool {
        for s in ordered {
            guard !stopRequested else { return false }
            if await apply(s) { await saveSelected(s); return true }
            await markFailed(s)
            log.write(loc.string("log.tryNext", [s.name(using: loc)]))
        }
        return false
    }

    private func markFailed(_ s: Strategy) async {
        putResult(.failed(strategyId: s.id, error: Msg("result.applyFailed")))
        saveResults()
    }

    /// Connects with the given strategy and keeps the connection (Windows `Engine.ApplyAsync`).
    private func apply(_ s: Strategy) async -> Bool {
        setState(.connecting, Msg("detail.connectingTo", s.name(using: loc)))
        log.write(loc.string("log.connectingWith", [s.name(using: loc)]))
        await stopAll()

        let timeoutMs = max(30, settings.testTimeoutSec * 2) * 1000
        do {
            let handle = try await connections.open(strategy: s, endpoint: nil, timeoutMs: timeoutMs, persistent: true)
            switch try await probe.measure(samples: 1) {
            case .ok:
                activeConnection = handle
                log.write(loc.string("log.warpConnectedIn", [String(handle.connectMs)]))
                setState(.connected, Msg("detail.strategy", s.name(using: loc)))
                return true
            case .notWarp, .noTraffic:
                await handle.close()
                log.write(loc.string("err.noTraffic"))
            }
        } catch let error as WarpConnectionError {
            log.write(loc.string("log.warpNotConnected"))
            log.write(error.message)
        } catch {
            log.write(loc.string("log.warpNotConnected"))
            log.write(String(describing: error))
        }
        setState(.idle, Msg("detail.connectFailed"))
        return false
    }

    private func stopAll() async {
        if let c = activeConnection {
            activeConnection = nil
            await c.close()
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

    /// A distinct token per attempt so `WarpConnectionProvider` implementations can tell isolated
    /// test attempts apart.
    ///
    /// TODO(real-Mac PoC): once a real `WarpConnectionProvider` exists, decide what "endpoint"
    /// actually means for it — Option A can pin a `warp-cli` endpoint like Windows'
    /// `Warp.NextEndpoint`; Option B's own MASQUE tunnel would pick from its own endpoint list,
    /// closer to Android's `WarpEndpoints`. This placeholder only guarantees the value changes
    /// between calls.
    private func nextEndpoint() -> String {
        defer { endpointSeq += 1 }
        return "isolated-\(endpointSeq)"
    }
}
