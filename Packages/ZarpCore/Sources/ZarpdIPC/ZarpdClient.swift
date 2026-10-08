import Darwin
import Foundation
import ZarpCore

/// `WarpConnectionProvider` + `WarpProbe` implementation talking to `zarpd` over the Unix domain
/// socket IPC described in `docs/ARCHITECTURE.md` §9.4 / `zarpd/ipc/protocol.go`: newline-delimited
/// JSON, one request per line, one response per line. Each call opens its own short-lived
/// connection (connect, send one line, read one line, close) rather than multiplexing several
/// requests over one persistent connection — simpler, and call frequency here (scan/connect
/// actions and a few-second status poll, not a data path) makes the per-call connection overhead
/// irrelevant. The actual WARP traffic never goes through this socket; it only carries control
/// calls.
///
/// Raw POSIX sockets rather than `Network.framework`: a blocking `connect`/`write`/`read`/`close`
/// sequence this short is trivial to reason about, and it always runs on a dedicated background
/// thread (see `call`), never on a Swift concurrency cooperative thread. What the plain sequence
/// needed to be made safe, and now is:
///
/// - **No SIGPIPE.** Writing to a socket whose peer already closed raises SIGPIPE, whose default
///   action kills the process. `SO_NOSIGPIPE` turns that into an ordinary `EPIPE` error.
/// - **No unbounded waits.** Every call has a deadline (`SO_RCVTIMEO`); a daemon that hangs makes
///   the call fail instead of parking a thread — and the engine awaiting it — forever.
/// - **Cancellation.** If the calling task is cancelled (the user pressed Cancel), the socket is shut
///   down under the blocked `read`, the call throws, and the daemon — seeing the client vanish —
///   abandons an `open` that is still dialing (and closes one that finished too late).
public final class ZarpdClient: WarpConnectionProvider, WarpProbe, @unchecked Sendable {
    /// The IPC protocol version this build speaks (`zarpd/ipc.ProtocolVersion`). A daemon reporting
    /// an older one is a stale leftover from before an app update.
    public static let protocolVersion = 2

