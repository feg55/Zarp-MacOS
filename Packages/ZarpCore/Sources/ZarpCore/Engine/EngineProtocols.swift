/// This file is the entire seam between the strategy/scan/settings/UI code in this package and
/// live networking. Nothing on this side of the seam knows or assumes how a WARP connection is
/// actually made: in the app, `ZarpdClient` implements these protocols by talking to the `zarpd`
/// daemon (`docs/ARCHITECTURE.md` §1) — which owns the WARP session, the utun and the routes — and
/// the tests substitute scripted fakes. `ZarpEngine` is written only against what is declared here.
///
/// Nothing in this package opens a socket, touches a route or runs a process.

/// A live WARP connection produced by `WarpConnectionProvider.open(...)`. Whatever the connection
/// actually is on this platform is entirely the implementation's business — this package only
/// needs to know how long it took to come up and how to close it.
public protocol WarpConnectionHandle: Sendable {
    /// The backend's identifier for this connection. Lets the engine tell "the connection I'm
    /// holding" apart from "the connection the backend reports right now" (they differ when the
    /// backend replaced it, or restarted).
    var id: String { get }
    var connectMs: Int { get }
    /// Endpoint actually used, for logs and diagnostics (Windows `Warp.NextEndpoint`, Android
    /// `TunnelHandle.endpoint`).
    var endpoint: String? { get }
    /// Non-fatal problems the backend ran into while bringing the connection up (e.g. "DNS was
    /// not overridden"). The engine writes them to the log.
    var warnings: [String] { get }
    func close() async
}

public extension WarpConnectionHandle {
    var warnings: [String] { [] }
}

/// How much of the machine's traffic a *persistent* connection carries.
public struct TunnelRouting: Sendable, Equatable {
    /// Send all traffic through WARP. `false` routes only the measurement target (all a scan
    /// needs, and the mode every test connection uses).
    public var routeAll: Bool
    /// Also resolve names through Cloudflare's resolvers while connected. Requires `routeAll`.
    public var overrideDNS: Bool

    public init(routeAll: Bool, overrideDNS: Bool) {
        self.routeAll = routeAll
        self.overrideDNS = overrideDNS && routeAll
    }

    /// What a throwaway scan attempt uses.
    public static let testRouteOnly = TunnelRouting(routeAll: false, overrideDNS: false)
}

/// What a `WarpConnectionProvider` reports back from `connectionSnapshot()` — an already-live
/// persistent connection it owns, discovered rather than just-opened. `strategyId` is whatever the
/// original `open(strategy:...)` caller's `strategy.id` was, so the engine can restore which saved
/// strategy is showing as connected; `nil` if the backend can't identify it (an old connection from
/// before this field existed, say) — the engine still adopts the connection, just without a name.
public struct LiveConnectionStatus: Sendable {
    public let handle: WarpConnectionHandle
    public let strategyId: String?
    /// Whether the tunnel carries all of the machine's traffic or only the test route.
    public let routeAll: Bool

    public init(handle: WarpConnectionHandle, strategyId: String?, routeAll: Bool = true) {
        self.handle = handle
        self.strategyId = strategyId
        self.routeAll = routeAll
    }
}

/// A persistent connection that ended on its own (as opposed to being closed by the app).
public struct ConnectionLoss: Sendable, Equatable {
    public let connectionId: String
    public let reason: String

    public init(connectionId: String, reason: String) {
        self.connectionId = connectionId
        self.reason = reason
    }
}

/// The backend's current connection state in one answer.
public struct ConnectionSnapshot: Sendable {
    /// The persistent connection that is up right now, if any.
    public let live: LiveConnectionStatus?
    /// The most recent persistent connection that died by itself, if the backend remembers one.
    public let lastLoss: ConnectionLoss?

    public init(live: LiveConnectionStatus?, lastLoss: ConnectionLoss? = nil) {
        self.live = live
        self.lastLoss = lastLoss
    }
}

/// Opens a WARP connection for one strategy.
public protocol WarpConnectionProvider: Sendable {
    /// - Parameters:
    ///   - strategy: transport + desync plan to apply. The engine never asks for a strategy it
    ///     knows to be unsupported (`Strategy.unsupportedReason`), so an implementation may treat
    ///     the plan as complete.
    ///   - endpoint: pin a specific WARP endpoint for an isolated test, or an opaque per-attempt
    ///     token ("isolated-N") the backend maps onto its own endpoint rotation; `nil` lets the
    ///     implementation choose (Windows `Warp.SetEndpointAsync(null)`).
    ///   - timeoutMs: give up after this long.
    ///   - persistent: `true` for the connection the app keeps using (Windows `Engine.ApplyAsync`),
    ///     `false` for a throwaway scan attempt (Windows `Engine.TestAsync`) that gets closed right
    ///     after probing.
    ///   - routing: how much traffic a persistent connection carries; ignored for test attempts.
    ///
    /// Must honor Swift task cancellation: when the surrounding task is cancelled the call should
    /// stop waiting, and a connection that is established anyway must not be left behind.
    func open(strategy: Strategy, endpoint: String?, timeoutMs: Int, persistent: Bool, routing: TunnelRouting) async throws -> WarpConnectionHandle

