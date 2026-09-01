#if ENABLE_ICLOUD_SYNC

    import ClipKittyCloudSync
    @testable import ClipKittyiOS
    import Foundation
    import XCTest

    final class iOSSyncStatusButtonTests: XCTestCase {
        private let english = Locale(identifier: "en_US")

        func testDisabledSettingWinsOverAWorkingCoordinatorStatus() {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: false,
                status: .syncing(.uploading(.events(count: 3)))
            )

            XCTAssertEqual(presentation.phase, .off)
            XCTAssertFalse(presentation.isAnimating)
            XCTAssertEqual(
                presentation.accessibilityValue(locale: english),
                "Sync is off"
            )
        }

        func testMissingCoordinatorIsUnavailableWhenSettingIsEnabled() {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: nil
            )

            XCTAssertEqual(presentation.phase, .unavailable)
            XCTAssertFalse(presentation.isAnimating)
            XCTAssertEqual(
                presentation.accessibilityValue(locale: english),
                "iCloud not available"
            )
        }

        func testIdleIsStaticAndReportsWaiting() {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: .idle
            )

            XCTAssertEqual(presentation.phase, .idle)
            XCTAssertFalse(presentation.isAnimating)
            XCTAssertEqual(
                presentation.accessibilityValue(locale: english),
                "Waiting to sync"
            )
        }

        func testConnectingAnimatesAndReportsConnecting() {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: .connecting
            )

            XCTAssertEqual(presentation.phase, .connecting)
            XCTAssertTrue(presentation.isAnimating)
            XCTAssertEqual(
                presentation.accessibilityValue(locale: english),
                "Connecting"
            )
        }

        func testEveryWorkingActivityAnimatesAndReportsItsExactDescription() {
            let records = SyncEngine.SyncRecordCounts(events: 2, snapshots: 1)
            let activities: [SyncEngine.SyncActivity] = [
                .downloading(.incremental(records: records)),
                .applying(.fullResync(records: records)),
                .rebuildingIndex(.localMaintenance),
                .compacting,
                .uploading(.snapshots(count: 4)),
                .cleaningUp(count: 5),
            ]

            for activity in activities {
                let presentation = iOSSyncStatusPresentation(
                    syncEnabled: true,
                    status: .syncing(activity)
                )

                XCTAssertEqual(presentation.phase, .syncing(activity))
                XCTAssertTrue(presentation.isAnimating)
                XCTAssertEqual(
                    presentation.accessibilityValue(locale: english),
                    activity.statusDescription
                )
            }
        }

        func testRecentSuccessIsStaticAndReportsJustNow() {
            let now = Date(timeIntervalSince1970: 10000)
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: .synced(lastSync: now.addingTimeInterval(-59))
            )

            XCTAssertFalse(presentation.isAnimating)
            XCTAssertEqual(
                presentation.accessibilityValue(now: now, locale: english),
                "Synced just now"
            )
        }

        func testOlderSuccessIncludesLocalizedRelativeTime() {
            let now = Date(timeIntervalSince1970: 10000)
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: .synced(lastSync: now.addingTimeInterval(-120))
            )

            XCTAssertFalse(presentation.isAnimating)
            XCTAssertEqual(
                presentation.accessibilityValue(now: now, locale: english),
                "Synced 2 minutes ago"
            )
        }

        func testFailureStatesAreStaticAndExposeAnActionableReason() {
            let cases: [(SyncEngine.SyncStatus, String)] = [
                (.error("Upload failed, retrying"), "Upload failed, retrying"),
                (.error("  \n"), "Sync failed"),
                (.temporarilyUnavailable, "iCloud temporarily unavailable"),
                (.unavailable, "iCloud not available"),
            ]

            for (status, expectedValue) in cases {
                let presentation = iOSSyncStatusPresentation(
                    syncEnabled: true,
                    status: status
                )

                XCTAssertFalse(presentation.isAnimating)
                XCTAssertEqual(
                    presentation.accessibilityValue(locale: english),
                    expectedValue
                )
            }
        }
    }

#endif