    /// Where the installed daemon listens. A *debug* build honors `ZARP_SOCKET`, so development can
    /// point the app at a daemon of its own without touching the installed one; a release build never
    /// reads the environment for this.
    public static var defaultSocketPath: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ZARP_SOCKET"], !override.isEmpty { return override }
        #endif
        return "/var/run/zarpd.sock"
    }

    private let socketPath: String
    private let timeoutScale: Double

    /// Test seam: runs right after `connect` succeeds and before the request is written. Lets a test
    /// make a fake daemon's close *deterministically* precede the write (otherwise it is a race the
    /// client usually wins), which is the only way to exercise the EPIPE/SIGPIPE paths.
    var afterConnectForTesting: (@Sendable () -> Void)?

    /// - Parameter timeoutScale: multiplies every call's deadline (tests use a small value so a
    ///   hung fake daemon is noticed in milliseconds, not seconds).
    public init(socketPath: String = ZarpdClient.defaultSocketPath, timeoutScale: Double = 1) {
        self.socketPath = socketPath
        self.timeoutScale = timeoutScale
    }

    // MARK: - WarpConnectionProvider

    public func open(strategy: Strategy, endpoint: String?, timeoutMs: Int, persistent: Bool, routing: TunnelRouting) async throws -> WarpConnectionHandle {
        // Belt and braces: the engine never asks for these, but an unsupported strategy has an
        // *empty* plan, and an empty plan means "plain direct connection" to the daemon.
        if let reason = strategy.unsupportedReason {
            throw WarpConnectionError("strategy not supported (\(reason.key))", code: "unsupported")
        }
        let plan = strategy.plan
        let params = OpenParams(
            transport: strategy.transport.wireName,
            strategyId: strategy.id,
            fakeSteps: plan.fakeSteps.map(FakeStepWire.init),
            tcpDesync: plan.tcpDesync.map(TCPDesyncWire.init),
            endpoint: endpoint ?? "",
            timeoutMs: timeoutMs,
            persistent: persistent,
            routeAll: persistent && routing.routeAll,
            overrideDNS: persistent && routing.overrideDNS
        )
        // The daemon dials for up to `timeoutMs`, then creates the interface and routes: allow that
        // plus slack before giving up on the answer.
        let result: OpenResult = try await call("open", params, timeout: TimeInterval(timeoutMs) / 1000 + 25)
        return ZarpdConnectionHandle(
            client: self, id: result.connectionId, connectMs: result.connectMs,
            endpoint: result.endpoint, warnings: result.warnings ?? []
        )
    }

    /// See `WarpConnectionProvider.connectionSnapshot()`'s doc comment — reconciles `ZarpEngine`
    /// with what zarpd actually has open: a tunnel the engine didn't itself start (the GUI crashed
    /// or was quit and relaunched, zarpd wasn't touched at all), or the loss of one it believed in.
    public func connectionSnapshot() async throws -> ConnectionSnapshot {
        let status: StatusResult = try await call("status", EmptyParams())
        let loss = status.lastLoss.map { ConnectionLoss(connectionId: $0.connectionId, reason: $0.reason) }
        guard status.connected, let connectionId = status.connectionId else {
            return ConnectionSnapshot(live: nil, lastLoss: loss)
        }
        let handle = ZarpdConnectionHandle(
            client: self, id: connectionId, connectMs: status.connectMs ?? 0, endpoint: status.endpoint, warnings: []
        )
        // A daemon that omits the field predates it, and every persistent connection such a daemon
        // made carried only the test route.
        let live = LiveConnectionStatus(handle: handle, strategyId: status.strategyId, routeAll: status.routeAll ?? false)
        return ConnectionSnapshot(live: live, lastLoss: nil)
    }

    public func isAccountRegistered() async throws -> Bool {
        let ping = try await self.ping()
        return ping.accountRegistered ?? false
    }

    public func registerAccount() async throws {
        // Registration is a round trip to Cloudflare from the daemon (which itself waits up to 60s).
        let _: RegisterResult = try await call("register", EmptyParams(), timeout: 75)
    }

    /// Closing is cleanup, and cleanup must still happen when the task that asked for it has been
    /// cancelled — which is exactly when the engine's cancel path calls it. So it runs detached
    /// from the caller's cancellation. Best-effort: a failed close leaves the daemon's connection
    /// alive until its next `open` (which supersedes it) or, for a test connection, its lease.
    fileprivate func close(connectionID: String) async {
        struct CloseParams: Encodable { let connectionId: String }
        let client = self
        await Task.detached {
            _ = try? await client.call("close", CloseParams(connectionId: connectionID), timeout: 10) as EmptyResult
        }.value
    }

    /// Cheap, side-effect-free liveness/version check — distinct from `ZarpdInstaller.state`, which
    /// only answers "is it installed", not "is it actually up and answering right now". Throws the
    /// same `WarpConnectionError` as any other call — most commonly "connect(...): No such file or
    /// directory" when `zarpd` isn't running at all.
    public func ping() async throws -> PingResult {
        try await call("ping", EmptyParams(), timeout: 5)
    }

    /// Asks zarpd to exit non-zero, which the installed LaunchDaemon's `KeepAlive: {SuccessfulExit:
    /// false}` then relaunches — see zarpd's `Manager.restart` doc comment for why this, not a real
    /// "stop," is what "restart" means for a root daemon an unprivileged app has no `sudo` access
    /// to. The response race is real but harmless: zarpd answers before exiting, but the socket
    /// connection itself may drop mid-read if the process dies unusually fast, so a
    /// `WarpConnectionError` here isn't necessarily a failed restart — callers should re-`ping()`
    /// after a short delay rather than trust this call's success/failure alone.
    public func restart() async throws -> RestartResult {
        try await call("restart", EmptyParams(), timeout: 5)
    }

    /// Daemon log lines newer than `since` (0 = everything buffered).
    public func logs(since: UInt64) async throws -> DaemonLogs {
        struct LogsParams: Encodable { let since: UInt64 }
        return try await call("logs", LogsParams(since: since), timeout: 5)
    }

    // MARK: - WarpProbe

    public func measure(connection: WarpConnectionHandle, samples: Int) async throws -> WarpMeasurement {
        guard let handle = connection as? ZarpdConnectionHandle else {
            throw WarpConnectionError("measure() was given a connection that did not come from zarpd")
        }
        struct MeasureParams: Encodable { let connectionId: String; let samples: Int }
        // One warm-up plus `samples` timed requests, each bounded at 5s by the daemon.
        let timeout = TimeInterval(samples + 1) * 5 + 15
        let result: MeasureResult = try await call("measure", MeasureParams(connectionId: handle.id, samples: samples), timeout: timeout)
        switch result.kind {
        case "ok": return .ok(pingMs: result.pingMs ?? 0, warp: result.warp ?? "on")
        case "notWarp": return .notWarp(result.detail)
        default: return .noTraffic(lastError: result.lastError)
        }
    }

    // MARK: - Wire I/O

    private func call<Params: Encodable, Result: Decodable>(_ method: String, _ params: Params, timeout: TimeInterval = 10) async throws -> Result {
        let id = UInt64.random(in: 1...UInt64.max)
        let requestData = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        let pending = PendingCall()
        let socketPath = self.socketPath
        let timeout = timeout * timeoutScale
        let afterConnect = afterConnectForTesting
        let responseData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try ZarpdClient.sendAndReceive(socketPath: socketPath, requestLine: requestData, timeout: timeout, pending: pending, afterConnect: afterConnect)
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            pending.cancel()
        }
        let response = try JSONDecoder().decode(Response<Result>.self, from: responseData)
        if let error = response.error {
            throw WarpConnectionError(error.message, timedOut: error.timedOut, code: error.code)
        }
        guard let result = response.result else {
            throw WarpConnectionError("zarpd returned neither a result nor an error for \(method)")
        }
        return result
    }

    /// Blocking POSIX socket round-trip: connect, write requestLine + "\n", read until the first
    /// "\n" in the response. Must only ever be called from a background queue (see `call`).
    private static func sendAndReceive(socketPath: String, requestLine: Data, timeout: TimeInterval, pending: PendingCall,
                                       afterConnect: (@Sendable () -> Void)? = nil) throws -> Data {
        let cancelled = WarpConnectionError("cancelled", code: "cancelled")
        if pending.isCancelled { throw cancelled }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WarpConnectionError("socket(): \(String(cString: strerror(errno)))") }
        defer {
            pending.detach()
            Darwin.close(fd)
        }

        // A peer that has gone away must produce EPIPE, never a process-killing SIGPIPE.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        // From here on a cancellation can interrupt the blocking calls by shutting the socket down.
        guard pending.attach(fd) else { throw cancelled }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw WarpConnectionError("socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() { buf[i] = CChar(bitPattern: byte) }
            buf[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addrLen) }
        }
        guard connectResult == 0 else {
            if pending.isCancelled { throw cancelled }
            throw WarpConnectionError("connect(\(socketPath)): \(String(cString: strerror(errno))) — is zarpd running?", code: "daemon_unreachable")
        }

        afterConnect?()

        // The daemon may refuse a client it doesn't trust and close at once, with the reason already
        // on the wire — so a failed write must not stop us from reading what it said.
        var writeError: WarpConnectionError?
        var toSend = requestLine
        toSend.append(UInt8(ascii: "\n"))
        toSend.withUnsafeBytes { rawPtr in
            var offset = 0
            let base = rawPtr.bindMemory(to: UInt8.self)
            while offset < base.count {
                let n = Darwin.write(fd, base.baseAddress!.advanced(by: offset), base.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    writeError = WarpConnectionError("write(): \(String(cString: strerror(errno)))")
                    return
                }
                if n == 0 {
                    writeError = WarpConnectionError("write(): connection closed")
                    return
                }
                offset += n
            }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let maxResponse = 4 * 1024 * 1024
        let newline = UInt8(ascii: "\n")
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                if pending.isCancelled { throw cancelled }
                if err == EAGAIN || err == EWOULDBLOCK {
                    throw WarpConnectionError("zarpd did not answer within \(Int(timeout)) s", timedOut: true, code: "daemon_timeout")
                }
                throw writeError ?? WarpConnectionError("read(): \(String(cString: strerror(err)))")
            }
            if n == 0 {
                if pending.isCancelled { throw cancelled }
                if response.contains(newline) { break }
                throw writeError ?? WarpConnectionError("zarpd closed the connection before responding")
            }
            // Only the bytes just read can contain the newline that ends the answer: looking through
            // everything received so far on every read made a large answer quadratic.
            let sawNewline = buf[0..<n].contains(newline)
            response.append(contentsOf: buf[0..<n])
            if sawNewline { break }
            if response.count > maxResponse { throw WarpConnectionError("zarpd's answer is unreasonably large") }
        }
        return response
    }
}

