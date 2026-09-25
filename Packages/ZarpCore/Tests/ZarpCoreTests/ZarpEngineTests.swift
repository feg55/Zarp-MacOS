import XCTest
@testable import ZarpCore

// Test-only doubles for `WarpConnectionProvider`/`WarpProbe`, used to verify the scan/self-heal
// state machine in isolation from real networking. These must never appear outside this test
// target — the production code's only stand-ins are the always-throwing `Unimplemented*` types in
// `EngineProtocols.swift`, which do not pretend anything works.

private struct FakeHandle: WarpConnectionHandle {
    let connectMs: Int
    let endpoint: String?
    func close() async {}
}

private actor OneShotGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrived = false
    private var arrivedContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        arrived = true
        arrivedContinuation?.resume()
        arrivedContinuation = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }

    /// Suspends until some call to `wait()` has actually parked on the gate. Lets a test know the
    /// background task reached this exact point deterministically, instead of racing it — spawning
    /// the task only guarantees it was scheduled, not that it has run yet.
    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivedContinuation = $0 }
    }
}

private final class ScriptedConnectionProvider: WarpConnectionProvider, @unchecked Sendable {
    enum Outcome {
        case ok(connectMs: Int)
        case fail(timedOut: Bool = false)
    }

    private let lock = NSLock()
    private var scripts: [String: [Outcome]]
    private(set) var openedIds: [String] = []
    /// If set, the first `open(strategy:)` call whose id matches waits on this gate before
    /// returning — lets a test hold a scan "in progress" to exercise `cancel()`.
    var gateForId: (id: String, gate: OneShotGate)?

    init(_ scripts: [String: [Outcome]]) {
        self.scripts = scripts
    }

    func open(strategy: Strategy, endpoint: String?, timeoutMs: Int, persistent: Bool) async throws -> WarpConnectionHandle {
        if let g = gateForId, g.id == strategy.id { await g.gate.wait() }
        let outcome: Outcome = lock.withLock {
            openedIds.append(strategy.id)
            var list = scripts[strategy.id] ?? [.fail()]
            let next = list.count > 1 ? list.removeFirst() : list[0]
            scripts[strategy.id] = list
            return next
        }
        switch outcome {
        case .ok(let ms): return FakeHandle(connectMs: ms, endpoint: endpoint)
        case .fail(let timedOut): throw WarpConnectionError("scripted failure", timedOut: timedOut)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

private final class AlwaysOnProbe: WarpProbe, Sendable {
    let pingMs: Int
    init(pingMs: Int = 50) { self.pingMs = pingMs }
    func measure(samples: Int) async throws -> WarpMeasurement { .ok(pingMs: pingMs, warp: "on") }
}

@MainActor
final class ZarpEngineTests: XCTestCase {
    private func makeEngine(
        connections: WarpConnectionProvider,
        probe: WarpProbe = AlwaysOnProbe(),
        settings: AppSettings = {
            var s = AppSettings(); s.stopAfterWorking = 1; return s
        }()
    ) -> ZarpEngine {
        ZarpEngine(
            settingsStore: InMemorySettingsStore(settings),
            strategyStore: InMemoryCustomStrategyStore(),
            connections: connections,
            probe: probe,
            network: UnimplementedNetworkInspector(),
            log: LogBus(),
            localization: Localization(tables: ["en": Localization.parseTable(Self.minimalEnglish)])
        )
    }

    /// Just enough English text for `Msg`/log formatting not to matter to these assertions —
    /// full key coverage is `LocalizationTests`' job, not this file's.
    private static let minimalEnglish = """
    detail.strategy = Strategy: {0}
    detail.cancelled = Cancelled
    """

    func testQuickScanStopsAfterFirstWorkingAndConnectsWithIt() async {
        // First in the built-in catalog (see StrategyCatalogTests), scripted to succeed on all
        // three calls a full happy path needs: phase-1 test, phase-2 recheck, final apply.
        let provider = ScriptedConnectionProvider([
            "warp-q-google6": [.ok(connectMs: 120), .ok(connectMs: 130), .ok(connectMs: 110)],
        ])
        let engine = makeEngine(connections: provider)
        await engine.load()

        let started = await engine.search(full: false)
        XCTAssertTrue(started)
        await engine.waitUntilIdle()

        let state = await engine.state
        let selected = await engine.selectedStrategyId
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(selected, "warp-q-google6")
        XCTAssertEqual(provider.openedIds, ["warp-q-google6", "warp-q-google6", "warp-q-google6"])
    }

    func testSelfHealFallsBackToOtherConfirmedStrategyWhenSavedFails() async {
        // "warp-q-google6" is saved but broken; "warp-q-vk6" is already confirmed from an earlier
        // scan. Connect must try the saved one, mark it failed, then fall back — without
        // re-testing the already-confirmed one first (matches Windows `Engine.ConnectAsync`).
        var settings = AppSettings()
        settings.selectedStrategyId = "warp-q-google6"
        settings.results = ["warp-q-vk6": TestResult(strategyId: "warp-q-vk6", ok: true, connectMs: 200, pingMs: 60, confirmed: true)]

        let provider = ScriptedConnectionProvider([
            "warp-q-vk6": [.ok(connectMs: 90)],
        ])
        let engine = makeEngine(connections: provider, settings: settings)
        await engine.load()

        let started = await engine.connect()
        XCTAssertTrue(started)
        await engine.waitUntilIdle()

        let state = await engine.state
        let selected = await engine.selectedStrategyId
        let results = await engine.results
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(selected, "warp-q-vk6")
        XCTAssertEqual(results["warp-q-google6"]?.ok, false)
        XCTAssertEqual(provider.openedIds, ["warp-q-google6", "warp-q-vk6"])
    }

    func testSecondCallWhileBusyIsRefused() async {
        let provider = ScriptedConnectionProvider([:]) // everything fails instantly, doesn't matter here
        let engine = makeEngine(connections: provider)
        await engine.load()

        let first = await engine.search(full: false)
        let second = await engine.search(full: true)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "a second operation must not start while the engine is busy")

        await engine.waitUntilIdle()
        let busyAfter = await engine.isBusy
        XCTAssertFalse(busyAfter)
    }

    func testCancelStopsAScanBeforeLaterStrategiesAreTried() async {
        let gate = OneShotGate()
        let provider = ScriptedConnectionProvider([
            "warp-q-google6": [.ok(connectMs: 100)],
        ])
        provider.gateForId = (id: "warp-q-google6", gate: gate)
        let engine = makeEngine(connections: provider)
        await engine.load()

        let started = await engine.search(full: true) // full scan so it would otherwise walk the whole catalog
        XCTAssertTrue(started)
        // Order matters: request cancellation *while the background task is still parked on the
        // gate*, before releasing it. That guarantees `stopRequested` is already true by the time
        // the in-flight attempt finishes and the loop checks it again — no race with the
        // background task racing ahead to a second strategy between "release" and "cancel".
        // `search` only guarantees the background Task was scheduled, not that it has actually run
        // yet, so wait for it to really reach the gate before cancelling.
        await gate.waitUntilArrived()
        await engine.cancel()
        await gate.open()
        await engine.waitUntilIdle()

        let detail = await engine.detail
        XCTAssertEqual(detail.key, "detail.cancelled")
        // The one attempt already in flight when cancel() landed is allowed to finish; no second
        // strategy id may ever be opened after that.
        XCTAssertEqual(provider.openedIds, ["warp-q-google6"])
    }
}
