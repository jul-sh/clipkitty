@testable import ClipKittyiOS
import XCTest

@MainActor
final class iOSLifecycleStateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "iOSLifecycleStateTests")!
        defaults.removePersistentDomain(forName: "iOSLifecycleStateTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "iOSLifecycleStateTests")
        defaults = nil
        super.tearDown()
    }

    /// A fresh install must land in onboarding, so the flag defaults to false.
    func testOnboardingIsIncompleteOnFirstLaunch() {
        let state = iOSLifecycleState(defaults: defaults)
        XCTAssertFalse(state.hasCompletedOnboarding)
    }

    /// Onboarding is shown once. The flag has to outlive the process because
    /// backgrounding tears the container down and rebootstraps on foreground.
    func testCompletedOnboardingPersists() {
        let state = iOSLifecycleState(defaults: defaults)
        state.hasCompletedOnboarding = true

        let reloaded = iOSLifecycleState(defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
    }
}
