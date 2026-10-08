import Foundation

/// Persisted app settings and results. Same field names and defaults as Windows Zarp's
/// `AppConfig` (`Core/AppConfig.cs`) where macOS has the same feature; the macOS-only additions are
/// marked below, and the Windows options with no macOS counterpart (`AutoUpdateZapret` — there is
/// no backend binary to update; `RestrictToWarpIps` — there is no packet filter to restrict) are
/// simply not here.
///
/// Decoding is deliberately forgiving: every field falls back to its default when it is missing, so
/// a settings file written by an older build (or hand-edited, or from the Windows app) keeps all of
/// its other values when a field is added later, instead of the whole file being thrown away.
/// Unknown keys are ignored for the same reason.
public struct AppSettings: Codable, Sendable, Equatable {
    public var selectedStrategyId: String?
    public var results: [String: TestResult] = [:]

    /// Seconds to wait for WARP to connect on one strategy.
    public var testTimeoutSec: Int = 15
    /// Working strategies to find before Quick Scan stops (Full Scan always tests all of them).
    public var stopAfterWorking: Int = 3
    public var autoConnectOnStart: Bool = false
    /// Ask on window close until the user picks "remember my choice" (Windows `AskBeforeClose`).
    public var askBeforeClose: Bool = true
    public var minimizeToMenuBar: Bool = true
    public var disconnectOnExit: Bool = true
    /// Every test uses a fresh WARP endpoint, so a strategy cannot inherit DPI state from the
    /// previous successful connection (Windows `IsolateTests`).
    public var isolateTests: Bool = true
    /// UI language code; `nil` means "follow the system", same as Windows `Language`.
    public var language: String?

    // MARK: macOS-only

    /// Send all of the Mac's traffic through WARP while connected. When off, the tunnel carries
    /// only the measurement target — enough to prove a strategy works, but nothing else the user
    /// does is affected (a diagnostic mode, and the safety valve if a full tunnel misbehaves).
    public var routeAllTraffic: Bool = true
    /// While a full tunnel is up, resolve names through Cloudflare's resolvers (the original DNS
    /// settings are restored on disconnect). Only meaningful with `routeAllTraffic`.
    public var overrideDNS: Bool = true
    /// When a connected tunnel drops by itself (network change, sleep/wake, WARP dropping the
    /// session), reconnect with the same strategy — a few quiet attempts, never a rescan.
    public var reconnectOnLoss: Bool = true
    /// The user has accepted Cloudflare's WARP terms, so Zarp may register an anonymous WARP
    /// account for this Mac. Nothing registers before this is true.
    public var warpTermsAccepted: Bool = false

    public static let timeoutRange = 5...60
    public static let stopAfterRange = 1...100

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case selectedStrategyId, results, testTimeoutSec, stopAfterWorking, autoConnectOnStart
        case askBeforeClose, minimizeToMenuBar, disconnectOnExit, isolateTests, language
        case routeAllTraffic, overrideDNS, reconnectOnLoss, warpTermsAccepted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        // Lenient per field: a value of the wrong type (a hand edit, a different app's file) falls
        // back to that field's default instead of discarding every other setting in the file.
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        selectedStrategyId = (try? c.decodeIfPresent(String.self, forKey: .selectedStrategyId)) ?? nil
        // One damaged result must not cost the user every other result they scanned for.
        results = ((try? c.decodeIfPresent([String: LossyDecodable<TestResult>].self, forKey: .results)) ?? nil)?
            .compactMapValues(\.value) ?? d.results
        testTimeoutSec = field(.testTimeoutSec, d.testTimeoutSec)
        stopAfterWorking = field(.stopAfterWorking, d.stopAfterWorking)
        autoConnectOnStart = field(.autoConnectOnStart, d.autoConnectOnStart)
        askBeforeClose = field(.askBeforeClose, d.askBeforeClose)
        minimizeToMenuBar = field(.minimizeToMenuBar, d.minimizeToMenuBar)
        disconnectOnExit = field(.disconnectOnExit, d.disconnectOnExit)
        isolateTests = field(.isolateTests, d.isolateTests)
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil
        routeAllTraffic = field(.routeAllTraffic, d.routeAllTraffic)
        overrideDNS = field(.overrideDNS, d.overrideDNS)
        reconnectOnLoss = field(.reconnectOnLoss, d.reconnectOnLoss)
        warpTermsAccepted = field(.warpTermsAccepted, d.warpTermsAccepted)
        self = normalized()
    }

    /// The same settings with numeric fields forced into the ranges the UI offers — a hand-edited
    /// file can't make a scan wait forever or stop after zero strategies.
    public func normalized() -> AppSettings {
        var s = self
        s.testTimeoutSec = min(max(s.testTimeoutSec, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        s.stopAfterWorking = min(max(s.stopAfterWorking, Self.stopAfterRange.lowerBound), Self.stopAfterRange.upperBound)
        return s
    }
}

/// Decodes a `T` or, if that fails, yields `nil` instead of throwing — lets a collection skip the
/// entries it can't read rather than failing as a whole.
struct LossyDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
