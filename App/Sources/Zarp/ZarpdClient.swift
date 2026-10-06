import Darwin
import Foundation
import ZarpCore

/// `WarpConnectionProvider` + `WarpProbe` implementation talking to `zarpd` over the Unix domain
/// socket IPC described in `docs/ARCHITECTURE.md` §9.4 / `zarpd/ipc/protocol.go`: newline-delimited
/// JSON, one request per line, one response per line. Each call opens its own short-lived
/// connection (connect, send one line, read one line, close) rather than multiplexing several
/// requests over one persistent connection — simpler, and call frequency here (scan/connect
/// actions, not a data path) makes the per-call connection overhead irrelevant. The actual WARP
/// traffic never goes through this socket; it only carries control calls.
///
/// Raw POSIX sockets rather than `Network.framework`: `NWConnection`'s callback-based API adds a
/// layer of state-machine bridging for little benefit over a `connect`/`write`/`read`/`close`
/// sequence this short, and blocking POSIX calls are trivial to reason about — they're always run
/// on a dedicated background thread (see `call`), never on a Swift concurrency cooperative thread.
final class ZarpdClient: WarpConnectionProvider, WarpProbe, @unchecked Sendable {
    private let socketPath: String

    init(socketPath: String = "/var/run/zarpd.sock") {
        self.socketPath = socketPath
    }

    // MARK: - WarpConnectionProvider

    func open(strategy: Strategy, endpoint: String?, timeoutMs: Int, persistent: Bool) async throws -> WarpConnectionHandle {
        let plan = strategy.plan
        let params = OpenParams(
            transport: strategy.transport.wireName,
            strategyId: strategy.id,
            fakeSteps: plan.fakeSteps.map(FakeStepWire.init),
            tcpDesync: plan.tcpDesync.map(TCPDesyncWire.init),
            endpoint: endpoint ?? "",
            timeoutMs: timeoutMs,
            persistent: persistent
        )
        let result: OpenResult = try await call("open", params)
        return ZarpdConnectionHandle(client: self, connectionID: result.connectionId, connectMs: result.connectMs, endpoint: result.endpoint)
    }

    /// See `WarpConnectionProvider.currentConnection()`'s doc comment — reconciles `ZarpEngine`
    /// with a tunnel zarpd already has open that this particular `ZarpdClient`/engine instance
    /// didn't itself start (most concretely: the GUI crashed or was quit and relaunched, zarpd
    /// wasn't touched at all).
    func currentConnection() async throws -> LiveConnectionStatus? {
        let result: StatusResult = try await call("status", EmptyParams())
        guard result.connected, let connectionId = result.connectionId else { return nil }
        let handle = ZarpdConnectionHandle(
            client: self, connectionID: connectionId, connectMs: result.connectMs ?? 0, endpoint: result.endpoint
        )
        return LiveConnectionStatus(handle: handle, strategyId: result.strategyId)
    }

    fileprivate func close(connectionID: String) async {
        struct CloseParams: Encodable { let connectionId: String }
        // Best-effort: a failed close notification leaves zarpd's own connection alive, which is
        // a resource leak worth logging once this has a real log sink wired in, but not something
        // the caller (already tearing down) can usefully retry.
        _ = try? await call("close", CloseParams(connectionId: connectionID)) as EmptyResult
    }

    /// Cheap, side-effect-free liveness/version check (Phase 8: "app detects daemon availability/
    /// version" — distinct from `ZarpdInstaller.state`, which only answers "is it installed,"
    /// not "is it actually up and answering right now"). Throws the same `WarpConnectionError`
    /// as any other call — most commonly "connect(...): No such file or directory" when `zarpd`
    /// isn't running at all.
    func ping() async throws -> PingResult {
        try await call("ping", EmptyParams())
    }

    /// Asks zarpd to exit non-zero, which the installed LaunchDaemon's `KeepAlive: {SuccessfulExit:
    /// false}` then relaunches — see zarpd/cmd/zarpd/main.go's handleRestart doc comment for why
    /// this, not a real "stop," is what "restart" means for a root daemon an unprivileged app has
    /// no `sudo` access to. The response race is real but harmless: zarpd answers before exiting,
    /// but the socket connection itself may drop mid-read if the process dies unusually fast, so a
    /// `WarpConnectionError` here isn't necessarily a failed restart — callers should re-`ping()`
    /// after a short delay rather than trust this call's success/failure alone.
    func restart() async throws -> RestartResult {
        try await call("restart", EmptyParams())
    }

    // MARK: - WarpProbe

