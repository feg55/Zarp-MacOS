import XCTest
@testable import ZarpCore

/// Inputs that used to be mis-parsed *silently* — each of these produced a plausible-looking wrong
/// answer rather than an error.
final class ParsingRobustnessTests: XCTestCase {
    // MARK: - Language files

    func testCRLFLanguageFilesParse() {
        // Swift treats "\r\n" as ONE Character, so splitting on "\n" never splits a CRLF file: only
        // its first key survived. The language files are vendored from a Windows app.
        let table = Localization.parseTable("# comment\r\na = one\r\nb = two\r\n\r\nc = three\r\n")
        XCTAssertEqual(table, ["a": "one", "b": "two", "c": "three"])
    }

    func testLoneCRAndByteOrderMarkParse() {
        XCTAssertEqual(Localization.parseTable("a = 1\rb = 2"), ["a": "1", "b": "2"])
        XCTAssertEqual(Localization.parseTable("\u{FEFF}a = 1\nb = 2"), ["a": "1", "b": "2"], "a BOM must not become part of the first key")
    }

    func testEscapedNewlineStillWorks() {
        XCTAssertEqual(Localization.parseTable("a = line one\\nline two")["a"], "line one\nline two")
    }

    func testPlaceholdersAreNotSubstitutedTwice() {
        // A value containing "{1}" (an error message, a strategy name the user typed) used to be
        // rewritten by the next argument.
        XCTAssertEqual(Localization.format("{0} / {1}", ["{1}", "X"]), "{1} / X")
        XCTAssertEqual(Localization.format("{1} then {0}", ["a", "b"]), "b then a")
        XCTAssertEqual(Localization.format("{0}{0}", ["ab"]), "abab")
    }

    func testMalformedPlaceholdersAreLeftAlone() {
        XCTAssertEqual(Localization.format("{5} {x} { } {+0} {-1} {", ["a"]), "{5} {x} { } {+0} {-1} {")
        XCTAssertEqual(Localization.format("no placeholders", ["unused"]), "no placeholders")
        XCTAssertEqual(Localization.format("{0}", []), "{0}")
        XCTAssertEqual(Localization.format("{10}", (0...10).map(String.init)), "10")
        XCTAssertEqual(Localization.format("{1}", ["a"]), "{1}")
    }

    func testFormatHandlesNonASCIIText() {
        XCTAssertEqual(Localization.format("Стратегия «{0}» — {1} мс", ["fake ×6", "120"]), "Стратегия «fake ×6» — 120 мс")
    }

    // MARK: - strategies.txt

    func testCRLFCustomStrategiesFileParses() {
        let text = "# header\r\nOne | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=2\r\nTwo | h2 | --payload=tls_client_hello --lua-desync=multisplit:pos=1\r\n"
        let strategies = CustomStrategyFile.parse(text)
        XCTAssertEqual(strategies.map(\.id), ["custom-one", "custom-two"])
    }

    func testCustomStrategiesFileWithBOMParses() {
        let strategies = CustomStrategyFile.parse("\u{FEFF}One | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=2\n")
        XCTAssertEqual(strategies.map(\.id), ["custom-one"])
    }

    // MARK: - strategy arguments

    func testAnUnreadableRepeatCountIsAnErrorNotOne() {
        // "repeats=6x" used to silently become 1 repeat: the strategy ran — and was scored — as
        // something other than what the user wrote.
        for bad in ["6x", "", "six", "1.5", "-3", "0", "51", "99999999999999999999"] {
            let plan = StrategyArgsParser.parse(transport: .masqueH3,
                args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=\(bad)")
            XCTAssertNotNil(plan.parseIssue, "repeats='\(bad)' must be rejected")
            XCTAssertTrue(plan.fakeSteps.isEmpty, "repeats='\(bad)'")
        }
        let ok = StrategyArgsParser.parse(transport: .masqueH3, args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=50")
        XCTAssertEqual(ok.fakeSteps.first?.repeats, 50)
    }

    func testTheRepeatErrorSaysWhatIsWrong() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6x")
        XCTAssertEqual(plan.parseIssue?.key, "strategy.badSyntax")
        XCTAssertTrue(plan.parseIssue?.args.first?.contains("6x") ?? false)
        let range = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=500")
        XCTAssertTrue(range.parseIssue?.args.first?.contains("1-50") ?? false)
    }

    func testAFakeWithoutRepeatsIsOne() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3, args: "--payload=quic_initial --lua-desync=fake:blob=quic_google")
        XCTAssertEqual(plan.fakeSteps.first?.repeats, 1)
    }

    func testADuplicatedParameterIsMalformed() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:blob=quic_vk:repeats=3")
        XCTAssertNotNil(plan.parseIssue, "the later blob used to silently win")
        XCTAssertTrue(plan.fakeSteps.isEmpty)
    }

    // MARK: - IP addresses

    func testIPv4RequiresPlainDigits() {
        XCTAssertEqual(IPAddress("162.159.198.1"), .v4(0xA29FC601))
        for bad in ["+1.+2.+3.+4", "1.2.3.+4", "1.2.3", "1.2.3.4.5", "1.2.3.256", "1.2.3.", "٣.٣.٣.٣", "1.2.3.04x", " 1.2.3.4", ""] {
            XCTAssertNil(IPAddress(bad), "'\(bad)' must not parse")
        }
    }

    func testIPv6RequiresHexDigits() {
        XCTAssertNotNil(IPAddress("2606:4700:4700::1111"))
        XCTAssertNotNil(IPAddress("::"))
        for bad in ["+1::", "2606:4700::zzzz", "1:2:3:4:5:6:7:8:9", "1::2::3", ":::", "12345::"] {
            XCTAssertNil(IPAddress(bad), "'\(bad)' must not parse")
        }
    }

    func testIPAddressRoundTripsThroughText() {
        for text in ["10.0.0.1", "2606:4700:4700::1111", "::1", "fe80::"] {
            XCTAssertEqual(IPAddress(text).map(\.description), text)
        }
    }
}
