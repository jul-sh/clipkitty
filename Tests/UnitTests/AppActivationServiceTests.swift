@testable import ClipKittyMacPlatform
import XCTest

@MainActor
final class AppActivationServiceTests: XCTestCase {
    func testSyntheticPasteFallsBackToCopyOnlyWithoutTargetApp() {
        let service = AppActivationService(workspace: MockWorkspace())

        switch service.syntheticPasteBehavior(for: nil) {
        case .copyOnly:
            break
        case .paste:
            XCTFail("Expected nil target app to disable synthetic paste")
        }
    }

    func testDetectsRoyalTSXBundleIdentifier() {
        XCTAssertEqual(
            RemoteDesktopApp.detect(bundleIdentifier: "com.lemonmojo.RoyalTSX.App", localizedName: nil),
            .royalTSX
        )
    }

    func testDetectsRoyalTSXByLocalizedName() {
        XCTAssertEqual(
            RemoteDesktopApp.detect(bundleIdentifier: "com.example.remote", localizedName: "Royal TSX"),
            .royalTSX
        )
    }

    func testDetectsMicrosoftRemoteDesktopBundleIdentifier() {
        XCTAssertEqual(
            RemoteDesktopApp.detect(bundleIdentifier: "com.microsoft.rdc.macos", localizedName: nil),
            .microsoftRemoteDesktop
        )
    }

    func testDetectsWindowsAppByLocalizedName() {
        XCTAssertEqual(
            RemoteDesktopApp.detect(bundleIdentifier: "com.example.remote", localizedName: "Windows App"),
            .microsoftRemoteDesktop
        )
    }

    func testLeavesRegularAppsEligibleForSyntheticPaste() {
        XCTAssertNil(
            RemoteDesktopApp.detect(bundleIdentifier: "com.microsoft.VSCode", localizedName: "Visual Studio Code")
        )
    }
}
