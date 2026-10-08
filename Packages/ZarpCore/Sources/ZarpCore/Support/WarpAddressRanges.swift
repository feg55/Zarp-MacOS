/// Public Cloudflare address ranges the official WARP client connects to (engage, MASQUE and
/// WireGuard endpoints). Reference data only — same ranges Windows Zarp documents in
/// `Zapret.WarpRanges4/6` for its "Intercept WARP addresses only" option and for `NextEndpoint`.
///
/// This is informational (settings text, endpoint validation, log messages, test-endpoint
/// selection). It is not a filter rule and nothing here inspects or touches live traffic —
/// that boundary is defined by the protocols in `Engine/EngineProtocols.swift` and belongs to
/// the daemon (`docs/ARCHITECTURE.md` §1).
public enum WarpAddressRanges {
    public static let ranges: [(low: IPAddress, high: IPAddress)] = [
        ("162.159.192.0", "162.159.199.255"),
        ("162.159.204.0", "162.159.204.255"),
        ("188.114.96.0", "188.114.99.255"),
        ("2606:4700:100::", "2606:4700:1ff:ffff:ffff:ffff:ffff:ffff"),
        ("2606:4700:d0::", "2606:4700:df:ffff:ffff:ffff:ffff:ffff"),
    ].map { (low: IPAddress($0.0)!, high: IPAddress($0.1)!) }

    public static func contains(_ ip: IPAddress) -> Bool {
        ranges.contains { r in r.low.version == ip.version && r.low <= ip && ip <= r.high }
    }
}
