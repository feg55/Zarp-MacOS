import Foundation

/// Persists `AppSettings` as JSON, same layout as Windows Zarp's `zarp.json`
/// (`%LOCALAPPDATA%\Zarp` there, `~/Library/Application Support/Zarp` here). A protocol so the
/// engine can be tested without touching disk.
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// File-backed store. Pure Foundation file I/O — no networking — so it behaves the same on Linux
/// and macOS.
public final class JSONFileSettingsStore: SettingsStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(_ settings: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// In-memory store for tests and previews.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AppSettings

    public init(_ initial: AppSettings = AppSettings()) {
        current = initial
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func save(_ settings: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        current = settings
    }
}
