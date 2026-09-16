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
            XCTAssertEqual(
                presentation.accessibilityValue(locale: english),
                "iCloud not available"
            )
        }

        func testIdleReportsWaiting() {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: .idle
            )

            XCTAssertEqual(presentation.phase, .idle)
            XCTAssertEqual(
                presentation.accessibilityValue(locale: english),
                "Waiting to sync"
            )
        }

        func testConnectingReportsConnecting() {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: .connecting
            )

            XCTAssertEqual(presentation.phase, .connecting)
            XCTAssertEqual(
                presentation.accessibilityValue(locale: english),
                "Connecting"
            )
        }

        func testEveryWorkingActivityReportsItsExactDescription() {
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
                XCTAssertEqual(
                    presentation.accessibilityValue(locale: english),
                    activity.statusDescription
                )
            }
        }

        func testRecentSuccessReportsJustNow() {
            let now = Date(timeIntervalSince1970: 10000)
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: true,
                status: .synced(lastSync: now.addingTimeInterval(-59))
            )

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

            XCTAssertEqual(
                presentation.accessibilityValue(now: now, locale: english),
                "Synced 2 minutes ago"
            )
        }

        /// The toolbar slot is occupied only by a failure the user may need to
        /// resolve. Work in flight is as ambient as a resting state, so
        /// connecting, syncing, idle, synced, off and unavailable stay hidden.
        func testOnlyFailedStatesOccupyTheToolbarSlot() {
            let visible: [(String, SyncEngine.SyncStatus?)] = [
                ("error", .error("Upload failed, retrying")),
                ("temporarilyUnavailable", .temporarilyUnavailable),
            ]
            for (name, status) in visible {
                let presentation = iOSSyncStatusPresentation(syncEnabled: true, status: status)
                XCTAssertTrue(presentation.isVisible, "\(name) should occupy the slot")
            }

            let hidden: [(String, SyncEngine.SyncStatus?)] = [
                ("idle", .idle),
                ("connecting", .connecting),
                ("syncing", .syncing(.uploading(.events(count: 3)))),
                ("synced", .synced(lastSync: Date())),
                ("unavailable", .unavailable),
            ]
            for (name, status) in hidden {
                let presentation = iOSSyncStatusPresentation(syncEnabled: true, status: status)
                XCTAssertFalse(presentation.isVisible, "\(name) should be hidden")
            }
        }

        /// A disabled sync setting hides the control regardless of any status
        /// a still-running coordinator reports.
        func testDisabledSyncHidesTheControl() {
            let presentation = iOSSyncStatusPresentation(
                syncEnabled: false,
                status: .syncing(.uploading(.events(count: 3)))
            )
            XCTAssertFalse(presentation.isVisible)
        }

        /// A suspended session drops the coordinator from the environment; the
        /// resulting nil status must not leave a stranded indicator behind.
        func testMissingCoordinatorHidesTheControl() {
            let presentation = iOSSyncStatusPresentation(syncEnabled: true, status: nil)
            XCTAssertFalse(presentation.isVisible)
        }

        func testFailureStatesExposeAnActionableReason() {
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

                XCTAssertEqual(
                    presentation.accessibilityValue(locale: english),
                    expectedValue
                )
            }
        }
    }

#endif
