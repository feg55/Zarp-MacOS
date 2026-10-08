/// Whether this app can actually carry out a strategy. Orthogonal to `TestResult`: an `.available`
/// strategy can still fail a scan for ordinary reasons (bad network, a DPI variant it doesn't
/// defeat); an `.unsupported` one is never attempted at all.
///
/// This matters because the daemon is only ever sent what `DesyncPlan` describes. A strategy whose
/// technique this port can't perform (`badsum`, `tcp_md5`, `seqovl`, `hostfakesplit`, WireGuard...)
/// has an *empty* plan — which, if it were sent anyway, would run as a plain direct connection and
/// then be recorded as "works ✔✔" under the unsupported strategy's name. Before this type was
/// consulted, five of the built-in strategies did exactly that.
public enum StrategyReadiness: Hashable, Sendable {
    /// Everything the strategy asks for is something the daemon can do.
    case available
    /// Never attempted; the message says why, in a form the strategy table can show.
    case unsupported(Msg)
}
