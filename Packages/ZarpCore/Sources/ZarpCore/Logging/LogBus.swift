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
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "[\(f.string(from: timestamp))] \(text)"
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
    /// 2 MB cap on the log file, same as Windows Zarp's `Log.Init`.
    private let maxFileSize: UInt64 = 2 * 1024 * 1024

    public var onAppend: (@Sendable (LogEntry) -> Void)?

    public init(maxEntries: Int = 2000) {
        self.maxEntries = maxEntries
    }

    /// Points the bus at a log file, truncating it if it has already grown past the cap (same
    /// rule as Windows `Log.Init`).
    public func attachFile(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        fileURL = url
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64, size > maxFileSize {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    public func write(_ text: String) -> LogEntry {
        let entry = LogEntry(text: text)
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

    /// Caller must already hold `lock`.
    private func appendToFile(_ entry: LogEntry) {
        guard let fileURL else { return }
        let line = entry.formatted + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL)
        }
    }

    public func snapshot() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
