import Foundation

/// Reads and initializes the user's `strategies.txt`. A protocol so the engine's tests don't touch
/// disk — same reasoning as `SettingsStore`.
public protocol CustomStrategyStore: Sendable {
    func loadText() -> String
    /// Writes `CustomStrategyFile.template` if the file doesn't exist yet (Windows
    /// `StrategyCatalog.Load`'s behavior on first run).
    func writeTemplateIfMissing()
}

/// File-backed store, e.g. `~/Library/Application Support/Zarp/strategies.txt`.
public final class FileCustomStrategyStore: CustomStrategyStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func loadText() -> String {
        lock.lock(); defer { lock.unlock() }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func writeTemplateIfMissing() {
        lock.lock(); defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? CustomStrategyFile.template.data(using: .utf8)?.write(to: url)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryCustomStrategyStore: CustomStrategyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String

    public init(_ text: String = "") {
        self.text = text
    }

    public func loadText() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }

    public func writeTemplateIfMissing() {
        lock.lock(); defer { lock.unlock() }
        if text.isEmpty { text = CustomStrategyFile.template }
    }
}
