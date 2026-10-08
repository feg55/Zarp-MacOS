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

    func testEveryKeyReferencedFromCodeExistsInEnglishAndRussian() throws {
        let loc = Localization.load(languageFilesDirectory: repoRoot().appendingPathComponent("Resources/Lang"))
        let alternation = Self.keyPrefixes.joined(separator: "|")
        let regex = try NSRegularExpression(pattern: "\"((?:\(alternation))\\.[A-Za-z0-9]+(?:\\.[A-Za-z0-9]+)*)\"")

        var used: [String: String] = [:] // key -> first file mentioning it
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
        for (key, file) in used.sorted(by: { $0.key < $1.key }) {
            XCTAssertNotNil(loc.raw("en", key), "'\(key)' (used in \(file)) is missing from en.txt")
            XCTAssertNotNil(loc.raw("ru", key), "'\(key)' (used in \(file)) is missing from ru.txt")
        }
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
