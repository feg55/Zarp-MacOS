/// A WARP strategy: tunnel transport + the handshake-desync steps it asks for, written in
/// zapret2's `winws2` profile argument syntax — the same syntax Windows Zarp and Android Zarp
/// use, so a `strategies.txt` file is interchangeable across all three ports. Empty `args` means
/// "no desync": WARP would connect directly (Windows Zarp's `Strategy.UsesZapret == false`).
public struct Strategy: Identifiable, Hashable, Sendable {
    public let id: String
    /// Localization key for built-in strategies, resolved at display time so the name follows
    /// language changes (Windows `Strategy.NameKey`). `nil` for custom strategies, which keep the
    /// name the user typed in `strategies.txt`.
    public let nameKey: String?
    private let literalName: String
    public let transport: Transport
    /// winws2-style profile arguments, e.g.
    /// `--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6`.
    public let args: String
    public let isCustom: Bool

    public init(id: String, name: String, transport: Transport, args: String, isCustom: Bool = false, nameKey: String? = nil) {
        self.id = id
        self.nameKey = nameKey
        self.literalName = name
        self.transport = transport
        self.args = args
        self.isCustom = isCustom
    }

    /// Display name: translated by `nameKey` for built-ins, the literal typed name for custom
    /// strategies — same rule as Windows `Strategy.Name`.
    public func name(using loc: Localization) -> String {
        nameKey.map { loc.string($0) } ?? literalName
    }

    /// `false` only for the "direct" control strategies: WARP would connect without any desync
    /// (Windows `Strategy.UsesZapret`).
    public var requiresDesync: Bool { !args.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What `args` asks for. Parsing only describes the request — see `StrategyReadiness` for
    /// whether macOS can currently carry any of it out.
    public var plan: DesyncPlan { StrategyArgsParser.parse(transport: transport, args: args) }

    /// Current readiness, looked up from `StrategyReadinessRegistry` (empty until the real-Mac PoC
    /// fills it in, so every built-in strategy reads `.pendingRealMacVerification` today).
    public var readiness: StrategyReadiness { StrategyReadinessRegistry.readiness(for: id) }

    // Identity is by id: two `Strategy` values with the same id are the same strategy even if one
    // is a freshly-reloaded copy with identical fields — matches how results/selection are keyed.
    public static func == (a: Strategy, b: Strategy) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
