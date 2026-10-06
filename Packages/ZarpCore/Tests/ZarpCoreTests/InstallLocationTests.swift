import XCTest
@testable import ZarpCore

final class InstallLocationTests: XCTestCase {
    func testOrdinaryInstallLocationsAreFine() {
        XCTAssertNil(InstallLocationProblem.detect(bundlePath: "/Applications/Zarp.app"))
        XCTAssertNil(InstallLocationProblem.detect(bundlePath: "/Users/someone/Applications/Zarp.app"))
        // A development build — the daemon registration workflow this project itself used for all of
        // Phase 8 — must keep working, so DerivedData is not flagged.
        XCTAssertNil(InstallLocationProblem.detect(
            bundlePath: "/Users/someone/Library/Developer/Xcode/DerivedData/Zarp-abc/Build/Products/Debug/Zarp.app"))
    }

    func testAppOpenedInPlaceFromADiskImageIsFlagged() {
        XCTAssertEqual(InstallLocationProblem.detect(bundlePath: "/Volumes/Zarp/Zarp.app"), .mountedVolume)
        // macOS names a second simultaneous mount of the same volume "Zarp 1".
        XCTAssertEqual(InstallLocationProblem.detect(bundlePath: "/Volumes/Zarp 1/Zarp.app"), .mountedVolume)
    }

    func testAppTranslocationPathIsFlagged() {
        XCTAssertEqual(
            InstallLocationProblem.detect(
                bundlePath: "/private/var/folders/jp/0kssyvp56ds2ddf4kc9j961r0000gn/T/AppTranslocation/8F2B1C3E/d/Zarp.app"),
            .translocated)
    }

    func testVolumesAnywhereButTheStartOfThePathIsNotMistakenForAMountedVolume() {
        // A prefix match, not a substring one: a user folder that merely contains "Volumes".
        XCTAssertNil(InstallLocationProblem.detect(bundlePath: "/Users/someone/Volumes/Zarp.app"))
    }
}
