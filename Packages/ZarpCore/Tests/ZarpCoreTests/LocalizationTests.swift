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

    func testEveryLanguageDefinesExactlyTheEnglishKeys() {
        // en.txt is the reference. A language that lacks a key silently shows English for it; one that
        // has an extra key is carrying text nothing displays any more.
        let loc = Localization.load(languageFilesDirectory: repoRootLangDirectory())
        let englishKeys = loc.keys(for: "en")
        XCTAssertFalse(englishKeys.isEmpty)
        for language in Localization.languages where language.code != "en" {
            let keys = loc.keys(for: language.code)
            XCTAssertEqual(englishKeys.subtracting(keys).sorted(), [],
                           "\(language.code).txt lacks keys that en.txt defines")
            XCTAssertEqual(keys.subtracting(englishKeys).sorted(), [],
                           "\(language.code).txt defines keys that en.txt does not")
        }
    }

    func testEveryLanguageKeepsTheSamePlaceholdersAsEnglish() {
        // A translation that forgets "{1}" silently drops information from a message.
        let loc = Localization.load(languageFilesDirectory: repoRootLangDirectory())
        func placeholders(_ text: String) -> Set<String> {
            var found = Set<String>()
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                let inner = rest[rest.index(after: open)..<close]
                if Int(inner) != nil { found.insert(String(inner)) }
                rest = rest[rest.index(after: close)...]
            }
            return found
        }
        for language in Localization.languages where language.code != "en" {
            for key in loc.keys(for: "en").sorted() {
                guard let english = loc.raw("en", key), let translated = loc.raw(language.code, key) else { continue }
                XCTAssertEqual(placeholders(translated), placeholders(english),
                               "\(language.code).txt: '\(key)' has different {n} placeholders than en.txt")
            }
        }
    }

    func testNoTranslationIsEmptyOrMentionsWindowsOnlyConcepts() {
        // The first translations were vendored from the Windows app, whose text talks about WinDivert,
        // Defender and the tray. None of that exists here, and an empty value would show a blank label.
        let loc = Localization.load(languageFilesDirectory: repoRootLangDirectory())
        let windowsOnly = ["windows", "windivert", "winws", "defender", "warp-cli", ".exe"]
        for language in Localization.languages {
            for key in loc.keys(for: language.code).sorted() {
                let value = loc.raw(language.code, key) ?? ""
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.code).txt: '\(key)' is empty")
                let lowered = value.lowercased()
                for word in windowsOnly {
                    XCTAssertFalse(lowered.contains(word), "\(language.code).txt: '\(key)' mentions \(word), which this app does not have")
                }
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
