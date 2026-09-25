import Foundation

/// Persisted app settings and results. Same field names and defaults as Windows Zarp's
/// `AppConfig` (`Core/AppConfig.cs`), except where macOS has no equivalent: there is no bundled
/// backend binary for this app to download or update, so Windows' `AutoUpdateZapret` has no
/// counterpart here.
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
    /// Intercept WARP addresses only (recommended); see `WarpAddressRanges`.
    public var restrictToWarpAddresses: Bool = true
    /// Every test uses a fresh WARP endpoint, so a strategy cannot inherit DPI state from the
    /// previous successful connection (Windows `IsolateTests`).
    public var isolateTests: Bool = true
    /// UI language code; `nil` means "follow the system", same as Windows `Language`.
    public var language: String?

    public init() {}
}
