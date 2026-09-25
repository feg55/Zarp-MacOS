import Foundation
import SystemExtensions
import os.log

/// PoC-only wiring for `docs/MACOS_NETWORK_RESEARCH.md` Q1: activates `ZarpFilter` and reports
/// what actually happens (needs approval / completed / failed) through the app's own log, so it's
/// visible the same way as everything else in `LogView` — no separate PoC/App target needed since
/// `ZarpFilter` is already embedded in this app bundle (`project.yml`'s `embed: true` dependency).
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionActivator()
    private let log = Logger(subsystem: "io.github.zarp.mac", category: "SystemExtensionActivator")
    private var onEvent: ((String) -> Void)?

    func activate(identifier: String, onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.notice("Submitted activation request for \(identifier, privacy: .public)")
        onEvent("Submitted activation request for \(identifier)")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.notice("Replacing existing extension \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.notice("Needs user approval (System Settings > General > Login Items & Extensions)")
        onEvent?("Needs approval in System Settings \u{2192} General \u{2192} Login Items & Extensions")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let text = result == .completed ? "completed" : "will complete after reboot"
        log.notice("Activation finished: \(text, privacy: .public)")
        onEvent?("Activation finished: \(text)")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log.error("Activation failed: \(error.localizedDescription, privacy: .public)")
        onEvent?("Activation failed: \(error.localizedDescription)")
    }
}