    /// The backend's own already-live persistent connection, if it has one right now — lets a
    /// freshly-launched `ZarpEngine` (most concretely: the GUI crashed or was quit and relaunched,
    /// not the backend) adopt a real tunnel that outlived it instead of showing "disconnected"
    /// while the tunnel keeps running underneath, and lets a running engine notice that the tunnel
    /// it believes in is gone. A `nil` `live` means genuinely idle; connectivity failures (the
    /// backend isn't reachable at all) still throw `WarpConnectionError`, same as `open`.
    func connectionSnapshot() async throws -> ConnectionSnapshot

    /// Whether the backend already has a WARP account. Cheap and side-effect free.
    func isAccountRegistered() async throws -> Bool

    /// Registers an anonymous WARP account. Only ever called after the user accepted Cloudflare's
    /// terms (the engine's `askAcceptWarpTerms` hook, or a previously saved acceptance).
    func registerAccount() async throws
}

/// Error from `WarpConnectionProvider.open`. `timedOut` drives the same `err.timeout` vs. generic
/// failure distinction Windows' scan loop makes.
public struct WarpConnectionError: Error, Sendable {
    public let message: String
    public let timedOut: Bool
    /// A machine-readable reason from the backend (`"no_account"`, `"foreign_vpn"`,
    /// `"cancelled"`, ...), when it gave one.
    public let code: String?

    public init(_ message: String, timedOut: Bool = false, code: String? = nil) {
        self.message = message
        self.timedOut = timedOut
        self.code = code
    }

    /// The call was abandoned because the caller cancelled it (or went away), not because it failed.
    public var isCancelled: Bool { code == "cancelled" }
}

/// Result of checking whether traffic actually goes through WARP. Every Zarp port uses the same
/// rule: `cdn-cgi/trace` must report `warp=on` or `warp=plus`.
public enum WarpMeasurement: Sendable {
    case ok(pingMs: Int, warp: String)
    /// Reached the server, but the request did not come through WARP. The payload is the raw
    /// `warp=` value that was seen (`"off"`), without the label.
    case notWarp(String?)
    case noTraffic(lastError: String?)
}

/// Confirms WARP and measures latency through a given open connection: `samples + 1` requests to
/// `cdn-cgi/trace`, the first a warm-up, the result the median (Windows `Warp.MeasureAsync`, Android
/// `TraceClient`).
public protocol WarpProbe: Sendable {
    /// `connection` is the handle `open` returned — measuring a *specific* connection (rather than
    /// "whatever was opened last") keeps this correct if the backend ever holds more than one.
    func measure(connection: WarpConnectionHandle, samples: Int) async throws -> WarpMeasurement
}

/// Detects a foreign VPN/proxy that would carry WARP traffic instead of Zarp's own path, so a scan
/// doesn't silently measure someone else's tunnel (Windows `NetCheck.ForeignVpnAdapters`). The
/// app's implementation lives in the App target (it needs `getifaddrs`); the engine only asks.
public protocol NetworkInspector: Sendable {
    func foreignVPNInterfaceNames() -> [String]
}

// MARK: - Honest placeholders — never a real implementation

/// Always fails. For previews and tests of code that must not reach a backend; nothing here
/// pretends a connection or a scan succeeded.
public struct UnimplementedWarpConnectionProvider: WarpConnectionProvider {
    public init() {}
    public func open(strategy: Strategy, endpoint: String?, timeoutMs: Int, persistent: Bool, routing: TunnelRouting) async throws -> WarpConnectionHandle {
        throw WarpConnectionError("no WARP backend is configured")
    }
    /// An idle snapshot, not a thrown error: there is truly nothing to adopt from a backend that
    /// never opens anything, which is a different, honest answer from "couldn't check."
    public func connectionSnapshot() async throws -> ConnectionSnapshot { ConnectionSnapshot(live: nil) }
    public func isAccountRegistered() async throws -> Bool { false }
    public func registerAccount() async throws {
        throw WarpConnectionError("no WARP backend is configured")
    }
}

/// Always fails, for the same reason as `UnimplementedWarpConnectionProvider`.
public struct UnimplementedWarpProbe: WarpProbe {
    public init() {}
    public func measure(connection: WarpConnectionHandle, samples: Int) async throws -> WarpMeasurement {
        throw WarpConnectionError("no WARP backend is configured")
    }
}

/// Reports "no foreign VPN found" unconditionally. A stand-in for tests and previews, not a
/// verified answer — callers must not treat an empty list from this type as a real check having
/// run (the app uses `SystemNetworkInspector`).
public struct UnimplementedNetworkInspector: NetworkInspector {
    public init() {}
    public func foreignVPNInterfaceNames() -> [String] { [] }
}
