import Foundation

/// Reads and initializes the user's `strategies.txt`. A protocol so the engine's tests don't touch
/// disk — same reasoning as `SettingsStore`.
public protocol CustomStrategyStore: Sendable {
    func loadText() -> String
    /// Writes `CustomStrategyFile.template` if the file doesn't exist yet (Windows
    /// `StrategyCatalog.Load`'s behavior on first run).
    func writeTemplateIfMissing()
    /// Replaces the file's contents (the in-app editor's Save). Throws if the file can't be
    /// written, so the editor can say so instead of pretending the user's strategies were saved.
    func saveText(_ text: String) throws
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

    public func saveText(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
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

    public func saveText(_ newText: String) throws {
        lock.lock(); defer { lock.unlock() }
        text = newText
    }
}
