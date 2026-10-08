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

    // MARK: - Release builds: the daemon runs as root, so where it lives matters

    func testReleaseBuildsOnlyRegisterTheDaemonFromTheSystemApplicationsFolder() {
        func detect(_ path: String) -> InstallLocationProblem? {
            InstallLocationProblem.detect(bundlePath: path, requireSystemApplications: true)
        }
        XCTAssertNil(detect("/Applications/Zarp.app"))
        XCTAssertNil(detect("/Applications/Utilities/Zarp.app"))
        // Folders the logged-in user owns: a root process must not run an executable they can replace.
        XCTAssertEqual(detect("/Users/someone/Applications/Zarp.app"), .notInApplications)
        XCTAssertEqual(detect("/Users/someone/Downloads/Zarp.app"), .notInApplications)
        XCTAssertEqual(detect("/Users/someone/Library/Developer/Xcode/DerivedData/Zarp-abc/Build/Products/Release/Zarp.app"), .notInApplications)
        XCTAssertEqual(detect("/tmp/Zarp.app"), .notInApplications)
    }

    func testLookalikeAndTraversalPathsAreNotTheApplicationsFolder() {
        func detect(_ path: String) -> InstallLocationProblem? {
            InstallLocationProblem.detect(bundlePath: path, requireSystemApplications: true)
        }
        XCTAssertEqual(detect("/ApplicationsFake/Zarp.app"), .notInApplications)
        XCTAssertEqual(detect("/Applications"), .notInApplications)
        XCTAssertEqual(detect("/Applications/"), .notInApplications)
        XCTAssertEqual(detect("/Applications/../Users/someone/Zarp.app"), .notInApplications, "a .. must not smuggle a path in")
        XCTAssertEqual(detect("/Users/someone/Applications/../../../../Applications/../tmp/Zarp.app"), .notInApplications)
    }

    func testTheMoreSpecificProblemWinsInAReleaseBuild() {
        XCTAssertEqual(InstallLocationProblem.detect(bundlePath: "/Volumes/Zarp/Zarp.app", requireSystemApplications: true), .mountedVolume)
        XCTAssertEqual(InstallLocationProblem.detect(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Zarp.app", requireSystemApplications: true), .translocated)
    }

    func testDevelopmentBuildsAreNotAffectedByTheNewRule() {
        // The default keeps the Phase 8 workflow (register from DerivedData) working.
        XCTAssertNil(InstallLocationProblem.detect(bundlePath: "/Users/someone/Library/Developer/Xcode/DerivedData/Zarp/Build/Products/Debug/Zarp.app"))
    }
}
