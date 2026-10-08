/// One `fake:...` step: send `blob` `repeats` times before the real handshake packet. `ipTTL` /
/// `ip6TTL` apply to the fakes only (winws2's `ip_ttl=`/`ip6_ttl=`). Purely descriptive data —
/// nothing here sends anything.
public struct FakeStep: Hashable, Sendable {
    public let blob: Blob
    public let repeats: Int
    public let ipTTL: Int?
    public let ip6TTL: Int?

    public init(blob: Blob, repeats: Int, ipTTL: Int? = nil, ip6TTL: Int? = nil) {
        self.blob = blob
        self.repeats = repeats
        self.ipTTL = ipTTL
        self.ip6TTL = ip6TTL
    }
}

/// A TCP ClientHello segmentation step: `split` sends the pieces in order, `disorder` sends the
/// first piece with a TTL of 1 so it is retransmitted after the rest (winws2's `multisplit` /
/// `multidisorder`). `positions` are winws2's own position markers: a byte offset (negative =
/// from the end) or one of `host`, `endhost`, `sld`, `midsld`.
public struct TCPDesyncStep: Hashable, Sendable {
    public enum Mode: String, Sendable { case split, disorder }
    public let mode: Mode
    public let positions: [String]

    public init(mode: Mode, positions: [String]) {
        self.mode = mode
        self.positions = positions
    }
}

/// What a strategy's `args` string asks for, parsed from winws2 profile syntax by
/// `StrategyArgsParser`. This only *describes* the request — which blob, how many times, what
/// TTL, where to split a ClientHello. It says nothing about whether the daemon can carry any of it
/// out; that is `StrategyReadiness` (and `Strategy.unsupportedReason`).
public struct DesyncPlan: Hashable, Sendable {
    public var fakeSteps: [FakeStep] = []
    public var tcpDesync: TCPDesyncStep?
    /// Set when `args` uses syntax this parser does not understand, or asks for a technique that
    /// needs more than a fake-packet send or a plain TCP segmentation (e.g. `badsum`, `tcp_md5`,
    /// `seqovl`, which need raw-socket-level packet crafting). `nil` does not mean "will work on
    /// macOS" — only that the argument syntax parsed into a fake-send / TCP-split request cleanly.
    public var parseIssue: Msg?

    public init(fakeSteps: [FakeStep] = [], tcpDesync: TCPDesyncStep? = nil, parseIssue: Msg? = nil) {
        self.fakeSteps = fakeSteps
        self.tcpDesync = tcpDesync
        self.parseIssue = parseIssue
    }

    /// No desync at all — WARP would connect as-is (the "direct" control strategies).
    public var isDirect: Bool { fakeSteps.isEmpty && tcpDesync == nil && parseIssue == nil }
}
