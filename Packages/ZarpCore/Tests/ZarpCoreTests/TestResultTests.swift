import XCTest
@testable import ZarpCore

final class TestResultTests: XCTestCase {
    func testScoreWeightsPingFourTimesConnect() {
        let r = TestResult(strategyId: "s", ok: true, connectMs: 1000, pingMs: 100)
        XCTAssertEqual(r.score, 1000 + 100 * 4)
    }

    func testFailedResultScoresWorstPossible() {
        let r = TestResult.failed(strategyId: "s", error: Msg("err.timeout", "15"))
        XCTAssertEqual(r.score, Int.max)
        XCTAssertFalse(r.ok)
    }

    func testConfirmedMergeTakesSlowerConnectAndAveragePing() {
        let first = TestResult(strategyId: "s", ok: true, connectMs: 800, pingMs: 100)
        let second = TestResult(strategyId: "s", ok: true, connectMs: 1200, pingMs: 140)
        let merged = TestResult.confirmed(first, second)
        XCTAssertEqual(merged.connectMs, 1200) // max, i.e. the more pessimistic figure
        XCTAssertEqual(merged.pingMs, 120)      // average
        XCTAssertTrue(merged.confirmed)
        XCTAssertTrue(merged.ok)
    }

    func testDisplayErrorAddsNotConfirmedFramingOnlyWhenRechecked() {
        let loc = Localization(tables: ["en": [
            "err.timeout": "no connection within {0} s",
            "result.notConfirmed": "not confirmed: {0}",
        ]])
        var r = TestResult.failed(strategyId: "s", error: Msg("err.timeout", "15"))
        XCTAssertEqual(r.displayError(using: loc), "no connection within 15 s")
        r.rechecked = true
        XCTAssertEqual(r.displayError(using: loc), "not confirmed: no connection within 15 s")
    }

    func testCodableRoundTrip() throws {
        // `.iso8601` (the strategy `SettingsStore` actually persists with) has whole-second
        // precision, so the fixture timestamp must already be second-aligned for the round trip
        // to be exactly equal — this is testing the wire format, not `Date` itself.
        let timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let r = TestResult(strategyId: "s", ok: true, connectMs: 500, pingMs: 40, confirmed: true, endpoint: "isolated-3", timestamp: timestamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestResult.self, from: encoder.encode(r))
        XCTAssertEqual(decoded, r)
    }
}
