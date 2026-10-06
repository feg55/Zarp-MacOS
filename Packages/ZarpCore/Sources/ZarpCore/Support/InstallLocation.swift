import Foundation

/// A place the app can be running from where registering the `zarpd` LaunchDaemon would quietly
/// produce a daemon that stops working. `SMAppService.daemon`'s plist uses `BundleProgram`, a path
/// *relative to the app bundle*, so launchd re-resolves it against wherever the bundle was when
/// `register()` ran — and both of these locations go away:
///
/// - A `.dmg` double-clicked and opened in place (or an app on any other mounted volume) vanishes
///   when the image is ejected, taking the daemon's executable with it.
/// - A quarantined app launched from where it was downloaded (Downloads, Desktop) instead of being
///   moved first is run by Gatekeeper from a randomized, read-only "App Translocation" copy that is
///   discarded afterwards.
///
/// Everything else — `/Applications`, `~/Applications`, a development build in DerivedData — is
/// deliberately *not* a problem here: this only blocks the two known-broken cases, it doesn't
/// insist on one canonical install folder.
public enum InstallLocationProblem: Equatable, Sendable {
    case mountedVolume
    case translocated

    /// - Parameter bundlePath: `Bundle.main.bundleURL.path`.
    public static func detect(bundlePath: String) -> InstallLocationProblem? {
        // Checked first: a translocated path lives under /private/var/folders, never /Volumes, but
        // keeping the more specific signal first means a future path that somehow matched both
        // would still report the more actionable one.
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .mountedVolume }
        return nil
    }
}
