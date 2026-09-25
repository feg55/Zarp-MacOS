import Network
import NetworkExtension
import os.log

/// Smoke-test stub only: proves the target signs, builds, and activates with this Apple ID/team.
/// Allows every packet unconditionally — no WARP detection, no delay, no injection yet. That
/// starts once `docs/MACOS_NETWORK_RESEARCH.md` Q1 (does the entitlement/signing path work at
/// all) has a real answer instead of a guess.
final class FilterPacketProvider: NEFilterPacketProvider {
    private let log = Logger(subsystem: "io.github.zarp.filter", category: "FilterPacketProvider")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        log.notice("Zarp filter starting (signing/entitlement smoke test)")
        packetHandler = { _, _, _, _, _ in .allow }
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.notice("Zarp filter stopping: \(String(describing: reason))")
        completionHandler()
    }
}
