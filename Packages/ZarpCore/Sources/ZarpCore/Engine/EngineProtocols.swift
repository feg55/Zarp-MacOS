/// This file is the entire seam between the strategy/scan/settings/UI code in this package and
/// live networking. Nothing on this side of the seam knows or assumes how a WARP connection is
/// actually made — see `docs/MACOS_NETWORK_RESEARCH.md` and `docs/ARCHITECTURE.md` for the two
/// candidate designs this must support without changes to `ZarpEngine` or the UI:
///
///   A) drive the official Cloudflare WARP client (warp-cli) and apply a strategy's desync
///      through a packet-filter system extension + a root helper that sends the fake packets —
///      the Windows Zarp model (`Warp.cs` + `Zapret.cs`), UNVERIFIED on macOS.
///   B) open Zarp's own MASQUE tunnel and send the fakes from its own UDP socket right before the
///      real QUIC Initial — the Android Zarp model (`zarpcore`/`dial.go`), used only if (A) turns
///      out not to be feasible.
///
/// Nothing in this file implements NEFilterPacketProvider, raw sockets, BPF, a privileged helper,
/// or a MASQUE client. That is deliberate: `docs/IMPLEMENTATION_PLAN.md` phases 1–2 (a real-Mac
/// proof of concept) must answer the open questions in `docs/MACOS_NETWORK_RESEARCH.md` §6 before
/// any of that is worth writing. The two placeholder types at the bottom of this file exist only
/// so the App target's UI has *something* to build against meanwhile — every method on them fails
/// loudly, on purpose, and nothing here or in the UI is allowed to treat that as success.

/// A live WARP connection produced by `WarpConnectionProvider.open(...)`. Whatever the connection
/// actually is on this platform is entirely the implementation's business — this package only
/// needs to know how long it took to come up and how to close it.
public protocol WarpConnectionHandle: Sendable {
    var connectMs: Int { get }
    /// Endpoint actually used, for logs and diagnostics (Windows `Warp.NextEndpoint`, Android
    /// `TunnelHandle.endpoint`).
    var endpoint: String? { get }
    func close() async
}

/// What a `WarpConnectionProvider` reports back from `currentConnection()` — an already-live
/// persistent connection it owns, discovered rather than just-opened. `strategyId` is whatever the
/// original `open(strategy:...)` caller's `strategy.id` was, so the engine can restore which saved
/// strategy is showing as connected; `nil` if the backend can't identify it (an old connection from
/// before this field existed, say) — the engine still adopts the connection, just without a name.
public struct LiveConnectionStatus: Sendable {
    public let handle: WarpConnectionHandle
    public let strategyId: String?

    public init(handle: WarpConnectionHandle, strategyId: String?) {
        self.handle = handle
        self.strategyId = strategyId
    }
}

/// Opens a WARP connection for one strategy.
///
/// TODO(real-Mac PoC): implement this — see the file-level doc comment above for the two
/// candidate designs. `ZarpEngine` does not need to change for either choice.
public protocol WarpConnectionProvider: Sendable {
    /// - Parameters:
    ///   - strategy: transport + desync plan to apply.
    ///   - endpoint: pin a specific WARP endpoint for an isolated test; `nil` lets the
    ///     implementation choose (Windows `Warp.SetEndpointAsync(null)`).
    ///   - timeoutMs: give up after this long.
    ///   - persistent: `true` for the connection the app keeps using (Windows `Engine.ApplyAsync`),
    ///     `false` for a throwaway scan attempt (Windows `Engine.TestAsync`) that gets closed right
    ///     after probing.
    func open(strategy: Strategy, endpoint: String?, timeoutMs: Int, persistent: Bool) async throws -> WarpConnectionHandle

