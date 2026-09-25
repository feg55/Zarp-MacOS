/// A message that resolves to text only when displayed, so status, log and error text follow a
/// language change without re-running whatever produced them. Same idea as Windows Zarp's `Msg`
/// (`Core/L.cs`) and Android Zarp's `Msg`.
public struct Msg: Hashable, Sendable, Codable {
    public let key: String
    public let args: [String]

    public init(_ key: String, _ args: CustomStringConvertible...) {
        self.key = key
        self.args = args.map(\.description)
    }

    public init(key: String, args: [String]) {
        self.key = key
        self.args = args
    }

    public func text(using loc: Localization) -> String {
        loc.string(key, args)
    }
}
