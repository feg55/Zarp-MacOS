import XCTest
@testable import ZarpCore

final class StrategyCatalogTests: XCTestCase {
    func testBuiltInIdsAreUnique() {
        let ids = StrategyCatalog.builtIn.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate strategy id in the built-in catalog")
    }

    func testBuiltInIsNotEmptyAndOrderIsStable() {
        // Order matters: the scan walks the list top to bottom, most-likely-first, same as
        // Windows Zarp. This just pins the first and last entries so a reorder is caught.
        XCTAssertEqual(StrategyCatalog.builtIn.first?.id, "warp-q-google6")
        XCTAssertEqual(StrategyCatalog.builtIn.last?.id, "direct-h2")
    }

    func testDirectControlStrategiesHaveNoDesync() {
        for id in ["direct", "direct-h2"] {
            let s = StrategyCatalog.builtIn.first { $0.id == id }
            XCTAssertNotNil(s, id)
            XCTAssertFalse(s!.requiresDesync, id)
            XCTAssertTrue(s!.plan.isDirect, id)
        }
    }

    func testEveryBuiltInStrategyParsesWithoutError() {
        // Parsing must never crash regardless of what the technique needs — a `parseIssue` is a
        // valid, expected outcome for several of these (badsum, seqovl, md5, hostfakesplit).
        for s in StrategyCatalog.builtIn {
            _ = s.plan // must not trap
        }
    }

    func testKnownCleanStrategiesHaveNoParseIssue() {
        // These use nothing beyond a plain fake-packet send or a plain TCP split, so the parser
        // should describe them cleanly (readiness is a separate question — see StrategyReadiness).
        let cleanIds = ["warp-q-google6", "warp-q-google3", "warp-q-vk6", "warp-q-google-vk",
                         "warp-q-google10", "warp-q-google-ttl", "warp-q-vk-ttl",
                         "warp-wg-google6", "warp-wg-stun", "warp-wg-vk10", "warp-wg-google-ttl",
                         "warp-t-split", "warp-t-disorder"]
        for id in cleanIds {
            let s = StrategyCatalog.builtIn.first { $0.id == id }
            XCTAssertNotNil(s, id)
            XCTAssertNil(s!.plan.parseIssue, "\(id) should parse cleanly, got \(String(describing: s!.plan.parseIssue))")
        }
    }

    func testKnownRawStrategiesAreFlagged() {
        // These need more than macOS's plain socket send/split can do (checksum tampering,
        // sequence-number games, TCP options) — the parser must say so, not silently accept them.
        let rawIds = ["warp-q-google-bad", "warp-t-google-md5", "warp-t-seqovl", "warp-t-vk-seq", "warp-t-hostfake"]
        for id in rawIds {
            let s = StrategyCatalog.builtIn.first { $0.id == id }
            XCTAssertNotNil(s, id)
            XCTAssertNotNil(s!.plan.parseIssue, "\(id) should be flagged as needing more than a basic send")
        }
    }

    func testLoadAppendsCustomStrategiesAfterBuiltIn() {
        let custom = "My QUIC | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=8\n"
        let all = StrategyCatalog.load(customText: custom)
        XCTAssertEqual(all.count, StrategyCatalog.builtIn.count + 1)
        XCTAssertEqual(all.last?.id, "custom-my-quic")
        XCTAssertTrue(all.last?.isCustom ?? false)
    }

    func testReadinessSaysWhichStrategiesTheDaemonCanActuallyRun() {
        // Everything the daemon can execute: fake-packet sends (QUIC) and plain TCP splits (HTTP/2),
        // plus the two direct controls. Everything else must be marked unsupported *with a reason*,
        // because an unsupported strategy sent to the daemon anyway would run as a plain direct
        // connection and be scored as if it had worked.
        let supported = Set(StrategyCatalog.builtIn.filter { $0.readiness == .available }.map(\.id))
        XCTAssertEqual(supported, [
            "warp-q-google6", "warp-q-google3", "warp-q-vk6", "warp-q-google-vk", "warp-q-google10",
            "warp-q-google-ttl", "warp-q-vk-ttl", "warp-t-split", "warp-t-disorder", "direct", "direct-h2",
        ])
        let unsupported = Set(StrategyCatalog.builtIn.filter { $0.unsupportedReason != nil }.map(\.id))
        XCTAssertEqual(unsupported, [
            "warp-q-google-bad", "warp-t-google-md5", "warp-t-seqovl", "warp-t-vk-seq", "warp-t-hostfake",
            "warp-wg-google6", "warp-wg-stun", "warp-wg-vk10", "warp-wg-google-ttl",
        ])
        for s in StrategyCatalog.builtIn where s.unsupportedReason != nil {
            XCTAssertNotEqual(s.unsupportedReason?.key, "", s.id)
        }
        XCTAssertEqual(StrategyCatalog.builtIn.first { $0.id == "warp-wg-stun" }?.unsupportedReason?.key, "strategy.wgUnsupported")
        XCTAssertEqual(StrategyCatalog.builtIn.first { $0.id == "warp-q-google-bad" }?.unsupportedReason?.key, "strategy.badsum")
    }

    func testAnUnsupportedStrategyHasAnEmptyPlanSoItMustNeverBeSentToTheDaemon() {
        // This is *why* readiness matters: the wire format only carries fake steps and a TCP split.
        for id in ["warp-q-google-bad", "warp-t-google-md5", "warp-t-seqovl", "warp-t-vk-seq", "warp-t-hostfake"] {
            let plan = StrategyCatalog.builtIn.first { $0.id == id }!.plan
            XCTAssertTrue(plan.fakeSteps.isEmpty && plan.tcpDesync == nil, "\(id) would be sent as a direct connection")
        }
    }
}
