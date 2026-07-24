@testable import ClipKitty
import XCTest

@MainActor
final class AppStateOwnershipTests: XCTestCase {
    func testLifecycleStatePersistsLifecycleFactsWithoutSettingsSerializer() throws {
        let defaults = try isolatedDefaults()
        let firstLaunch = Date(timeIntervalSince1970: 1_700_000_000)
        let state = AppLifecycleState(defaults: defaults, now: { firstLaunch })

        XCTAssertEqual(state.firstLaunchDate, firstLaunch)
        XCTAssertEqual(defaults.object(forKey: "firstLaunchDate") as? Date, firstLaunch)

        let infoDismissal = firstLaunch.addingTimeInterval(60)
        let nudgeInteraction = firstLaunch.addingTimeInterval(120)
        state.launchAtLoginPromptDismissed = true
        state.lastInfoDismissDate = infoDismissal
        state.lastNudgeInteractionDate = nudgeInteraction
        state.hasCompletedOnboarding = true

        let restored = AppLifecycleState(defaults: defaults, now: {
            XCTFail("A persisted first-launch date must be reused")
            return .distantFuture
        })
        XCTAssertTrue(restored.launchAtLoginPromptDismissed)
        XCTAssertEqual(restored.lastInfoDismissDate, infoDismissal)
        XCTAssertEqual(restored.lastNudgeInteractionDate, nudgeInteraction)
        XCTAssertTrue(restored.hasCompletedOnboarding)
        XCTAssertEqual(restored.firstLaunchDate, firstLaunch)
    }

    func testRuntimeTextScaleIsDerivedAndNeverPersistedByRuntimeState() throws {
        let defaults = try isolatedDefaults()
        defaults.set("UICTContentSizeCategoryXXL", forKey: "UIPreferredContentSizeCategoryName")

        let runtime = AppRuntimeState(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(runtime.textScale, 1.24, accuracy: 0.001)
        XCTAssertEqual(runtime.scaled(10), 12.4, accuracy: 0.001)
        XCTAssertNil(defaults.object(forKey: "textScale"))
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "AppStateOwnershipTests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }
}
