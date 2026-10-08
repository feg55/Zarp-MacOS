import XCTest
@testable import ZarpCore

final class SettingsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zarp-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func decode(_ json: String) throws -> AppSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppSettings.self, from: Data(json.utf8))
    }

    // MARK: - Lenient decoding

    func testAFileFromAnOlderBuildKeepsEverythingItHad() throws {
        // Written before routeAllTraffic / overrideDNS / reconnectOnLoss / warpTermsAccepted existed.
        // Synthesized Codable would have thrown on the missing keys and the store would have
        // silently reset *all* settings, results and the saved strategy to defaults.
        let old = """
        {"selectedStrategyId":"warp-q-google6","testTimeoutSec":20,"stopAfterWorking":2,"autoConnectOnStart":true,
         "askBeforeClose":false,"minimizeToMenuBar":false,"disconnectOnExit":false,"isolateTests":false,
         "restrictToWarpAddresses":true,"results":{"warp-q-google6":{"strategyId":"warp-q-google6","ok":true,
         "connectMs":120,"pingMs":30,"confirmed":true,"timestamp":"2026-09-26T10:00:00Z"}}}
        """
        let s = try decode(old)
        XCTAssertEqual(s.selectedStrategyId, "warp-q-google6")
        XCTAssertEqual(s.testTimeoutSec, 20)
        XCTAssertEqual(s.stopAfterWorking, 2)
        XCTAssertTrue(s.autoConnectOnStart)
        XCTAssertFalse(s.askBeforeClose)
        XCTAssertFalse(s.disconnectOnExit)
        XCTAssertFalse(s.isolateTests)
        XCTAssertEqual(s.results["warp-q-google6"]?.connectMs, 120)
        XCTAssertEqual(s.results["warp-q-google6"]?.confirmed, true)
        // New fields take their defaults; the unknown legacy key is ignored.
        XCTAssertTrue(s.routeAllTraffic)
        XCTAssertTrue(s.overrideDNS)
        XCTAssertTrue(s.reconnectOnLoss)
        XCTAssertFalse(s.warpTermsAccepted)
    }

    func testAnEmptyObjectIsJustTheDefaults() throws {
        XCTAssertEqual(try decode("{}"), AppSettings())
    }

    func testOneWronglyTypedFieldDoesNotCostTheOthers() throws {
        let s = try decode(#"{"testTimeoutSec":"fifteen","stopAfterWorking":5,"language":7,"selectedStrategyId":"direct"}"#)
        XCTAssertEqual(s.testTimeoutSec, AppSettings().testTimeoutSec)
        XCTAssertEqual(s.stopAfterWorking, 5)
        XCTAssertNil(s.language)
        XCTAssertEqual(s.selectedStrategyId, "direct")
    }

    func testOneDamagedResultDoesNotCostTheOthers() throws {
        let s = try decode("""
        {"results":{"good":{"strategyId":"good","ok":true,"connectMs":10,"pingMs":5},
                    "broken":"not an object",
                    "alsoBroken":{"ok":true}}}
        """)
        XCTAssertEqual(Set(s.results.keys), ["good"])
    }

    func testNumericSettingsAreClampedToWhatTheUIOffers() throws {
        let s = try decode(#"{"testTimeoutSec":0,"stopAfterWorking":100000}"#)
        XCTAssertEqual(s.testTimeoutSec, 5)
        XCTAssertEqual(s.stopAfterWorking, 100)
        XCTAssertEqual(try decode(#"{"testTimeoutSec":-9}"#).testTimeoutSec, 5)
        XCTAssertEqual(try decode(#"{"testTimeoutSec":9999}"#).testTimeoutSec, 60)
    }

    func testResultsWithMissingFieldsAreStillResults() throws {
        let s = try decode(#"{"results":{"x":{"strategyId":"x"}}}"#)
        XCTAssertEqual(s.results["x"]?.ok, false)
        XCTAssertEqual(s.results["x"]?.connectMs, 0)
    }

    // MARK: - The file store

    func testRoundTrip() {
        let url = dir.appendingPathComponent("zarp.json")
        let store = JSONFileSettingsStore(url: url)
        var s = AppSettings()
        s.selectedStrategyId = "warp-q-vk6"
        s.routeAllTraffic = false
        s.warpTermsAccepted = true
        s.results = ["warp-q-vk6": TestResult(strategyId: "warp-q-vk6", ok: true, connectMs: 99, pingMs: 11, confirmed: true)]
        store.save(s)
        let loaded = store.load()
        XCTAssertEqual(loaded.selectedStrategyId, "warp-q-vk6")
        XCTAssertFalse(loaded.routeAllTraffic)
        XCTAssertTrue(loaded.warpTermsAccepted)
        XCTAssertEqual(loaded.results["warp-q-vk6"]?.pingMs, 11)
    }

    func testMissingFileIsQuietlyTheDefaults() {
        let problems = ProblemBox()
        let store = JSONFileSettingsStore(url: dir.appendingPathComponent("nope.json"), onProblem: problems.add)
        XCTAssertEqual(store.load(), AppSettings())
        XCTAssertTrue(problems.all.isEmpty, "a first run is not a problem")
    }

    func testACorruptFileIsKeptAsideNotOverwritten() throws {
        let url = dir.appendingPathComponent("zarp.json")
        try Data("{ this is not json".utf8).write(to: url)
        let problems = ProblemBox()
        let store = JSONFileSettingsStore(url: url, onProblem: problems.add)

        XCTAssertEqual(store.load(), AppSettings())
        XCTAssertEqual(problems.all.count, 1)
        if case .corrupt = problems.all[0] {} else { XCTFail("expected a .corrupt problem, got \(problems.all)") }

        // The user's file is preserved under a dated name; the next save writes a fresh one.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("zarp.corrupt-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(aside[0])), "{ this is not json")
        store.save(AppSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testASaveFailureIsReportedOnceUntilItRecovers() throws {
        // A "directory" that is really a file: createDirectory/write must fail.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let problems = ProblemBox()
        let store = JSONFileSettingsStore(url: blocker.appendingPathComponent("zarp.json"), onProblem: problems.add)
        for _ in 0..<5 { store.save(AppSettings()) }
        XCTAssertEqual(problems.all.count, 1, "a full disk must not turn every scan result into another log line")
        if case .saveFailed = problems.all[0] {} else { XCTFail("expected .saveFailed, got \(problems.all)") }
    }

    func testSaveIsAtomicAndLeavesNoTemporaryFiles() throws {
        let url = dir.appendingPathComponent("zarp.json")
        let store = JSONFileSettingsStore(url: url)
        for i in 0..<20 {
            var s = AppSettings()
            s.testTimeoutSec = 5 + i
            store.save(s)
        }
        XCTAssertEqual(store.load().testTimeoutSec, 24)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["zarp.json"])
    }
}

private final class ProblemBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SettingsStoreProblem] = []
    var all: [SettingsStoreProblem] { lock.lock(); defer { lock.unlock() }; return items }
    var add: @Sendable (SettingsStoreProblem) -> Void {
        { [self] p in lock.lock(); items.append(p); lock.unlock() }
    }
}
