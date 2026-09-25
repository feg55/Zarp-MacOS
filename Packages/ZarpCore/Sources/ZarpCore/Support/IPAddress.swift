import Foundation

/// IPv4 or IPv6 address without any platform socket types, so it works in the extension,
/// the helper and in Linux tests alike.
public enum IPAddress: Hashable, Sendable {
    /// Numeric value, most significant byte first (192.168.0.1 = 0xC0A80001).
    case v4(UInt32)
    /// 16 bytes, network order.
    case v6([UInt8])

    public var version: Int {
        switch self {
        case .v4: return 4
        case .v6: return 6
        }
    }

    /// Network-order bytes: 4 for IPv4, 16 for IPv6.
    public var bytes: [UInt8] {
        switch self {
        case .v4(let v):
            return [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        case .v6(let b):
            return b
        }
    }

    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case 4:
            self = .v4(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case 16:
            self = .v6(bytes)
        default:
            return nil
        }
    }

    /// Parses dotted IPv4 or textual IPv6 (with `::` compression, without zone or embedded IPv4).
    public init?(_ text: String) {
        if text.contains(":") {
            guard let b = IPAddress.parseV6(text) else { return nil }
            self = .v6(b)
        } else {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var value: UInt32 = 0
            for p in parts {
                guard !p.isEmpty, p.count <= 3, let n = UInt32(p), n <= 255 else { return nil }
                value = value << 8 | n
            }
            self = .v4(value)
        }
    }

    private static func parseV6(_ text: String) -> [UInt8]? {
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ s: String) -> [UInt16]? {
            if s.isEmpty { return [] }
            var out: [UInt16] = []
            for g in s.split(separator: ":", omittingEmptySubsequences: false) {
                guard !g.isEmpty, g.count <= 4, let v = UInt16(g, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        var words: [UInt16]
        if halves.count == 2 {
            guard let tail = groups(halves[1]), head.count + tail.count <= 7 else { return nil }
            words = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            guard head.count == 8 else { return nil }
            words = head
        }
        return words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
    }
}

extension IPAddress: Comparable {
    /// Orders IPv4 before IPv6, then by bytes. Used for range checks within one family.
    public static func < (a: IPAddress, b: IPAddress) -> Bool {
        if a.version != b.version { return a.version < b.version }
        return a.bytes.lexicographicallyPrecedes(b.bytes)
    }
}

extension IPAddress: CustomStringConvertible {
    public var description: String {
        switch self {
        case .v4:
            return bytes.map(String.init).joined(separator: ".")
        case .v6(let b):
            var words = [UInt16](repeating: 0, count: 8)
            for i in 0..<8 { words[i] = UInt16(b[2 * i]) << 8 | UInt16(b[2 * i + 1]) }
            // RFC 5952: compress the longest run of two or more zero groups
            var bestStart = -1, bestLen = 0, i = 0
            while i < 8 {
                if words[i] == 0 {
                    var j = i
                    while j < 8 && words[j] == 0 { j += 1 }
                    if j - i > bestLen && j - i >= 2 { bestStart = i; bestLen = j - i }
                    i = j
                } else {
                    i += 1
                }
            }
            let hex = words.map { String($0, radix: 16) }
            if bestStart < 0 { return hex.joined(separator: ":") }
            let head = hex[0..<bestStart].joined(separator: ":")
            let tail = hex[(bestStart + bestLen)...].joined(separator: ":")
            return head + "::" + tail
        }
    }
}

extension IPAddress: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let ip = IPAddress(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad IP \(text)"))
        }
        self = ip
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
