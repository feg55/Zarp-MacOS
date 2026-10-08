import XCTest
@testable import ZarpCore

final class LogBusTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zarp-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testKeepsOnlyTheNewestEntriesInMemory() {
        let bus = LogBus(maxEntries: 5)
        for i in 1...12 { bus.write("line \(i)") }
        XCTAssertEqual(bus.snapshot().map(\.text), (8...12).map { "line \($0)" })
    }

    func testWritesFormattedLinesToTheFile() throws {
        let url = dir.appendingPathComponent("logs/zarp.log") // the directory doesn't exist yet
        let bus = LogBus()
        bus.attachFile(url)
        bus.write("hello")
        bus.write("world")
        let lines = try String(contentsOf: url).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("] hello"))
        XCTAssertTrue(lines[1].hasSuffix("] world"))
        XCTAssertNotNil(lines[0].range(of: #"^\[\d\d:\d\d:\d\d\] "#, options: .regularExpression))
    }

    func testImportedLinesKeepTheirOwnTimestamp() {
        let bus = LogBus()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = bus.write("from the daemon", at: when)
        XCTAssertEqual(entry.timestamp, when)
        XCTAssertEqual(bus.snapshot().last?.timestamp, when)
    }

    func testTheFileCapIsEnforcedWhileRunningNotJustAtStartup() throws {
        // A menu-bar app can run for weeks; only checking the size when the file is attached let it
        // grow without bound.
        let url = dir.appendingPathComponent("zarp.log")
        let bus = LogBus(maxFileSize: 2_000)
        bus.attachFile(url)
        for i in 0..<200 { bus.write("a reasonably long log line number \(i) to fill the file up") }

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        XCTAssertLessThanOrEqual(size, 2_000)
        let backup = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the previous generation is kept as .1")
        let backupSize = (try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? UInt64) ?? 0
        XCTAssertLessThanOrEqual(backupSize, 2_000)
        // The newest line is in the live file, in full.
        XCTAssertTrue(try String(contentsOf: url).contains("line number 199"))
    }

    func testAnOversizedFileFromAnEarlierRunIsRotatedAtAttach() throws {
        let url = dir.appendingPathComponent("zarp.log")
        try Data(repeating: UInt8(ascii: "x"), count: 5_000).write(to: url)
        let bus = LogBus(maxFileSize: 1_000)
        bus.attachFile(url)
        bus.write("fresh")
        XCTAssertEqual(try String(contentsOf: url).split(separator: "\n").count, 1)
    }

    func testAFileThatCannotBeWrittenNeverCrashesTheApp() throws {
        // The legacy FileHandle.write(_:) raises an Objective-C exception (uncatchable from Swift)
        // when the write fails — a full disk used to be able to take the app down. Pointing the
        // log at a path whose parent is a regular file makes every write fail.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let bus = LogBus()
        bus.attachFile(blocker.appendingPathComponent("zarp.log"))
        for i in 0..<10 { bus.write("line \(i)") }
        XCTAssertEqual(bus.snapshot().count, 10, "the in-memory log still works")
    }

    func testOnAppendReceivesEveryEntryOutsideTheLock() {
        let bus = LogBus()
        let box = EntryBox()
        bus.onAppend = { box.add($0) }
        bus.write("a")
        bus.write("b")
        // A callback that logs again (a UI hook that reacts to a line by writing another) must not
        // deadlock: onAppend is invoked after the lock is released.
        bus.onAppend = { entry in if entry.text == "trigger" { bus.write("reaction") } }
        bus.write("trigger")
        XCTAssertEqual(box.texts, ["a", "b"])
        XCTAssertEqual(bus.snapshot().map(\.text), ["a", "b", "trigger", "reaction"])
    }

    func testConcurrentWritersDoNotCorruptTheFile() throws {
        let url = dir.appendingPathComponent("zarp.log")
        let bus = LogBus()
        bus.attachFile(url)
        DispatchQueue.concurrentPerform(iterations: 8) { g in
            for i in 0..<50 { bus.write("writer \(g) line \(i)") }
        }
        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 400)
        for line in lines { XCTAssertTrue(line.contains("writer"), "torn line: \(line)") }
    }
}

private final class EntryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    func add(_ e: LogEntry) { lock.lock(); entries.append(e); lock.unlock() }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.text) }
}
