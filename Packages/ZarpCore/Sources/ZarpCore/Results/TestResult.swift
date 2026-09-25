import Foundation

/// Result of testing one strategy: same shape as Windows Zarp's `TestResult`
/// (`Core/AppConfig.cs`) and Android Zarp's `TestResult.kt`, so the scoring and double-verification
/// rules match both.
public struct TestResult: Hashable, Sendable, Codable {
    public let strategyId: String
    public var ok: Bool = false
    public var connectMs: Int = 0
    public var pingMs: Int = 0
    /// Error text as-is, when there is no translation key for it (e.g. a raw message from the
    /// networking layer).
    public var error: String?
    /// Error as a translation key + arguments, shown in the current language.
    public var errorKey: String?
    public var errorArgs: [String] = []
    /// The failure happened on the second, independent check.
    public var rechecked: Bool = false
    /// Passed the second, independent check (different WARP endpoint, fresh attempt).
    public var confirmed: Bool = false
    /// The WARP endpoint this test used, for diagnostics (Android Zarp records this too; Windows
    /// only logs it).
    public var endpoint: String?
    public var timestamp: Date = Date()

    public init(strategyId: String, ok: Bool = false, connectMs: Int = 0, pingMs: Int = 0,
                error: String? = nil, errorKey: String? = nil, errorArgs: [String] = [],
                rechecked: Bool = false, confirmed: Bool = false, endpoint: String? = nil,
                timestamp: Date = Date()) {
        self.strategyId = strategyId
        self.ok = ok
        self.connectMs = connectMs
        self.pingMs = pingMs
        self.error = error
        self.errorKey = errorKey
        self.errorArgs = errorArgs
        self.rechecked = rechecked
        self.confirmed = confirmed
        self.endpoint = endpoint
        self.timestamp = timestamp
    }

    /// Lower is better. Ping weighs 4×: it affects every request after connecting, connecting
    /// happens once — same weighting as Windows `TestResult.Score` / Android `TestResult.score`.
    public var score: Int { ok ? connectMs + pingMs * 4 : Int.max }

    public var errorMsg: Msg? { errorKey.map { Msg(key: $0, args: errorArgs) } }

    public func errorText(using loc: Localization) -> String {
        errorMsg?.text(using: loc) ?? error ?? ""
    }

    /// Text for the strategy list / log: adds "not confirmed" framing when the failure happened on
    /// the independent re-check (Windows `TestResult.DisplayError`).
    public func displayError(using loc: Localization) -> String {
        let text = errorText(using: loc)
        return rechecked ? loc.string("result.notConfirmed", [text]) : text
    }

    public static func failed(strategyId: String, error: Msg, timestamp: Date = Date(), endpoint: String? = nil) -> TestResult {
        TestResult(strategyId: strategyId, ok: false, errorKey: error.key, errorArgs: error.args, endpoint: endpoint, timestamp: timestamp)
    }

    public static func failedRaw(strategyId: String, error: String, timestamp: Date = Date(), endpoint: String? = nil) -> TestResult {
        TestResult(strategyId: strategyId, ok: false, error: error, endpoint: endpoint, timestamp: timestamp)
    }

    /// Double-verification merge: the slower (more pessimistic) connect time, the average ping —
    /// same rule as Windows `Engine.SearchAndApplyAsync` / Android `TestResult.confirmed`.
    public static func confirmed(_ first: TestResult, _ second: TestResult) -> TestResult {
        TestResult(strategyId: second.strategyId, ok: true, connectMs: max(first.connectMs, second.connectMs),
                   pingMs: (first.pingMs + second.pingMs) / 2, confirmed: true, endpoint: second.endpoint,
                   timestamp: second.timestamp)
    }
}
