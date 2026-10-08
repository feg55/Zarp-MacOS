import Darwin
import XCTest
import ZarpCore
@testable import ZarpdIPC

/// The client is the only thing standing between the engine and the daemon, and it used to have no
/// tests at all. These run the real `ZarpdClient` over real Unix sockets against `FakeDaemon`, whose
/// canned answers are byte-for-byte what `zarpd/ipc` produces (`json.Marshal` of the Go structs in
/// `protocol.go`) — so a field renamed on either side breaks a test here instead of the running app.
final class ZarpdClientTests: XCTestCase {
    private var daemons: [FakeDaemon] = []

    override func tearDown() {
        daemons.forEach { $0.stop() }
        daemons = []
        super.tearDown()
    }

    private func makeDaemon(_ behavior: @escaping @Sendable (FakeDaemon.Request) -> FakeDaemon.Behavior) throws -> FakeDaemon {
        let d = try FakeDaemon(behavior: behavior)
        daemons.append(d)
        return d
    }

    private func client(_ d: FakeDaemon, scale: Double = 1) -> ZarpdClient {
        ZarpdClient(socketPath: d.path, timeoutScale: scale)
    }

    private func strategy(_ id: String) -> Strategy {
        StrategyCatalog.builtIn.first { $0.id == id }!
    }

    // MARK: - Decoding what zarpd really sends

    func testPingDecodesTheDaemonsAnswer() async throws {
        let d = try makeDaemon { _ in .reply(result: Golden.ping) }
        let ping = try await client(d).ping()
        XCTAssertEqual(ping.version, "0.1.0")
        XCTAssertEqual(ping.pid, 4242)
        XCTAssertEqual(ping.effectiveProtocol, 2)
        XCTAssertEqual(ping.accountRegistered, true)
        XCTAssertEqual(d.requests.first?.method, "ping")
    }

