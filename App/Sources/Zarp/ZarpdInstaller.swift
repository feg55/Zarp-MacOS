import Foundation
import ServiceManagement
import ZarpCore

/// Installs, checks, and removes the `zarpd` privileged LaunchDaemon via `SMAppService` (macOS 13+)
/// — the modern replacement for `SMJobBless`/`AuthorizationExecuteWithPrivileges`. `zarpd` is
/// embedded in this app's own bundle at build time (`project.yml`'s "Build and embed zarpd daemon"
/// script phase: `Contents/MacOS/zarpd` + `Contents/Library/LaunchDaemons/*.plist`) and shares this
/// app's own code-signing Team ID, which is what lets `register()` work at all — confirmed for
/// real on a free "Personal Team" identity, no paid Apple Developer Program membership needed
/// (docs/IMPLEMENTATION_PLAN.md Phase 8).
///
/// `register()` triggers the OS's own authorization UI (a one-time admin password/Touch ID prompt,
/// then — on first install — a "background item added" notification the user approves once in
/// System Settings › General › Login Items & Extensions); this type does not, and cannot, build a
/// custom authorization dialog to replace that, matching Apple's own intended flow.
@MainActor
final class ZarpdInstaller: ObservableObject {
    enum State: Equatable {
        case notInstalled
        /// Registered, but the user hasn't approved it in System Settings yet — `zarpd` is not
        /// actually running.
        case requiresApproval
        /// Registered and launchd has it enabled; doesn't by itself mean the process is currently
        /// alive (crashed-and-KeepAlive-restarting looks the same) — `ZarpdClient.ping()` answers
        /// that, this only answers "is it installed."
        case enabled
        case notFound
        case unknown(String)
    }

    @Published private(set) var state: State = .notInstalled

    private static let plistName = "io.github.zarp.mac.zarpd.plist"
    private let service = SMAppService.daemon(plistName: plistName)

    init() {
        refresh()
    }

    func refresh() {
        state = Self.map(service.status)
    }

    /// Thrown by `install()` before touching `SMAppService` at all — see `InstallLocationProblem`
    /// for why registering from these locations produces a daemon that quietly stops working.
    struct BadInstallLocation: Error {
        let problem: InstallLocationProblem
    }

    /// Registers the daemon. Throws on real failure (e.g. the user declined authorization); a
    /// successful call still may leave `state == .requiresApproval` until the user acts on the
    /// System Settings prompt — call `openSystemSettingsLoginItems()` to take them there directly,
    /// matching Apple's documented pattern for this exact status.
    ///
    /// Refuses (`BadInstallLocation`, before calling `register()`, so no authorization prompt is
    /// ever shown for a registration that would be broken anyway) when the app is running from a
    /// mounted disk image or an App Translocation path.
    func install() throws {
        if let problem = InstallLocationProblem.detect(bundlePath: Bundle.main.bundleURL.path) {
            throw BadInstallLocation(problem: problem)
        }
        try service.register()
        refresh()
    }

    /// Unregisters the daemon (Phase 8's "clean uninstall"). Idempotent — unregistering something
    /// already unregistered is not treated as an error by `SMAppService` itself.
    func uninstall() throws {
        try service.unregister()
        refresh()
    }

    /// Opens System Settings › General › Login Items & Extensions, where a `.requiresApproval`
    /// daemon shows up waiting for a one-time toggle. `SMAppService`'s own documented way to get
    /// the user there without Zarp needing to know which OS version phrases that pane how.
    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> State {
        switch status {
        case .notRegistered: return .notInstalled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown(String(describing: status))
        }
    }
}
