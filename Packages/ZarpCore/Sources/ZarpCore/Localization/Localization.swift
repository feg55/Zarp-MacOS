import Foundation

/// Loads Zarp's `key = value` language files and resolves keys to text, with English as the
/// fallback for any key missing in the current language — same behavior as Windows Zarp's `L`
/// (`Core/L.cs`) and Android Zarp's `L`. The file format and the shared keys come straight from
/// the Windows `Lang/*.txt` files (MIT), copied into `Resources/Lang` in this project (see that
/// folder's own note on what has and hasn't been hand-edited since).
public final class Localization: @unchecked Sendable {
    public struct Language: Identifiable, Hashable, Sendable {
        public let code: String
        public let nativeName: String
        public var id: String { code }
        public init(code: String, nativeName: String) {
            self.code = code
            self.nativeName = nativeName
        }
    }

    /// Supported languages in menu order — identical list to Windows Zarp's `L.Languages`.
    public static let languages: [Language] = [
        Language(code: "en", nativeName: "English"),
        Language(code: "ru", nativeName: "Русский"),
        Language(code: "es", nativeName: "Español"),
        Language(code: "pt", nativeName: "Português"),
        Language(code: "zh", nativeName: "中文"),
        Language(code: "hi", nativeName: "हिन्दी"),
        Language(code: "fr", nativeName: "Français"),
        Language(code: "de", nativeName: "Deutsch"),
    ]

    public static let fallbackCode = "en"

    public static func isSupported(_ code: String?) -> Bool {
        guard let code else { return false }
        return languages.contains { $0.code == code }
    }

    private let lock = NSLock()
    private var tables: [String: [String: String]]
    private var _currentCode: String

    public var currentCode: String {
        lock.lock(); defer { lock.unlock() }
        return _currentCode
    }

    /// Called after `setLanguage` actually changes the language, mirroring Windows `L.Changed`.
    /// Fires on whatever thread called `setLanguage`; callers hop to the main thread themselves.
    public var onChanged: (@Sendable () -> Void)?

    /// `tables`: language code -> (key -> value), already parsed. Build this with
    /// `Localization.parseTable(_:)` per file, or use `Localization.load(languageFilesDirectory:)`.
    public init(tables: [String: [String: String]], currentCode: String? = nil) {
        self.tables = tables
        self._currentCode = (currentCode.flatMap { Localization.isSupported($0) ? $0 : nil }) ?? Localization.fallbackCode
    }

    /// Resolves a settings value (possibly empty or unsupported, meaning "follow the system") to
    /// a concrete language code — same rule as Windows `L.Resolve`.
    public func resolve(setting: String?, systemCode: String) -> String {
        if Localization.isSupported(setting) { return setting! }
        return Localization.isSupported(systemCode) ? systemCode : Localization.fallbackCode
    }

    public func setLanguage(_ code: String) {
        let resolved = Localization.isSupported(code) ? code : Localization.fallbackCode
        lock.lock()
        let changed = resolved != _currentCode
        if changed { _currentCode = resolved }
        lock.unlock()
        if changed { onChanged?() }
    }

    public func string(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return tables[_currentCode]?[key] ?? tables[Localization.fallbackCode]?[key] ?? key
    }

    public func string(_ key: String, _ args: [String]) -> String {
        let format = string(key)
        guard !args.isEmpty else { return format }
        return Localization.format(format, args)
    }

    public func string(_ key: String, _ args: CustomStringConvertible...) -> String {
        string(key, args.map(\.description))
    }

    /// `{0}`, `{1}`, ... placeholder substitution, same convention as Windows Zarp's language
    /// files. Missing placeholders are left as-is instead of throwing, so a malformed or
    /// not-yet-updated translation never crashes the app — same reasoning as Windows' catch-and-append.
    static func format(_ template: String, _ args: [String]) -> String {
        var out = template
        for (i, arg) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(i)}", with: arg)
        }
        return out
    }

    /// All keys defined for a language (used by the key-parity test).
    public func keys(for code: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard let table = tables[code] else { return [] }
        return Set(table.keys)
    }

    /// Raw value without the English fallback (used by the key-parity test).
    public func raw(_ code: String, _ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tables[code]?[key]
    }

    // MARK: - Loading

    /// Parses one `key = value` file. `\n` in a value becomes a real newline, `#` starts a
    /// comment line, blank lines are ignored — identical format to Windows Zarp's `Lang/*.txt`
    /// (see `L.Parse` there).
    public static func parseTable(_ contents: String) -> [String: String] {
        var table: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            table[key] = value.replacingOccurrences(of: "\\n", with: "\n")
        }
        return table
    }

    /// Builds a `Localization` from a directory of `<code>.txt` files (the layout of
    /// `Resources/Lang`). A missing or unreadable language file is skipped, not thrown, so the app
    /// still runs with whatever loaded — same spirit as Windows `AppConfig.Load`'s error handling.
    public static func load(languageFilesDirectory dir: URL, currentCode: String? = nil) -> Localization {
        var tables: [String: [String: String]] = [:]
        for language in languages {
            let url = dir.appendingPathComponent("\(language.code).txt")
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                tables[language.code] = parseTable(contents)
            }
        }
        return Localization(tables: tables, currentCode: currentCode)
    }
}
