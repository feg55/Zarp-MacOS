/// Built-in strategies, ported id-for-id, name-for-name and argument-for-argument from Windows
/// Zarp's `StrategyCatalog` (`Core/Strategy.cs`), in the same order (top to bottom = most likely
/// first, unchanged from upstream — ids and args are load-bearing: they are what a saved
/// `selectedStrategyId` and `results` dictionary key against). Two HTTP/2 segmentation strategies
/// and the HTTP/2 control strategy are carried over from Android Zarp's catalog
/// (`core/StrategyCatalog.kt`) because their `--lua-desync` calls need nothing beyond a plain TCP
/// send — no raw-socket tricks — unlike the rest of the HTTP/2 entries below them.
///
/// This list says nothing about what actually works on macOS yet; see `StrategyReadiness`.
public enum StrategyCatalog {
    public static let builtIn: [Strategy] = [
        // ---------- MASQUE / HTTP3 (default protocol of the WARP client) ----------
        Strategy(id: "warp-q-google6", name: "WARP QUIC: fake google ×6", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6"),
        Strategy(id: "warp-q-google3", name: "WARP QUIC: fake google ×3", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=3"),
        Strategy(id: "warp-q-vk6", name: "WARP QUIC: fake vk ×6", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_vk:repeats=6"),
        Strategy(id: "warp-q-google-vk", name: "WARP QUIC: fakes google + vk", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=3 --lua-desync=fake:blob=quic_vk:repeats=3"),
        Strategy(id: "warp-q-google10", name: "WARP QUIC: fake google ×10", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=10"),
        Strategy(id: "warp-q-google-ttl", name: "WARP QUIC: fake google ttl=4 ×6", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:ip_ttl=4:ip6_ttl=4:repeats=6"),
        Strategy(id: "warp-q-vk-ttl", name: "WARP QUIC: fake vk ttl=4 ×6", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_vk:ip_ttl=4:ip6_ttl=4:repeats=6"),
        Strategy(id: "warp-q-google-bad", name: "WARP QUIC: fake google badsum ×6", transport: .masqueH3,
                 args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:badsum:repeats=6"),

        // ---------- WireGuard ----------
        Strategy(id: "warp-wg-google6", name: "WARP WireGuard: fake QUIC google ×6", transport: .wireGuard,
                 args: "--payload=wireguard_initiation --lua-desync=fake:blob=quic_google:repeats=6"),
        Strategy(id: "warp-wg-stun", name: "WARP WireGuard: fake STUN ×6", transport: .wireGuard,
                 args: "--payload=wireguard_initiation --lua-desync=fake:blob=stun_fake:repeats=6"),
        Strategy(id: "warp-wg-vk10", name: "WARP WireGuard: fake QUIC vk ×10", transport: .wireGuard,
                 args: "--payload=wireguard_initiation --lua-desync=fake:blob=quic_vk:repeats=10"),
        Strategy(id: "warp-wg-google-ttl", name: "WARP WireGuard: fake google ttl=4", transport: .wireGuard,
                 args: "--payload=wireguard_initiation --lua-desync=fake:blob=quic_google:ip_ttl=4:ip6_ttl=4:repeats=6"),

        // ---------- MASQUE / HTTP2 (TLS over TCP) ----------
        Strategy(id: "warp-t-google-md5", name: "WARP TLS: fake google md5 + split", transport: .masqueH2,
                 args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_google:tcp_md5:repeats=6 --lua-desync=multisplit:pos=1,midsld"),
        Strategy(id: "warp-t-seqovl", name: "WARP TLS: seqovl google", transport: .masqueH2,
                 args: "--payload=tls_client_hello --lua-desync=multisplit:pos=2:seqovl=681:seqovl_pattern=tls_google"),
        Strategy(id: "warp-t-vk-seq", name: "WARP TLS: fake vk badseq + disorder", transport: .masqueH2,
                 args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_vk:tcp_seq=-3000:repeats=6 --lua-desync=multidisorder:pos=1,midsld"),
        Strategy(id: "warp-t-hostfake", name: "WARP TLS: hostfakesplit vk.com", transport: .masqueH2,
                 args: "--payload=tls_client_hello --lua-desync=hostfakesplit:host=vk.com:tcp_md5"),
        // Android Zarp addition: plain TCP segmentation, no raw-socket trick beyond the send itself.
        Strategy(id: "warp-t-split", name: "WARP TLS: split 1,midsld", transport: .masqueH2,
                 args: "--payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld"),
        Strategy(id: "warp-t-disorder", name: "WARP TLS: disorder 1,midsld", transport: .masqueH2,
                 args: "--payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld"),

        // ---------- Control: maybe WARP already works on this network ----------
        Strategy(id: "direct", name: "Direct connection (no desync)", transport: .masqueH3, args: "", nameKey: "strategy.direct"),
        Strategy(id: "direct-h2", name: "Direct over HTTP/2 (no desync)", transport: .masqueH2, args: "", nameKey: "strategy.directH2"),
    ]

    /// Built-in strategies plus the user's `strategies.txt`, in that order (matches Windows/Android).
    public static func load(customText: String, onSkipped: (String) -> Void = { _ in }) -> [Strategy] {
        builtIn + CustomStrategyFile.parse(customText, onSkipped: onSkipped)
    }
}
