/// Whether a strategy's handshake-desync technique has been confirmed to work through whichever
/// macOS interception layer this build uses (see `docs/MACOS_NETWORK_RESEARCH.md` and
/// `Engine/EngineProtocols.swift`). This is orthogonal to `TestResult`: a `.readyToTest` strategy
/// can still fail a scan for ordinary reasons (bad network, a DPI variant it doesn't defeat), and
/// a strategy the real-Mac proof of concept has not reached yet must stay
/// `.pendingRealMacVerification` even though nothing here calls it "broken" — reporting a made-up
/// pass or fail would be a false result, not an honest unknown.
public enum StrategyReadiness: Hashable, Sendable {
    /// Default for every built-in strategy right now. The desync technique it needs has not been
    /// verified against real macOS networking APIs yet.
    case pendingRealMacVerification
    /// Verified working end-to-end on real hardware (Windows `warp=on` equivalent check passed).
    case readyToTest
    /// Verified impossible on this platform for a structural reason (e.g. the platform refuses
    /// raw TCP sends), with the reason to show in the UI.
    case knownUnsupported(Msg)
}

/// Where a strategy's readiness is looked up. Deliberately empty right now — see the TODO below.
///
/// TODO(real-Mac PoC, `docs/IMPLEMENTATION_PLAN.md` phases 1–2): as each technique is verified on
/// real hardware, add its strategy ids here with `.readyToTest`, or `.knownUnsupported(reason)` if
/// the PoC finds a hard platform limit. Nothing in this package may populate this on its own —
/// nothing here has run against a real network.
public enum StrategyReadinessRegistry {
    public static let overrides: [String: StrategyReadiness] = [:]

    public static func readiness(for strategyId: String) -> StrategyReadiness {
        overrides[strategyId] ?? .pendingRealMacVerification
    }
}
