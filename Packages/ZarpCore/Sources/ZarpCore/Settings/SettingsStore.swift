import Foundation

/// Persists `AppSettings` as JSON, same layout as Windows Zarp's `zarp.json`
/// (`%LOCALAPPDATA%\Zarp` there, `~/Library/Application Support/Zarp` here). A protocol so the
/// engine can be tested without touching disk.
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// Something worth telling the user about that a store can't fix by itself (Windows
/// `log.configBroken` / `log.configSaveFailed`).
public enum SettingsStoreProblem: Sendable, Equatable {
    /// The settings file could not be read; defaults are being used. The unreadable file was moved
    /// aside (not deleted) so nothing the user had is lost for good.
    case corrupt(String)
    /// The settings file could not be written.
    case saveFailed(String)
}

/// File-backed store. Pure Foundation file I/O — no networking — so it behaves the same on Linux
/// and macOS.
public final class JSONFileSettingsStore: SettingsStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let onProblem: @Sendable (SettingsStoreProblem) -> Void
    /// Only the first save failure is reported until one succeeds, so a full disk doesn't turn
    /// every scan result into another log line.
    private var reportedSaveFailure = false

    public init(url: URL, onProblem: @escaping @Sendable (SettingsStoreProblem) -> Void = { _ in }) {
        self.url = url
        self.onProblem = onProblem
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            onProblem(.corrupt(error.localizedDescription))
            return AppSettings()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            // Writing defaults over this file at the next save would destroy the only copy of
            // whatever the user had: keep it next to the original under a dated name.
            quarantineCorruptFile()
            onProblem(.corrupt(Self.describe(error)))
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(settings)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            reportedSaveFailure = false
        } catch {
            if !reportedSaveFailure {
                reportedSaveFailure = true
                onProblem(.saveFailed(error.localizedDescription))
            }
        }
    }

    private func quarantineCorruptFile() {
        let stamp = Self.stampFormatter.string(from: Date())
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".corrupt-\(stamp).json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let ctx), .keyNotFound(_, let ctx), .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
                return ctx.debugDescription
            @unknown default: break
            }
        }
        return error.localizedDescription
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
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
