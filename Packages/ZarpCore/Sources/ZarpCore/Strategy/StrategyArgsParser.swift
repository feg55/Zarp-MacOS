import Foundation

/// Parser for the subset of zapret2 (winws2) profile syntax that Zarp's built-in and custom
/// strategies use. Ported from Android Zarp's `ZapretArgs.parse` (`core/ZapretArgs.kt`), which
/// documents the same winws2 argument grammar Windows Zarp passes straight through to the
/// `winws2` process. Pure string parsing: it builds a `DesyncPlan` describing the request and
/// never touches a socket or a byte of packet data.
public enum StrategyArgsParser {
    private static let quicPayload = "quic_initial"
    private static let tlsPayload = "tls_client_hello"
    private static let wireGuardPayload = "wireguard_initiation"
    private static let maxRepeats = 50

    public static func parse(transport: Transport, args: String) -> DesyncPlan {
        let tokens = args.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return DesyncPlan() }

        var fakes: [FakeStep] = []
        var tcpDesync: TCPDesyncStep?

        for tok in tokens {
            let (key, value) = splitOnce(tok, on: "=")
            switch key {
            case "--payload":
                let wanted: String
                switch transport {
                case .masqueH3: wanted = quicPayload
                case .masqueH2: wanted = tlsPayload
                case .wireGuard: wanted = wireGuardPayload
                }
                if !value.split(separator: ",").map(String.init).contains(wanted) {
                    return syntaxIssue("payload '\(value)' never matches the \(transport.title) handshake")
                }

            case "--lua-desync":
                let parts = value.split(separator: ":").map(String.init)
                guard let fn = parts.first else { return syntaxIssue("empty --lua-desync") }
                guard let params = parseParams(Array(parts.dropFirst())) else {
                    return syntaxIssue("bad arguments in '\(tok)'")
                }
                switch (transport, fn) {
                case (.masqueH3, "fake"), (.wireGuard, "fake"):
                    guard let step = parseFake(params) else { return DesyncPlan(parseIssue: fakeIssue(params)) }
                    fakes.append(step)
                case (.masqueH2, "multisplit"), (.masqueH2, "multidisorder"):
                    if tcpDesync != nil { return syntaxIssue("only one TCP split per strategy is supported") }
                    let extra = Set(params.keys).subtracting(["pos"])
                    if !extra.isEmpty { return rawIssue("\(fn):" + extra.sorted().joined(separator: ":")) }
                    let pos = params["pos"] ?? "2" // winws2 default
                    guard let positions = parsePositions(pos) else { return syntaxIssue("bad split positions '\(pos)'") }
                    tcpDesync = TCPDesyncStep(mode: fn == "multisplit" ? .split : .disorder, positions: positions)
                default:
                    return rawIssue("\(fn) (\(transport.title))")
                }

            default:
                return syntaxIssue("unknown option '\(key)'")
            }
        }
        return DesyncPlan(fakeSteps: fakes, tcpDesync: tcpDesync)
    }

    // MARK: - Issues

    /// A technique this parser does not implement at all for this transport (wrong payload
    /// family, or a `--lua-desync` function beyond plain fake-send / TCP segmentation).
    private static func rawIssue(_ feature: String) -> DesyncPlan {
        DesyncPlan(parseIssue: Msg("strategy.unknownFeature", feature))
    }

    private static func syntaxIssue(_ detail: String) -> DesyncPlan {
        DesyncPlan(parseIssue: Msg("strategy.badSyntax", detail))
    }

    // MARK: - Tokenizing

    private static func splitOnce(_ s: String, on separator: Character) -> (String, String) {
        guard let idx = s.firstIndex(of: separator) else { return (s, "") }
        return (String(s[s.startIndex..<idx]), String(s[s.index(after: idx)...]))
    }

    /// `"blob=quic_google"`, `"repeats=6"`, `"badsum"` -> map; bare flags get an empty value.
    private static func parseParams(_ items: [String]) -> [String: String]? {
        var out: [String: String] = [:]
        for item in items {
            guard !item.isEmpty else { return nil }
            let (k, v) = splitOnce(item, on: "=")
            out[k] = v
        }
        return out
    }

    // MARK: - fake:...

    private static let fakeKeys: Set<String> = ["blob", "repeats", "ip_ttl", "ip6_ttl"]

    private static func parseFake(_ p: [String: String]) -> FakeStep? {
        guard Set(p.keys).subtracting(fakeKeys).isEmpty else { return nil }
        guard let blobKey = p["blob"], let blob = Blob.byKey(blobKey) else { return nil }
        let repeats = p["repeats"].flatMap(Int.init) ?? 1
        guard (1...maxRepeats).contains(repeats) else { return nil }
        var ttl: Int?, ttl6: Int?
        if let s = p["ip_ttl"] { guard let v = Int(s) else { return nil }; ttl = v }
        if let s = p["ip6_ttl"] { guard let v = Int(s) else { return nil }; ttl6 = v }
        if let t = ttl, !(1...255).contains(t) { return nil }
        if let t = ttl6, !(1...255).contains(t) { return nil }
        return FakeStep(blob: blob, repeats: repeats, ipTTL: ttl, ip6TTL: ttl6)
    }

    /// Mirrors Android's `fakeProblem`: badsum first, then any other unrecognised key, then a
    /// missing or unknown blob, then a generic catch-all for e.g. an out-of-range `repeats`.
    private static func fakeIssue(_ p: [String: String]) -> Msg {
        let extra = Set(p.keys).subtracting(fakeKeys)
        if extra.contains("badsum") { return Msg("strategy.badsum") }
        if !extra.isEmpty { return Msg("strategy.unknownFeature", "fake:" + extra.sorted().joined(separator: ":")) }
        guard let blobKey = p["blob"] else { return Msg("strategy.badSyntax", "fake needs blob=") }
        guard Blob.byKey(blobKey) != nil else { return Msg("strategy.badSyntax", "unknown blob '\(blobKey)'") }
        return Msg("strategy.badSyntax", "bad fake parameters")
    }

    // MARK: - multisplit / multidisorder positions

    private static let positionMarkers: Set<String> = ["host", "endhost", "sld", "midsld"]

    private static func parsePositions(_ pos: String) -> [String]? {
        let parts = pos.split(separator: ",").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ positionMarkers.contains($0) || Int($0) != nil }) else { return nil }
        return parts
    }
}