    /// The backend's own already-live persistent connection, if it has one right now — lets a
    /// freshly-launched `ZarpEngine` (most concretely: the GUI crashed or was quit and relaunched,
    /// not the backend) adopt a real tunnel that outlived it instead of showing "disconnected"
    /// while the tunnel keeps running underneath. `nil` means genuinely idle; connectivity failures
    /// (the backend isn't reachable at all) still throw `WarpConnectionError`, same as `open`.
    func currentConnection() async throws -> LiveConnectionStatus?
}

/// Error from `WarpConnectionProvider.open`. `timedOut` drives the same `err.timeout` vs. generic
/// failure distinction Windows' scan loop makes.
public struct WarpConnectionError: Error, Sendable {
    public let message: String
    public let timedOut: Bool
    public init(_ message: String, timedOut: Bool = false) {
        self.message = message
        self.timedOut = timedOut
    }
}

/// Result of checking whether traffic actually goes through WARP. Every Zarp port uses the same
/// rule: `cdn-cgi/trace` must report `warp=on` or `warp=plus`.
public enum WarpMeasurement: Sendable {
    case ok(pingMs: Int, warp: String)
    case notWarp(String?)
    case noTraffic(lastError: String?)
}

/// Confirms WARP and measures latency through the connection currently open.
///
/// TODO(real-Mac PoC): implement as an HTTPS request to `https://www.cloudflare.com/cdn-cgi/trace`
/// through whatever `WarpConnectionProvider` produced (Windows `Warp.MeasureAsync`, Android
/// `TraceClient`): `samples + 1` requests, the first is a warm-up, the result is the median.
public protocol WarpProbe: Sendable {
    func measure(samples: Int) async throws -> WarpMeasurement
}

/// Detects a foreign VPN/proxy that would carry WARP traffic instead of Zarp's own path, so a scan
/// doesn't silently measure someone else's tunnel (Windows `NetCheck.ForeignVpnAdapters`).
///
/// TODO(real-Mac PoC): implement with `getifaddrs`, matching Windows `NetCheck.IsForeignVpnAdapter`
/// — exclude WARP's own interface and system IPv6 transition adapters (Teredo/6to4/ISATAP),
/// require an actual non-zero gateway, not just an interface that exists.
public protocol NetworkInspector: Sendable {
    func foreignVPNInterfaceNames() -> [String]
}

// MARK: - Honest placeholders — never a real implementation

/// Always fails. Exists only so the App target's UI can be built and click-tested before the real
/// networking layer exists. Every call throws `WarpConnectionError`; nothing here pretends a
/// connection or a scan succeeded.
///
/// TODO(real-Mac PoC): delete every use of this once a real `WarpConnectionProvider` exists.
public struct UnimplementedWarpConnectionProvider: WarpConnectionProvider {
    public init() {}
    public func open(strategy: Strategy, endpoint: String?, timeoutMs: Int, persistent: Bool) async throws -> WarpConnectionHandle {
        throw WarpConnectionError("macOS networking layer is not implemented yet — see docs/IMPLEMENTATION_PLAN.md")
    }
    /// `nil`, not a thrown error: there is truly nothing to adopt from a backend that never opens
    /// anything, which is a different, honest answer from "couldn't check."
    public func currentConnection() async throws -> LiveConnectionStatus? { nil }
}

/// Always fails, for the same reason as `UnimplementedWarpConnectionProvider`.
public struct UnimplementedWarpProbe: WarpProbe {
    public init() {}
    public func measure(samples: Int) async throws -> WarpMeasurement {
        throw WarpConnectionError("macOS networking layer is not implemented yet — see docs/IMPLEMENTATION_PLAN.md")
    }
}

/// Reports "no foreign VPN found" unconditionally. This is a stand-in, not a verified answer —
/// callers must not treat an empty list from this type as a real check having run.
///
/// TODO(real-Mac PoC): replace with a real `getifaddrs`-based implementation.
public struct UnimplementedNetworkInspector: NetworkInspector {
    public init() {}
    public func foreignVPNInterfaceNames() -> [String] { [] }
}
