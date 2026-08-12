@testable import ClipKitty
@testable import ClipKittyMacPlatform
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

    func testPasteModePreservesUserIntentAndEffectivePermissionState() {
        XCTAssertEqual(
            PasteMode(autoPasteEnabled: false, permissionStatus: .requiresRepair),
            .copyOnly
        )
        XCTAssertEqual(
            PasteMode(autoPasteEnabled: true, permissionStatus: .granted),
            .autoPaste
        )
        XCTAssertEqual(
            PasteMode(autoPasteEnabled: true, permissionStatus: .notGranted),
            .unavailable(.permissionNotGranted)
        )
        XCTAssertEqual(
            PasteMode(autoPasteEnabled: true, permissionStatus: .requiresRepair),
            .unavailable(.permissionRequiresRepair)
        )
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "AppStateOwnershipTests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }
}

@MainActor
final class AccessibilityPermissionMonitorTests: XCTestCase {
    func testPermissionStatusRequiresBothAccessibilityTrustAndEventPostingAccess() {
        let cases: [(trusted: Bool, canPost: Bool, expected: AccessibilityPermissionStatus)] = [
            (false, false, .notGranted),
            (true, true, .granted),
            (true, false, .requiresRepair),
            (false, true, .requiresRepair),
        ]

        for testCase in cases {
            let state = PermissionClientState(
                isAccessibilityTrusted: testCase.trusted,
                canPostEvents: testCase.canPost
            )

            XCTAssertEqual(makeMonitor(state: state).status, testCase.expected)
        }
    }

    func testRefreshDetectsAStaleGrant() {
        let state = PermissionClientState(isAccessibilityTrusted: true, canPostEvents: true)
        let monitor = makeMonitor(state: state)
        XCTAssertEqual(monitor.status, .granted)

        state.canPostEvents = false
        monitor.refresh()

        XCTAssertEqual(monitor.status, .requiresRepair)
    }

    func testPermissionRequestUsesEventPostingRequestAndRefreshesStatus() {
        let state = PermissionClientState(isAccessibilityTrusted: false, canPostEvents: false)
        state.requestResult = true
        state.onRequest = {
            state.isAccessibilityTrusted = true
            state.canPostEvents = true
        }
        let monitor = makeMonitor(state: state)

        XCTAssertTrue(monitor.requestPermission())
        XCTAssertEqual(state.requestCount, 1)
        XCTAssertEqual(monitor.status, .granted)
    }

    private func makeMonitor(state: PermissionClientState) -> AccessibilityPermissionMonitor {
        AccessibilityPermissionMonitor(client: AccessibilityPermissionClient(
            isAccessibilityTrusted: { state.isAccessibilityTrusted },
            canPostEvents: { state.canPostEvents },
            requestPostEventAccess: {
                state.requestCount += 1
                state.onRequest?()
                return state.requestResult
            }
        ))
    }
}

@MainActor
private final class PermissionClientState {
    var isAccessibilityTrusted: Bool
    var canPostEvents: Bool
    var requestResult = false
    var requestCount = 0
    var onRequest: (() -> Void)?

    init(isAccessibilityTrusted: Bool, canPostEvents: Bool) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.canPostEvents = canPostEvents
    }
}