    /// TODO(real Mac): `WarpProbe.measure` has no connection to scope the measurement to — this
    /// protocol was written before zarpd's per-open-call connection ids existed. For now this
    /// measures the most recently opened connection (zarpd's default is exactly one live
    /// connection at a time, matching `ZarpEngine`'s "one operation at a time" invariant — see
    /// `zarpd/cmd/zarpd/main.go`'s file doc comment); revisit if that invariant ever changes.
    func measure(samples: Int) async throws -> WarpMeasurement {
        guard let connectionID = ZarpdClient.lastOpenedConnectionID else {
            throw WarpConnectionError("measure() called with no open connection")
        }
        struct MeasureParams: Encodable { let connectionId: String; let samples: Int }
        let result: MeasureResult = try await call("measure", MeasureParams(connectionId: connectionID, samples: samples))
        switch result.kind {
        case "ok": return .ok(pingMs: result.pingMs ?? 0, warp: result.warp ?? "on")
        case "notWarp": return .notWarp(result.detail)
        default: return .noTraffic(lastError: result.lastError)
        }
    }

    fileprivate static var lastOpenedConnectionID: String?

    // MARK: - Wire I/O

    private func call<Params: Encodable, Result: Decodable>(_ method: String, _ params: Params) async throws -> Result {
        let id = UInt64.random(in: 1...UInt64.max)
        let request = Request(id: id, method: method, params: params)
        let requestData = try JSONEncoder().encode(request)
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try ZarpdClient.sendAndReceive(socketPath: self.socketPath, requestLine: requestData)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let response = try JSONDecoder().decode(Response<Result>.self, from: responseData)
        if let error = response.error {
            throw WarpConnectionError(error.message, timedOut: error.timedOut)
        }
        guard let result = response.result else {
            throw WarpConnectionError("zarpd returned neither a result nor an error for \(method)")
        }
        return result
    }

    /// Blocking POSIX socket round-trip: connect, write requestLine + "\n", read until the first
    /// "\n" in the response. Must only ever be called from a background queue (see `call`).
    private static func sendAndReceive(socketPath: String, requestLine: Data) throws -> Data {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WarpConnectionError("socket(): \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }

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
            throw WarpConnectionError("connect(\(socketPath)): \(String(cString: strerror(errno))) — is zarpd running?")
        }

        var toSend = requestLine
        toSend.append(UInt8(ascii: "\n"))
        try toSend.withUnsafeBytes { rawPtr in
            var offset = 0
            let base = rawPtr.bindMemory(to: UInt8.self)
            while offset < base.count {
                let n = Darwin.write(fd, base.baseAddress!.advanced(by: offset), base.count - offset)
                if n < 0 { throw WarpConnectionError("write(): \(String(cString: strerror(errno)))") }
                if n == 0 { throw WarpConnectionError("write(): connection closed") }
                offset += n
            }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { throw WarpConnectionError("read(): \(String(cString: strerror(errno)))") }
            if n == 0 { throw WarpConnectionError("read(): zarpd closed the connection before responding") }
            response.append(contentsOf: buf[0..<n])
            if response.contains(UInt8(ascii: "\n")) { break }
        }
        return response
    }
}

private final class ZarpdConnectionHandle: WarpConnectionHandle {
    private let client: ZarpdClient
    let connectionID: String
    let connectMs: Int
    let endpoint: String?

    init(client: ZarpdClient, connectionID: String, connectMs: Int, endpoint: String?) {
        self.client = client
        self.connectionID = connectionID
        self.connectMs = connectMs
        self.endpoint = endpoint
        ZarpdClient.lastOpenedConnectionID = connectionID
    }

    func close() async {
        await client.close(connectionID: connectionID)
        if ZarpdClient.lastOpenedConnectionID == connectionID {
            ZarpdClient.lastOpenedConnectionID = nil
        }
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
}

private struct EmptyResult: Decodable {}
private struct EmptyParams: Encodable {}

/// Mirrors zarpd/ipc/protocol.go's PingResult. Not `private` — `ping()`'s callers (Settings UI)
/// need it.
struct PingResult: Decodable {
    let version: String
    let pid: Int
}

/// Mirrors zarpd/ipc/protocol.go's RestartResult. Not `private` for the same reason as `PingResult`.
struct RestartResult: Decodable {
    let acknowledged: Bool
}

private struct OpenParams: Encodable {
    let transport: String
    let strategyId: String
    let fakeSteps: [FakeStepWire]
    let tcpDesync: TCPDesyncWire?
    let endpoint: String
    let timeoutMs: Int
    let persistent: Bool
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
}

private struct MeasureResult: Decodable {
    let kind: String
    let pingMs: Int?
    let warp: String?
    let detail: String?
    let lastError: String?
}

private extension Transport {
    /// Matches zarpd/cmd/zarpd/main.go's `switch p.Transport` cases exactly.
    var wireName: String {
        switch self {
        case .masqueH3: return "masqueH3"
        case .masqueH2: return "masqueH2"
        case .wireGuard: return "wireGuard"
        }
    }
}
