import XCTest
@testable import ZarpCore

/// Every localization key the code mentions must exist. A typo'd key doesn't fail anywhere — the
/// UI just shows the raw key ("daemon.badLocaton") — so this scans the sources for them.
final class LocalizationKeyUsageTests: XCTestCase {
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // file, ZarpCoreTests, Tests, ZarpCore, Packages
        return url
    }

    /// Prefixes that mark a string literal as a localization key.
    private static let keyPrefixes = [
        "main", "lang", "status", "hint", "tray", "dlg", "close", "settings", "col", "btn", "tip", "opt",
        "result", "strategy", "detail", "progress", "err", "log", "daemon", "custom", "terms",
    ]

    private func swiftFiles(under relative: String) -> [URL] {
        let base = repoRoot().appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Key -> the first source file that mentions it, for every key literal in the app's sources.
    private func keysUsedInCode() throws -> [String: String] {
        let alternation = Self.keyPrefixes.joined(separator: "|")
        let regex = try NSRegularExpression(pattern: "\"((?:\(alternation))\\.[A-Za-z0-9]+(?:\\.[A-Za-z0-9]+)*)\"")
        var used: [String: String] = [:]
        let files = swiftFiles(under: "App/Sources") + swiftFiles(under: "Packages/ZarpCore/Sources")
        XCTAssertFalse(files.isEmpty, "found no sources to scan — did the layout change?")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range(at: 1), in: text) {
                    used[String(text[r]), default: file.lastPathComponent] = file.lastPathComponent
                }
            }
        }
        XCTAssertGreaterThan(used.count, 50, "the scan should find the app's many keys; found \(used.count)")
        return used
    }

    func testEveryKeyReferencedFromCodeExistsInEveryLanguage() throws {
        let loc = Localization.load(languageFilesDirectory: repoRoot().appendingPathComponent("Resources/Lang"))
        for (key, file) in try keysUsedInCode().sorted(by: { $0.key < $1.key }) {
            for language in Localization.languages {
                XCTAssertNotNil(loc.raw(language.code, key), "'\(key)' (used in \(file)) is missing from \(language.code).txt")
            }
        }
    }

    /// The other direction: a key nothing asks for is dead text that every translator would still have
    /// to translate. (If a key is ever built at run time rather than written out as a literal, list its
    /// prefix in `dynamicallyBuiltPrefixes` so it is not reported.)
    func testNoKeyIsDefinedThatTheCodeNeverUses() throws {
        let dynamicallyBuiltPrefixes: [String] = []
        let loc = Localization.load(languageFilesDirectory: repoRoot().appendingPathComponent("Resources/Lang"))
        let used = Set(try keysUsedInCode().keys)
        let dead = loc.keys(for: "en").filter { key in
            !used.contains(key) && !dynamicallyBuiltPrefixes.contains { key.hasPrefix($0) }
        }
        XCTAssertEqual(dead.sorted(), [], "defined in the language files but never used by the app")
    }

    func testNoEnglishKeyIsAccidentallyDefinedTwice() throws {
        let text = try String(contentsOf: repoRoot().appendingPathComponent("Resources/Lang/en.txt"), encoding: .utf8)
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(seen.insert(key).inserted, "'\(key)' is defined twice in en.txt — the later one silently wins")
        }
    }
}
