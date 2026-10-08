/// Parses and describes the user's `strategies.txt` — same format on every Zarp port:
/// `Name | transport | winws2 profile arguments`, one strategy per line, `#` comments allowed.
/// Ported from Windows `StrategyCatalog.ParseCustom` (`Core/Strategy.cs`) and Android
/// `StrategyCatalog.parseCustom` (`core/StrategyCatalog.kt`).
public enum CustomStrategyFile {
    public static let fileName = "strategies.txt"

    /// Parses custom strategy lines. A malformed line is skipped and reported through
    /// `onSkipped`, never thrown — one bad line must not take down the whole file. Later
    /// duplicate ids win (matches saving results into a dictionary keyed by id).
    public static func parse(_ text: String, onSkipped: (String) -> Void = { _ in }) -> [Strategy] {
        var out: [Strategy] = []
        // CRLF files (Windows editors, some text editors' defaults) and a leading BOM are fine:
        // Swift sees "\r\n" as one Character, so a plain split on "\n" would not split them.
        var normalized = text
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, !parts[0].isEmpty, let transport = Transport(parsing: parts[1]) else {
                onSkipped(line)
                continue
            }
            let id = "custom-" + parts[0].lowercased().replacingOccurrences(of: " ", with: "-")
            out.append(Strategy(id: id, name: "★ " + parts[0], transport: transport, args: parts[2], isCustom: true))
        }
        var seen = Set<String>()
        return out.reversed().filter { seen.insert($0.id).inserted }.reversed()
    }

    /// Template written the first time `strategies.txt` doesn't exist yet — same content as
    /// Windows Zarp's `StrategyCatalog.CustomTemplate` / Android's `CUSTOM_TEMPLATE`. Comments
    /// stay in English: the syntax itself is the same technical winws2 syntax on every platform.
    public static let template = """
    # Custom Zarp strategies. One line = one strategy:
    #   Name | transport | winws2 profile arguments
    # transport: h3 (MASQUE/QUIC), h2 (MASQUE/TLS), wg (WireGuard)
    # Blobs: quic_google, quic_vk, tls_google, tls_vk, stun_fake, zero64
    #
    # Examples:
    # My QUIC | h3 | --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=8
    # My WG   | wg | --payload=wireguard_initiation --lua-desync=fake:blob=zero64:repeats=12

    """
}
