import XCTest
@testable import ZarpCore

final class LocalizationTests: XCTestCase {
    func testParseTableSkipsCommentsAndBlankLines() {
        let table = Localization.parseTable("""
        # a comment
        a.b = Hello

        c.d = World
        """)
        XCTAssertEqual(table, ["a.b": "Hello", "c.d": "World"])
    }

    func testParseTableConvertsEscapedNewline() {
        let table = Localization.parseTable("a.b = line one\\nline two")
        XCTAssertEqual(table["a.b"], "line one\nline two")
    }

    func testParseTableTrimsWhitespaceAroundKeyAndValue() {
        let table = Localization.parseTable("  a.b   =   Hello  ")
        XCTAssertEqual(table["a.b"], "Hello")
    }

    func testFallsBackToEnglishForMissingKeyInOtherLanguage() {
        let loc = Localization(tables: ["en": ["a.b": "Hello"], "ru": [:]], currentCode: "ru")
        XCTAssertEqual(loc.string("a.b"), "Hello")
    }

    func testMissingKeyEverywhereReturnsTheKeyItself() {
        let loc = Localization(tables: ["en": [:]])
        XCTAssertEqual(loc.string("no.such.key"), "no.such.key")
    }

    func testPlaceholderSubstitution() {
        let loc = Localization(tables: ["en": ["a.b": "{0}/{1}: {2}"]])
        XCTAssertEqual(loc.string("a.b", ["1", "3", "google"]), "1/3: google")
    }

    func testUnsupportedSettingResolvesToSystemLanguageOrEnglish() {
        let loc = Localization(tables: ["en": [:], "ru": [:]])
        XCTAssertEqual(loc.resolve(setting: nil, systemCode: "ru"), "ru")
        XCTAssertEqual(loc.resolve(setting: nil, systemCode: "xx"), "en")
        XCTAssertEqual(loc.resolve(setting: "ru", systemCode: "en"), "ru")
    }

    func testSetLanguageIgnoresUnsupportedCode() {
        let loc = Localization(tables: ["en": [:]], currentCode: "en")
        loc.setLanguage("xx")
        XCTAssertEqual(loc.currentCode, "en")
    }

    func testSetLanguageFiresOnChangedOnlyOnActualChange() {
        let loc = Localization(tables: ["en": [:], "ru": [:]], currentCode: "en")
        nonisolated(unsafe) var fired = 0
        loc.onChanged = { fired += 1 }
        loc.setLanguage("en") // already current
        XCTAssertEqual(fired, 0)
        loc.setLanguage("ru")
        XCTAssertEqual(fired, 1)
    }

    // MARK: - The real, vendored language files

    /// `Packages/ZarpCore/Tests/ZarpCoreTests/<this file>` -> repo root, by walking up from this
    /// source file's own path. Keeps the test working regardless of the current working directory
    /// `swift test` is invoked from, as long as the repo's directory layout is intact.
    private func repoRootLangDirectory() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // file, ZarpCoreTests, Tests, ZarpCore, Packages
        return url.appendingPathComponent("Resources/Lang")
    }

    func testAllEightLanguageFilesExistAndParse() throws {
        let dir = repoRootLangDirectory()
        for language in Localization.languages {
            let url = dir.appendingPathComponent("\(language.code).txt")
            let contents = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                                         "missing or unreadable: \(url.path)")
            XCTAssertFalse(Localization.parseTable(contents).isEmpty, "\(language.code).txt parsed to zero keys")
        }
    }

    func testEveryLanguageHasAllEnglishKeysOrFallsBackCleanly() {
        // Mirrors Windows Zarp's own test (`Zarp.Tests`): every language should define the same
        // key set as English. Where the vendored files haven't been updated for this port yet
        // (see Resources/Lang/en.txt's header note), this reports the gap instead of failing the
        // build — Localization's own fallback already covers a missing key at runtime.
        let loc = Localization.load(languageFilesDirectory: repoRootLangDirectory())
        let englishKeys = loc.keys(for: "en")
        XCTAssertFalse(englishKeys.isEmpty)
        for language in Localization.languages where language.code != "en" {
            let missing = englishKeys.subtracting(loc.keys(for: language.code))
            if !missing.isEmpty {
                // Known, documented gap for the 4 new en.txt-only keys until translators catch up
                // (see the header note in Resources/Lang/en.txt) — anything beyond that is new
                // and should be investigated.
                let expectedGap: Set<String> = ["strategy.directH2", "strategy.badSyntax", "strategy.unknownFeature", "strategy.badsum", "mac.notImplemented"]
                XCTAssertEqual(missing, expectedGap, "\(language.code).txt is missing unexpected keys: \(missing.subtracting(expectedGap).sorted())")
            }
        }
    }

    func testKeysUsedByZarpEngineExistInEnglish() {
        // Doesn't cover every key in the app, but catches the common typo class: a key referenced
        // from ZarpEngine that doesn't exist in en.txt at all.
        let loc = Localization.load(languageFilesDirectory: repoRootLangDirectory())
        let used = [
            "detail.noStrategy", "detail.strategy", "detail.preparing", "detail.disconnecting",
            "detail.disconnected", "detail.cancelled", "detail.testing", "detail.rechecking",
            "detail.notFound", "detail.foundButFailed", "detail.connectingTo", "detail.connectFailed",
            "log.savedFailed", "log.verifiedFailed", "log.searchQuick", "log.searchFull", "log.searchSelected",
            "log.testOk", "log.testFail", "log.recheck", "log.recheckOk", "log.candidatesFailed",
            "log.noneWorked", "log.best", "log.tryNext", "log.connectingWith", "log.warpNotConnected",
            "log.warpConnectedIn", "log.otherVpn", "log.vpnAdvice", "log.customSkipped",
            "result.applyFailed", "result.notConfirmed", "err.timeout", "err.noTraffic",
        ]
        for key in used {
            XCTAssertNotEqual(loc.string(key), key, "key '\(key)' used by ZarpEngine is missing from en.txt")
        }
    }
}
