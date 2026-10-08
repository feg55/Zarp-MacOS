import Foundation

public struct LogEntry: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let text: String

    public init(timestamp: Date = Date(), text: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.text = text
    }

    /// `[HH:mm:ss] text`, same format as Windows Zarp's log file and Android Zarp's log panel.
    public var formatted: String {
        "[\(LogEntry.timeString(timestamp))] \(text)"
    }

    // One shared formatter (creating a DateFormatter per line is expensive, and a log line is
    // formatted at least twice: once for the file, once for every redraw of the log panel),
    // guarded by a lock so concurrent writers/readers don't depend on its thread-safety.
    private static let formatterLock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func timeString(_ date: Date) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return formatter.string(from: date)
    }
}

/// In-memory log the UI reads, with an optional file sink. Same idea as Windows Zarp's `Log`
/// (`Core/Log.cs`, static) and Android Zarp's `LogBus`; this port is an instance type so tests
/// don't share state through a process-wide singleton.
public final class LogBus: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let maxEntries: Int
    private var fileURL: URL?
    private var fileSize: UInt64 = 0
    /// Cap on the log file, same as Windows Zarp's `Log.Init` (2 MB). Enforced on every write, not
    /// just at startup — a menu-bar app can run for weeks — by moving the full file to `<name>.1`
    /// and starting a fresh one.
    private let maxFileSize: UInt64

    public var onAppend: (@Sendable (LogEntry) -> Void)?

    public init(maxEntries: Int = 2000, maxFileSize: UInt64 = 2 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxFileSize = maxFileSize
    }

    /// Points the bus at a log file, starting a fresh one if the existing file has already grown
    /// past the cap (same rule as Windows `Log.Init`).
    public func attachFile(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        fileURL = url
        fileSize = Self.size(of: url)
        if fileSize > maxFileSize { rotate(url) }
    }

    @discardableResult
    public func write(_ text: String) -> LogEntry {
        write(text, at: Date())
    }

    /// Writes a line that happened at `timestamp` — for lines imported from another process (the
    /// daemon's own log), which keep the time they actually occurred.
    @discardableResult
    public func write(_ text: String, at timestamp: Date) -> LogEntry {
        let entry = LogEntry(timestamp: timestamp, text: text)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        appendToFile(entry)
        lock.unlock()
        onAppend?(entry)
        return entry
    }

    @discardableResult
    public func write(_ msg: Msg, using loc: Localization) -> LogEntry {
        write(msg.text(using: loc))
    }

    /// Caller must already hold `lock`. Failures are swallowed on purpose: a log that can't be
    /// written must never take the app down (the throwing FileHandle APIs are used so a full disk
    /// is an error here, not an Objective-C exception that Swift cannot catch).
    private func appendToFile(_ entry: LogEntry) {
        guard let fileURL else { return }
        guard let data = (entry.formatted + "\n").data(using: .utf8) else { return }
        if fileSize > 0, fileSize + UInt64(data.count) > maxFileSize { rotate(fileURL) }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL)
            }
            fileSize += UInt64(data.count)
        } catch {
            // Nowhere sensible to report this to; try again on the next line.
        }
    }

    /// Caller must already hold `lock`.
    private func rotate(_ url: URL) {
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        if (try? FileManager.default.moveItem(at: url, to: backup)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
        fileSize = 0
    }

    private static func size(of url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    public func snapshot() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
