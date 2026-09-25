/// Tunnel protocol the WARP client uses for a strategy. Same three options as Windows Zarp's
/// `WarpTransport` (`Core/Strategy.cs`).
public enum Transport: String, Codable, CaseIterable, Sendable {
    /// MASQUE over HTTP/3 (QUIC, UDP). Default protocol of the WARP client.
    case masqueH3
    /// MASQUE over HTTP/2 (TLS, TCP). Fallback transport of the WARP client.
    case masqueH2
    /// Classic WireGuard (UDP).
    case wireGuard

    /// Display title, same wording as Windows `Strategy.TransportTitle`.
    public var title: String {
        switch self {
        case .masqueH3: return "MASQUE / HTTP3"
        case .masqueH2: return "MASQUE / HTTP2"
        case .wireGuard: return "WireGuard"
        }
    }

    /// Parses the `strategies.txt` transport column: `h3`/`masque`/`masque-h3`, `h2`/`masque-h2`,
    /// `wg`/`wireguard` (case-insensitive) — same aliases as Windows `Strategy.TryParseTransport`.
    public init?(parsing text: String) {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "h3", "masque", "masque-h3": self = .masqueH3
        case "h2", "masque-h2": self = .masqueH2
        case "wg", "wireguard": self = .wireGuard
        default: return nil
        }
    }
}