    func testADaemonFromBeforeVersioningIsRecognisedAsProtocolOne() async throws {
        let d = try makeDaemon { _ in .reply(result: #"{"version":"0.1.0","pid":7}"#) }
        let ping = try await client(d).ping()
        XCTAssertNil(ping.protocolVersion)
        XCTAssertEqual(ping.effectiveProtocol, 1)
        let registered = try await client(d).isAccountRegistered()
        XCTAssertFalse(registered, "an old daemon doesn't say, so the app must not assume an account exists")
    }

    func testAccountRegisteredComesFromPing() async throws {
        for (json, expected) in [(#"{"version":"x","pid":1,"protocol":2,"accountRegistered":true}"#, true),
                                 (#"{"version":"x","pid":1,"protocol":2,"accountRegistered":false}"#, false)] {
            let d = try makeDaemon { _ in .reply(result: json) }
            let registered = try await client(d).isAccountRegistered()
            XCTAssertEqual(registered, expected)
        }
    }

    func testIdleStatusIsAnEmptySnapshot() async throws {
        let d = try makeDaemon { _ in .reply(result: Golden.statusIdle) }
        let snapshot = try await client(d).connectionSnapshot()
        XCTAssertNil(snapshot.live)
        XCTAssertNil(snapshot.lastLoss)
    }

    func testConnectedStatusBecomesALiveConnection() async throws {
        let d = try makeDaemon { _ in .reply(result: Golden.statusFullTunnel) }
        let live = try await client(d).connectionSnapshot().live
        XCTAssertEqual(live?.handle.id, "7")
        XCTAssertEqual(live?.handle.connectMs, 203)
        XCTAssertEqual(live?.handle.endpoint, "162.159.198.2:500")
        XCTAssertEqual(live?.strategyId, "warp-q-google6")
        XCTAssertEqual(live?.routeAll, true)
    }

    func testATestRouteOnlyTunnelIsNotMistakenForAFullTunnel() async throws {
        // Go sends "routeAll":false explicitly (it used to be omitempty, which made "test route
        // only" look like "field absent" and the app showed a plain Connected for a tunnel that
        // carries nothing but 1.1.1.1).
        let d = try makeDaemon { _ in .reply(result: Golden.statusTestRouteOnly) }
        let live = try await client(d).connectionSnapshot().live
        XCTAssertEqual(live?.handle.id, "2")
        XCTAssertEqual(live?.routeAll, false)
    }

    func testAnOldDaemonThatNeverSentRouteAllMeansTheTestRoute() async throws {
        let json = #"{"daemonRunning":true,"connected":true,"connectionId":"2","strategyId":"direct","connectMs":50}"#
        let d = try makeDaemon { _ in .reply(result: json) }
        let live = try await client(d).connectionSnapshot().live
        XCTAssertEqual(live?.routeAll, false, "every persistent connection of a daemon from before the field carried only the test route")
    }

    func testALostTunnelIsReportedWithItsReason() async throws {
        let d = try makeDaemon { _ in .reply(result: Golden.statusAfterLoss) }
        let snapshot = try await client(d).connectionSnapshot()
        XCTAssertNil(snapshot.live)
        XCTAssertEqual(snapshot.lastLoss, ConnectionLoss(connectionId: "3", reason: "no recent network activity"))
    }

    func testLogsDecodeIncludingAnEmptyRing() async throws {
        let d = try makeDaemon { _ in .reply(result: Golden.logs) }
        let logs = try await client(d).logs(since: 4)
        XCTAssertEqual(logs.lines?.map(\.text), ["closed #1"])
        XCTAssertEqual(logs.lines?.first?.timeMs, 1791284063527)
        XCTAssertEqual(logs.next, 5)
        XCTAssertEqual(logs.dropped, 2)
        XCTAssertEqual(d.requests.first?.params["since"] as? Int, 4)

        // Go encodes a nil slice as null, and omits `dropped` when zero.
        let empty = try makeDaemon { _ in .reply(result: Golden.logsEmpty) }
        let none = try await client(empty).logs(since: 0)
        XCTAssertNil(none.lines)
        XCTAssertEqual(none.next, 0)
    }

    func testRestartAndRegister() async throws {
        let d = try makeDaemon { req in
            req.method == "restart" ? .reply(result: #"{"acknowledged":true}"#) : .reply(result: #"{"accountRegistered":true}"#)
        }
        let restart = try await client(d).restart()
        XCTAssertTrue(restart.acknowledged)
        try await client(d).registerAccount()
        XCTAssertEqual(d.requests.map(\.method), ["restart", "register"])
    }

    // MARK: - What open sends

    func testOpenSendsTheStrategyAsTheDaemonExpectsIt() async throws {
        let d = try makeDaemon { _ in .reply(result: Golden.openTestConnection) }
        let handle = try await client(d).open(
            strategy: strategy("warp-q-google-ttl"), endpoint: "isolated-3", timeoutMs: 15000, persistent: false, routing: .testRouteOnly)
        XCTAssertEqual(handle.id, "1")
        XCTAssertEqual(handle.connectMs, 10)

        let p = try XCTUnwrap(d.requests.first?.params)
        XCTAssertEqual(d.requests.first?.method, "open")
        XCTAssertEqual(p["transport"] as? String, "masqueH3")
        XCTAssertEqual(p["strategyId"] as? String, "warp-q-google-ttl")
        XCTAssertEqual(p["endpoint"] as? String, "isolated-3")
        XCTAssertEqual(p["timeoutMs"] as? Int, 15000)
        XCTAssertEqual(p["persistent"] as? Bool, false)
        let steps = try XCTUnwrap(p["fakeSteps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0]["blob"] as? String, "quic_google")
        XCTAssertEqual(steps[0]["repeats"] as? Int, 6)
        XCTAssertEqual(steps[0]["ipTTL"] as? Int, 4)
        XCTAssertEqual(steps[0]["ip6TTL"] as? Int, 4)
    }

    func testOpenSendsATCPSplitForHTTP2() async throws {
        let d = try makeDaemon { _ in .reply(result: #"{"connectionId":"1","connectMs":10}"#) }
        _ = try await client(d).open(strategy: strategy("warp-t-disorder"), endpoint: nil, timeoutMs: 1000, persistent: false, routing: .testRouteOnly)
        let p = try XCTUnwrap(d.requests.first?.params)
        XCTAssertEqual(p["transport"] as? String, "masqueH2")
        let split = try XCTUnwrap(p["tcpDesync"] as? [String: Any])
        XCTAssertEqual(split["mode"] as? String, "disorder")
        XCTAssertEqual(split["positions"] as? [String], ["1", "midsld"])
        XCTAssertEqual(p["endpoint"] as? String, "", "no endpoint means the account's own")
    }

    func testOpenMapsPersistenceAndRoutingAndTheirGuards() async throws {
        let d = try makeDaemon { _ in .reply(result: #"{"connectionId":"1","connectMs":10,"routeAll":true}"#) }
        let c = client(d)
        let full = TunnelRouting(routeAll: true, overrideDNS: true)
        _ = try await c.open(strategy: strategy("direct"), endpoint: nil, timeoutMs: 1000, persistent: true, routing: full)
        _ = try await c.open(strategy: strategy("direct"), endpoint: nil, timeoutMs: 1000, persistent: false, routing: full)
        let persistent = d.requests[0].params, test = d.requests[1].params
        XCTAssertEqual(persistent["routeAll"] as? Bool, true)
        XCTAssertEqual(persistent["overrideDNS"] as? Bool, true)
        // A scan's test connection must never ask for the whole machine's traffic.
        XCTAssertEqual(test["routeAll"] as? Bool, false)
        XCTAssertEqual(test["overrideDNS"] as? Bool, false)
    }

    func testWarningsFromTheDaemonReachTheHandle() async throws {
        let d = try makeDaemon { _ in .reply(result: Golden.openFullTunnel) }
        let handle = try await client(d).open(strategy: strategy("direct"), endpoint: nil, timeoutMs: 1000, persistent: true, routing: .testRouteOnly)
        XCTAssertEqual(handle.warnings, ["DNS was not overridden: boom"])
        XCTAssertEqual(handle.endpoint, "162.159.198.1:443")
        XCTAssertEqual(handle.id, "9")
    }

    func testAnUnsupportedStrategyIsNeverSentBecauseItWouldRunAsADirectConnection() async throws {
        let d = try makeDaemon { _ in .reply(result: #"{"connectionId":"1","connectMs":10}"#) }
        for id in ["warp-t-seqovl", "warp-q-google-bad", "warp-wg-stun"] {
            do {
                _ = try await client(d).open(strategy: strategy(id), endpoint: nil, timeoutMs: 1000, persistent: false, routing: .testRouteOnly)
                XCTFail("\(id) must be refused")
            } catch let error as WarpConnectionError {
                XCTAssertEqual(error.code, "unsupported")
            }
        }
        XCTAssertEqual(d.connectionCount, 0, "not even a connection may be made for it")
    }

    // MARK: - Errors

    func testErrorsKeepMessageTimeoutFlagAndCode() async throws {
        let d = try makeDaemon { _ in .error(message: "no WARP account yet", timedOut: false, code: "no_account") }
        do {
            _ = try await client(d).open(strategy: strategy("direct"), endpoint: nil, timeoutMs: 1000, persistent: false, routing: .testRouteOnly)
            XCTFail("expected an error")
        } catch let error as WarpConnectionError {
            XCTAssertEqual(error.message, "no WARP account yet")
            XCTAssertEqual(error.code, "no_account")
            XCTAssertFalse(error.timedOut)
        }
        d.setBehavior { _ in .error(message: "timeout after 15s", timedOut: true) }
        do {
            _ = try await client(d).open(strategy: strategy("direct"), endpoint: nil, timeoutMs: 1000, persistent: false, routing: .testRouteOnly)
            XCTFail("expected an error")
        } catch let error as WarpConnectionError {
            XCTAssertTrue(error.timedOut)
            XCTAssertNil(error.code)
        }
    }

    func testADaemonThatIsNotRunning() async {
        let c = ZarpdClient(socketPath: "/tmp/zfd-does-not-exist.sock")
        do {
            _ = try await c.ping()
            XCTFail("expected an error")
        } catch let error as WarpConnectionError {
            XCTAssertEqual(error.code, "daemon_unreachable")
            XCTAssertTrue(error.message.contains("zarpd"), error.message)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAnOverlongSocketPathIsAnErrorNotACrash() async {
        let c = ZarpdClient(socketPath: "/tmp/" + String(repeating: "a", count: 200))
        do {
            _ = try await c.ping()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("too long"))
        }
    }

    func testAnAnswerThatNeverComesIsATimeoutNotAHang() async throws {
        let d = try makeDaemon { _ in .hang }
        let start = Date()
        do {
            _ = try await client(d, scale: 0.04).ping() // 5 s * 0.04 = 200 ms
            XCTFail("expected a timeout")
        } catch let error as WarpConnectionError {
            XCTAssertTrue(error.timedOut)
            XCTAssertEqual(error.code, "daemon_timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testMalformedAnswersAreErrors() async throws {
        let d = try makeDaemon { _ in .raw("this is not json\n") }
        do {
            _ = try await client(d).ping()
            XCTFail("expected an error")
        } catch {}
        let empty = try makeDaemon { req in .raw("{\"id\":\(req.id)}\n") }
        do {
            _ = try await client(empty).ping()
            XCTFail("an answer with neither result nor error must be an error")
        } catch let error as WarpConnectionError {
            XCTAssertTrue(error.message.contains("neither"))
        }
    }

    func testAHugeAnswerIsRefusedInsteadOfBufferedForever() async throws {
        let d = try makeDaemon { _ in .flood(bytes: 6 * 1024 * 1024) }
        do {
            _ = try await client(d).ping()
            XCTFail("expected an error")
        } catch let error as WarpConnectionError {
            XCTAssertTrue(error.message.contains("large"), error.message)
        }
    }

    // MARK: - Failure modes that used to kill the app or hang it

    func testAPeerThatHasGoneAwayDoesNotKillTheProcessWithSIGPIPE() async throws {
        // Without SO_NOSIGPIPE, writing to a socket whose peer has closed raises SIGPIPE and the whole
        // process (the app, in production) is terminated. Test runners commonly ignore SIGPIPE
        // themselves, which would hide the bug: put the default disposition back for the test.
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        let d = try makeDaemon { _ in .closeImmediately }
        let c = client(d)
        // Give the fake daemon time to close its end *before* the client writes — otherwise the
        // client wins the race and never touches a closed socket.
        c.afterConnectForTesting = { Thread.sleep(forTimeInterval: 0.15) }
        for _ in 0..<3 {
            do {
                _ = try await c.ping()
                XCTFail("expected an error")
            } catch let error as WarpConnectionError {
                XCTAssertTrue(error.message.contains("write()") || error.message.contains("closed"), error.message)
            }
        }
    }

    func testARefusalIsReadEvenThoughTheDaemonClosedBeforeReadingTheRequest() async throws {
        let d = try makeDaemon { _ in .refuse(code: "forbidden", message: "this process is not allowed to control zarpd") }
        let c = client(d)
        // The daemon has already written its refusal and closed by the time the client writes: the
        // write fails with EPIPE, but the reason is waiting to be read.
        c.afterConnectForTesting = { Thread.sleep(forTimeInterval: 0.15) }
        do {
            _ = try await c.ping()
            XCTFail("expected an error")
        } catch let error as WarpConnectionError {
            XCTAssertEqual(error.code, "forbidden", "the reason must reach the user, not 'broken pipe': \(error.message)")
        }
    }

    func testCancellingACallAbandonsItImmediatelyAndTheDaemonSeesTheClientLeave() async throws {
        let d = try makeDaemon { _ in .hang }
        let c = client(d)
        let task = Task { () -> String in
            do {
                _ = try await c.ping()
                return "answered"
            } catch let error as WarpConnectionError {
                return error.code ?? error.message
            } catch {
                return "\(error)"
            }
        }
        XCTAssertTrue(eventually { d.requests.count == 1 }, "the request should have reached the daemon")
        let cancelledAt = Date()
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2, "a cancelled call used to sit in read() until its full timeout")
        // The daemon notices the vanished client — that is what makes it abandon an open that is
        // still dialing.
        XCTAssertTrue(eventually { d.disconnectCount == 1 })
    }

    func testACallMadeFromAnAlreadyCancelledTaskNeverReachesTheDaemon() async throws {
        let d = try makeDaemon { _ in .reply(result: "{}") }
        let c = client(d)
        let task = Task { () -> Bool in
            // Wait until cancelled, then call.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            do { _ = try await c.ping(); return true } catch { return false }
        }
        task.cancel()
        let answered = await task.value
        XCTAssertFalse(answered)
        XCTAssertEqual(d.requests.count, 0)
    }

    func testClosingStillHappensWhenTheTaskThatClosesIsCancelled() async throws {
        // The engine's cancel path calls handle.close() from a task that has just been cancelled.
        // If the cancellation aborted *that* call too, every cancelled scan would leave its tunnel
        // open in the daemon.
        let d = try makeDaemon { req in
            req.method == "status"
                ? .reply(result: #"{"daemonRunning":true,"connected":true,"connectionId":"11","strategyId":"direct","connectMs":5,"routeAll":true}"#)
                : .reply(result: "{}")
        }
        let live = try await client(d).connectionSnapshot().live
        let handle = try XCTUnwrap(live?.handle)

        let task = Task {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            await handle.close() // runs with its own task already cancelled
        }
        task.cancel()
        await task.value

        let close = d.requests.first { $0.method == "close" }
        XCTAssertNotNil(close, "close must not be cancelled along with its caller")
        XCTAssertEqual(close?.params["connectionId"] as? String, "11")
    }

    func testClosingAGoneDaemonIsHarmless() async throws {
        let d = try makeDaemon { _ in .reply(result: #"{"daemonRunning":true,"connected":true,"connectionId":"1","strategyId":"direct","connectMs":5}"#) }
        let snapshot = try await client(d).connectionSnapshot()
        let handle = try XCTUnwrap(snapshot.live?.handle)
        d.stop()
        await handle.close() // must return, not throw or hang
    }

    func testManyConcurrentCallsAllSucceed() async throws {
        let d = try makeDaemon { _ in .reply(result: #"{"version":"x","pid":1,"protocol":2,"accountRegistered":true}"#) }
        let c = client(d)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<40 { group.addTask { try await c.ping().pid } }
            var n = 0
            for try await _ in group { n += 1 }
            XCTAssertEqual(n, 40)
        }
        XCTAssertEqual(d.requests.count, 40)
    }

    // MARK: - measure

    func testMeasureSendsTheConnectionAndMapsEveryResultKind() async throws {
        let d = try makeDaemon { req in
            switch req.method {
            case "status": return .reply(result: #"{"daemonRunning":true,"connected":true,"connectionId":"21","strategyId":"direct","connectMs":5}"#)
            default: return .reply(result: #"{"kind":"ok","pingMs":31,"warp":"on"}"#)
            }
        }
        let c = client(d)
        let snapshot = try await c.connectionSnapshot()
        let handle = try XCTUnwrap(snapshot.live?.handle)

        guard case .ok(let ping, let warp) = try await c.measure(connection: handle, samples: 3) else { return XCTFail("expected .ok") }
        XCTAssertEqual(ping, 31)
        XCTAssertEqual(warp, "on")
        let measure = try XCTUnwrap(d.requests.last)
        XCTAssertEqual(measure.method, "measure")
        XCTAssertEqual(measure.params["connectionId"] as? String, "21")
        XCTAssertEqual(measure.params["samples"] as? Int, 3)

        d.setBehavior { _ in .reply(result: #"{"kind":"notWarp","detail":"off"}"#) }
        guard case .notWarp(let detail) = try await c.measure(connection: handle, samples: 1) else { return XCTFail("expected .notWarp") }
        XCTAssertEqual(detail, "off", "the raw value, without a label")

        d.setBehavior { _ in .reply(result: #"{"kind":"noTraffic","lastError":"i/o timeout"}"#) }
        guard case .noTraffic(let err) = try await c.measure(connection: handle, samples: 1) else { return XCTFail("expected .noTraffic") }
        XCTAssertEqual(err, "i/o timeout")
    }

    func testMeasureRefusesAHandleThatIsNotFromTheDaemon() async throws {
        struct Foreign: WarpConnectionHandle {
            let id = "x"; let connectMs = 0; let endpoint: String? = nil
            func close() async {}
        }
        let d = try makeDaemon { _ in .reply(result: "{}") }
        do {
            _ = try await client(d).measure(connection: Foreign(), samples: 1)
            XCTFail("expected an error")
        } catch is WarpConnectionError {}
        XCTAssertEqual(d.connectionCount, 0)
    }

    // MARK: - Environment override

    func testTheDefaultSocketPathIsTheInstalledDaemons() {
        // (A debug build honors ZARP_SOCKET; this process doesn't set it.)
        XCTAssertEqual(ProcessInfo.processInfo.environment["ZARP_SOCKET"] ?? "", "")
        XCTAssertEqual(ZarpdClient.defaultSocketPath, "/var/run/zarpd.sock")
    }
}


/// The exact answers zarpd sends — copied from `TestWireFormat` in zarpd/ipc/protocol_test.go, which
/// pins the Go side to these very strings. Keep the two in step.
enum Golden {
    static let ping = #"{"version":"0.1.0","pid":4242,"protocol":2,"accountRegistered":true}"#
    static let statusIdle = #"{"daemonRunning":true,"accountRegistered":true,"connected":false,"routeAll":false}"#
    static let statusFullTunnel = #"{"daemonRunning":true,"accountRegistered":true,"connected":true,"connectionId":"7","strategyId":"warp-q-google6","endpoint":"162.159.198.2:500","transport":"masqueH3","connectMs":203,"connectStartedAt":"2026-10-06T10:00:00Z","utunName":"utun8","routeAll":true}"#
    static let statusTestRouteOnly = #"{"daemonRunning":true,"accountRegistered":false,"connected":true,"connectionId":"2","routeAll":false}"#
    static let statusAfterLoss = #"{"daemonRunning":true,"accountRegistered":true,"connected":false,"routeAll":false,"lastLoss":{"connectionId":"3","reason":"no recent network activity","at":"2026-10-06T10:01:00Z"}}"#
    static let openFullTunnel = #"{"connectionId":"9","connectMs":120,"endpoint":"162.159.198.1:443","utunName":"utun8","routeAll":true,"warnings":["DNS was not overridden: boom"]}"#
    static let openTestConnection = #"{"connectionId":"1","connectMs":10,"routeAll":false}"#
    static let logs = #"{"lines":[{"seq":5,"timeMs":1791284063527,"text":"closed #1"}],"next":5,"dropped":2}"#
    static let logsEmpty = #"{"lines":null,"next":0}"#
}