/// Lets a cancelled Swift task reach the blocking socket call running on another thread: `cancel()`
/// shuts the socket down, which makes its `read` return immediately.
private final class PendingCall: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Registers the socket; `false` if cancellation already happened (the caller must not proceed).
    func attach(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        self.fd = fd
        return true
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        fd = -1
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
}

private final class ZarpdConnectionHandle: WarpConnectionHandle {
    private let client: ZarpdClient
    let id: String
    let connectMs: Int
    let endpoint: String?
    let warnings: [String]

    init(client: ZarpdClient, id: String, connectMs: Int, endpoint: String?, warnings: [String]) {
        self.client = client
        self.id = id
        self.connectMs = connectMs
        self.endpoint = endpoint
        self.warnings = warnings
    }

    func close() async {
        await client.close(connectionID: id)
    }
}

// MARK: - Wire types (mirrors zarpd/ipc/protocol.go field for field)

private struct Request<Params: Encodable>: Encodable {
    let id: UInt64
    let method: String
    let params: Params
}

private struct Response<Result: Decodable>: Decodable {
    let id: UInt64
    let result: Result?
    let error: ErrorInfo?
}

private struct ErrorInfo: Decodable {
    let message: String
    let timedOut: Bool
    let code: String?
}

private struct EmptyResult: Decodable {}
private struct EmptyParams: Encodable {}

