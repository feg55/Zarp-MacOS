import Foundation

/// A place the app can be running from where registering the `zarpd` LaunchDaemon is wrong — either
/// because it would quietly produce a daemon that stops working, or because it would hand a root
/// process to a location ordinary users can modify.
///
/// `SMAppService.daemon`'s plist uses `BundleProgram`, a path *relative to the app bundle*, so
/// launchd re-resolves it against wherever the bundle was when `register()` ran, and:
///
/// - A `.dmg` double-clicked and opened in place (or an app on any other mounted volume) vanishes
///   when the image is ejected, taking the daemon's executable with it.
/// - A quarantined app launched from where it was downloaded (Downloads, Desktop) instead of being
///   moved first is run by Gatekeeper from a randomized, read-only "App Translocation" copy that is
///   discarded afterwards.
///
/// And because the daemon runs as **root**, where its executable lives matters for security too: a
/// bundle in a folder the logged-in user owns (`~/Applications`, `~/Downloads`, a build directory)
/// is an executable any process of that user could replace, which would then run as root. So a
/// release build only registers the daemon from the system `/Applications` folder. (Development
/// builds, run from Xcode's DerivedData, are exempt — see `detect`.)
public enum InstallLocationProblem: Equatable, Sendable {
    case mountedVolume
    case translocated
    /// Not under `/Applications`: the daemon's executable would sit somewhere a non-admin user (or
    /// malware running as them) can write.
    case notInApplications

    /// - Parameters:
    ///   - bundlePath: `Bundle.main.bundleURL.path`.
    ///   - requireSystemApplications: whether to insist on `/Applications` (true for a release
    ///     build; a debug build running from DerivedData passes false).
    public static func detect(bundlePath: String, requireSystemApplications: Bool = false) -> InstallLocationProblem? {
        // Checked first: a translocated path lives under /private/var/folders, never /Volumes, but
        // keeping the more specific signal first means a future path that somehow matched both
        // would still report the more actionable one.
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .mountedVolume }
        if requireSystemApplications && !isInSystemApplications(bundlePath) { return .notInApplications }
        return nil
    }

    /// `/Applications/Zarp.app` and `/Applications/Utilities/Zarp.app` qualify; `/Applications`
    /// itself and anything that merely starts with the same letters (`/ApplicationsFake/...`) don't.
    private static func isInSystemApplications(_ path: String) -> Bool {
        let standardized = NSString(string: path).standardizingPath
        return standardized.hasPrefix("/Applications/") && standardized.count > "/Applications/".count
    }
}
