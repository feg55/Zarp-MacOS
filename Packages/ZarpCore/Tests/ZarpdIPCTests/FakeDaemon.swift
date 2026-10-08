import Darwin
import Foundation

/// A stand-in for zarpd: a Unix-socket server whose behavior per connection is scripted by the test.
/// It speaks the same newline-delimited JSON as `zarpd/ipc`, so the real `ZarpdClient` runs against
/// real sockets, real byte streams and real failure modes (hung peer, early close, refusal, huge answer).
final class FakeDaemon: @unchecked Sendable {
    /// What to do with one connection, after its request line has been read.
    enum Behavior {
        /// Answer with `result`/`error` JSON built from the request's id.
        case reply(result: String)
        case error(message: String, timedOut: Bool = false, code: String? = nil)
        /// Send these exact bytes (e.g. an answer in a shape the test controls).
        case raw(String)
        /// Read the request and then say nothing, holding the connection open.
        case hang
        /// Accept and close immediately, without reading anything.
        case closeImmediately
        /// Write a refusal line and close without reading the request (what zarpd does to a peer
        /// that fails its credential check).
        case refuse(code: String, message: String)
        /// Send this many bytes of junk with no newline.
        case flood(bytes: Int)
    }

    let path: String
    private var listenFd: Int32 = -1
    private let lock = NSLock()
    private var behaviorFor: @Sendable (Request) -> Behavior
    private var _requests: [Request] = []
    private var _connections = 0
    private var _disconnects = 0
    private var stopping = false

    struct Request {
        let raw: String
        let id: UInt64
        let method: String
        /// The decoded `params` object, if any.
        let params: [String: Any]
    }

    init(behavior: @escaping @Sendable (Request) -> Behavior = { _ in .reply(result: "{}") }) throws {
        // Unix socket paths are limited to ~104 bytes; keep the name short and under /tmp.
        path = "/tmp/zfd-\(UUID().uuidString.prefix(8)).sock"
        behaviorFor = behavior
        try start()
    }

    deinit { stop() }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return _connections }
    var disconnectCount: Int { lock.lock(); defer { lock.unlock() }; return _disconnects }

    func setBehavior(_ b: @escaping @Sendable (Request) -> Behavior) {
        lock.lock(); behaviorFor = b; lock.unlock()
    }

    private func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buf = raw.bindMemory(to: CChar.self)
            for (i, b) in bytes.enumerated() { buf[i] = CChar(bitPattern: b) }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard rc == 0 else { close(fd); throw posixError("bind") }
        guard listen(fd, 32) == 0 else { close(fd); throw posixError("listen") }
        listenFd = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        lock.lock()
        if stopping { lock.unlock(); return }
        stopping = true
        let fd = listenFd
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(path)
    }

    private func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            lock.lock(); _connections += 1; lock.unlock()
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer {
            close(client)
            lock.lock(); _disconnects += 1; lock.unlock()
        }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        lock.lock(); let probe = behaviorFor(Request(raw: "", id: 0, method: "", params: [:])); lock.unlock()
        // Behaviors that act before any request is read:
        switch probe {
        case .closeImmediately: return
        case .refuse(let code, let message):
            write(client, "{\"id\":0,\"error\":{\"message\":\"\(message)\",\"timedOut\":false,\"code\":\"\(code)\"}}\n")
            return
        default: break
        }

        guard let line = readLine(client) else { return }
        let request = parse(line)
        lock.lock(); _requests.append(request); let behavior = behaviorFor(request); lock.unlock()

        switch behavior {
        case .reply(let result):
            write(client, "{\"id\":\(request.id),\"result\":\(result)}\n")
        case .error(let message, let timedOut, let code):
            let codePart = code.map { ",\"code\":\"\($0)\"" } ?? ""
            write(client, "{\"id\":\(request.id),\"error\":{\"message\":\"\(message)\",\"timedOut\":\(timedOut)\(codePart)}}\n")
        case .raw(let text):
            write(client, text)
        case .hang:
            // Hold the connection until the client goes away.
            var b: UInt8 = 0
            while read(client, &b, 1) > 0 {}
        case .flood(let bytes):
            let chunk = String(repeating: "x", count: 64 * 1024)
            var sent = 0
            while sent < bytes {
                if !write(client, chunk) { break }
                sent += chunk.utf8.count
            }
        case .closeImmediately, .refuse:
            break
        }
    }

    @discardableResult
    private func write(_ fd: Int32, _ text: String) -> Bool {
        let data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var b: UInt8 = 0
        while true {
            let n = read(fd, &b, 1)
            if n <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if b == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b)
        }
    }

    private func parse(_ line: String) -> Request {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Request(raw: line, id: 0, method: "", params: [:])
        }
        let id = (obj["id"] as? NSNumber)?.uint64Value ?? 0
        return Request(raw: line, id: id, method: obj["method"] as? String ?? "", params: obj["params"] as? [String: Any] ?? [:])
    }
}

/// Polls until `condition` holds (or a timeout), for the asynchronous side effects a fake daemon
/// observes (a disconnect, a request arriving).
func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