/// Mirrors zarpd/ipc/protocol.go's PingResult. Not `private` — `ping()`'s callers need it. The
/// fields added in protocol 2 are optional so a daemon from before the update still decodes (and
/// is then recognised as stale).
public struct PingResult: Decodable, Sendable {
    public let version: String
    public let pid: Int
    public let protocolVersion: Int?
    public let accountRegistered: Bool?

    private enum CodingKeys: String, CodingKey {
        case version, pid, accountRegistered
        case protocolVersion = "protocol"
    }

    /// The protocol the daemon speaks; a daemon that doesn't report one predates versioning.
    public var effectiveProtocol: Int { protocolVersion ?? 1 }
}

/// Mirrors zarpd/ipc/protocol.go's RestartResult. Not `private` for the same reason as `PingResult`.
public struct RestartResult: Decodable, Sendable {
    public let acknowledged: Bool
}

/// One buffered daemon log line.
public struct DaemonLogLine: Decodable, Sendable {
    public let seq: UInt64
    public let timeMs: Int64
    public let text: String
}

/// Mirrors zarpd/ipc/protocol.go's LogsResult.
public struct DaemonLogs: Decodable, Sendable {
    public let lines: [DaemonLogLine]?
    public let next: UInt64
    public let dropped: UInt64?
}

private struct RegisterResult: Decodable {
    let accountRegistered: Bool
}

private struct OpenParams: Encodable {
    let transport: String
    let strategyId: String
    let fakeSteps: [FakeStepWire]
    let tcpDesync: TCPDesyncWire?
    let endpoint: String
    let timeoutMs: Int
    let persistent: Bool
    let routeAll: Bool
    let overrideDNS: Bool
}

private struct FakeStepWire: Encodable {
    let blob: String
    let repeats: Int
    let ipTTL: Int?
    let ip6TTL: Int?

    init(_ step: FakeStep) {
        blob = step.blob.rawValue
        repeats = step.repeats
        ipTTL = step.ipTTL
        ip6TTL = step.ip6TTL
    }
}

private struct TCPDesyncWire: Encodable {
    let mode: String
    let positions: [String]

    init(_ step: TCPDesyncStep) {
        mode = step.mode.rawValue
        positions = step.positions
    }
}

private struct OpenResult: Decodable {
    let connectionId: String
    let connectMs: Int
    let endpoint: String?
    let warnings: [String]?
}

private struct LossInfoWire: Decodable {
    let connectionId: String
    let reason: String
}

/// Mirrors zarpd/ipc/protocol.go's StatusResult.
private struct StatusResult: Decodable {
    let daemonRunning: Bool
    let connected: Bool
    let connectionId: String?
    let strategyId: String?
    let endpoint: String?
    let transport: String?
    let connectMs: Int?
    let connectStartedAt: String?
    let utunName: String?
    let routeAll: Bool?
    let lastLoss: LossInfoWire?
}

private struct MeasureResult: Decodable {
    let kind: String
    let pingMs: Int?
    let warp: String?
    let detail: String?
    let lastError: String?
}

private extension Transport {
    /// Matches zarpd's `ipc.OpenParams.Transport` values exactly.
    var wireName: String {
        switch self {
        case .masqueH3: return "masqueH3"
        case .masqueH2: return "masqueH2"
        case .wireGuard: return "wireGuard"
        }
    }
}
