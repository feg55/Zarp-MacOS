import XCTest
@testable import ZarpCore

final class CustomStrategyFileTests: XCTestCase {
    func testParsesAValidLine() {
        let text = "My QUIC | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=8\n"
        let strategies = CustomStrategyFile.parse(text)
        XCTAssertEqual(strategies.count, 1)
        let s = strategies[0]
        XCTAssertEqual(s.id, "custom-my-quic")
        XCTAssertEqual(s.transport, .masqueH3)
        XCTAssertTrue(s.isCustom)
        XCTAssertEqual(s.args, "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=8")
    }

    func testNameGetsAStarMarker() {
        let strategies = CustomStrategyFile.parse("Foo | wg | --payload=wireguard_initiation")
        XCTAssertEqual(strategies.first?.name(using: Localization(tables: [:])), "★ Foo")
    }

    func testCommentsAndBlankLinesAreIgnored() {
        let text = """
        # a comment
        My QUIC | h3 | --payload=quic_initial

        """
        XCTAssertEqual(CustomStrategyFile.parse(text).count, 1)
    }

    func testMalformedLineIsSkippedAndReported() {
        var skipped: [String] = []
        let text = "not enough pipes | h3\nGood | h3 | --payload=quic_initial\n"
        let strategies = CustomStrategyFile.parse(text) { skipped.append($0) }
        XCTAssertEqual(strategies.count, 1)
        XCTAssertEqual(strategies[0].id, "custom-good")
        XCTAssertEqual(skipped, ["not enough pipes | h3"])
    }

    func testUnknownTransportIsSkipped() {
        var skipped: [String] = []
        let strategies = CustomStrategyFile.parse("Foo | xx | --payload=quic_initial") { skipped.append($0) }
        XCTAssertTrue(strategies.isEmpty)
        XCTAssertEqual(skipped.count, 1)
    }

    func testEmptyNameIsSkipped() {
        var skipped: [String] = []
        let strategies = CustomStrategyFile.parse(" | h3 | --payload=quic_initial") { skipped.append($0) }
        XCTAssertTrue(strategies.isEmpty)
        XCTAssertEqual(skipped.count, 1)
    }

    func testLaterDuplicateIdWins() {
        let text = """
        Foo | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=3
        Foo | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_vk:repeats=3
        """
        let strategies = CustomStrategyFile.parse(text)
        XCTAssertEqual(strategies.count, 1)
        XCTAssertTrue(strategies[0].args.contains("quic_vk"))
    }

    func testTemplateParsesAsOnlyComments() {
        // The template Zarp writes on first run must itself parse to zero strategies (every
        // example line in it starts with '#').
        XCTAssertTrue(CustomStrategyFile.parse(CustomStrategyFile.template).isEmpty)
    }
}
