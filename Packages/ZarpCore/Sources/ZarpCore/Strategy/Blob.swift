/// Fake-packet payloads Zarp strategies reference by name. Same keys as Windows Zarp's
/// `Zapret.Blobs` and Android Zarp's `Blob` enum, so a `strategies.txt` file written for one port
/// reads the same on this one. The bytes themselves are the zapret2 fake-packet captures (MIT,
/// `_reference/zapret2/files/fake/*.bin`), vendored into `Resources/blobs/*.bin` unchanged. This
/// type only names them for the strategy parser and catalog — nothing in this file reads, sends,
/// or otherwise touches the bytes; that is the platform networking layer's job (see
/// `Engine/EngineProtocols.swift`).
public enum Blob: String, CaseIterable, Sendable {
    case quicGoogle = "quic_google"
    case quicVk = "quic_vk"
    case tlsGoogle = "tls_google"
    case tlsVk = "tls_vk"
    case stunFake = "stun_fake"
    /// 64 zero bytes (Windows Zarp: `"0x" + 128 hex zeros`). No file on disk.
    case zero64 = "zero64"

    public static func byKey(_ key: String) -> Blob? { Blob(rawValue: key) }

    /// File name under `Resources/blobs`, `nil` for the synthetic all-zero blob.
    public var fileName: String? {
        switch self {
        case .quicGoogle: return "quic_initial_www_google_com.bin"
        case .quicVk: return "quic_initial_vk_com.bin"
        case .tlsGoogle: return "tls_clienthello_www_google_com.bin"
        case .tlsVk: return "tls_clienthello_vk_com.bin"
        case .stunFake: return "stun.bin"
        case .zero64: return nil
        }
    }
}
