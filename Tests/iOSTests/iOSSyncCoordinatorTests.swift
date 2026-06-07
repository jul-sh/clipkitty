#if ENABLE_ICLOUD_SYNC

    import ClipKittyAppleServices
    import ClipKittyRust
    @testable import ClipKittyiOS
    import SwiftUI
    import XCTest

    // MARK: - Spy Engine

    @MainActor
    private final class SpySyncEngine: SyncEngineProtocol {
        var onContentChanged: (() -> Void)?

        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0
        private(set) var prepareForSuspendCallCount = 0
        private(set) var handleRemoteNotificationCallCount = 0
        private(set) var runBackgroundSyncCycleCallCount = 0

        var stubbedStatus: SyncEngine.SyncStatus = .idle
        var stubbedBackgroundSyncResult: SyncEngine.BackgroundSyncResult = .completed
        var status: SyncEngine.SyncStatus { stubbedStatus }

        func start() { startCallCount += 1 }
        func stop() { stopCallCount += 1 }
        func prepareForSuspend() async { prepareForSuspendCallCount += 1 }
        func handleRemoteNotification() { handleRemoteNotificationCallCount += 1 }
        func runBackgroundSyncCycle() async -> SyncEngine.BackgroundSyncResult {
            runBackgroundSyncCycleCallCount += 1
            return stubbedBackgroundSyncResult
        }
    }

    private let sampleSyncingStatus = SyncEngine.SyncStatus.syncing(
        .applying(.incremental(records: .init(events: 2, snapshots: 1)))
    )

    // MARK: - Tests

    @MainActor
    final class iOSSyncCoordinatorTests: XCTestCase {
        private var tempDir: URL!
        private var store: ClipKittyRust.ClipboardStore!
        private var createdEngines: [SpySyncEngine]!

        override func setUp() {
            super.setUp()
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipkitty-sync-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dbPath = tempDir.appendingPathComponent("test.db").path
            store = try! ClipKittyRust.ClipboardStore(dbPath: dbPath)
            createdEngines = []
        }

        override func tearDown() {
            store = nil
            createdEngines = nil
            if let tempDir {
                try? FileManager.default.removeItem(at: tempDir)
            }
            tempDir = nil
            super.tearDown()
        }

        private func spyFactory() -> (ClipKittyRust.ClipboardStore) -> any SyncEngineProtocol {
            { [weak self] _ in
                let spy = SpySyncEngine()
                self?.createdEngines.append(spy)
                return spy
            }
        }

        private var latestEngine: SpySyncEngine? {
            createdEngines.last
        }

        // MARK: - Initialization

        func testInitDisabledCreatesNoEngine() {
            _ = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            XCTAssertTrue(createdEngines.isEmpty)
        }

        func testInitEnabledCreatesEngine() {
            _ = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            XCTAssertEqual(createdEngines.count, 1)
        }

        func testInitEnabledWiresOnContentChanged() {
            var callbackFired = false
            _ = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: { callbackFired = true },
                engineFactory: spyFactory()
            )
            latestEngine?.onContentChanged?()
            XCTAssertTrue(callbackFired)
        }

        func testInitEnabledDoesNotStartEngine() {
            _ = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            XCTAssertEqual(latestEngine?.startCallCount, 0)
        }

        // MARK: - Status

        func testStatusIdleWhenDisabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            XCTAssertEqual(coordinator.status, .idle)
        }

        func testStatusForwardsEngineStatusWhenEnabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            latestEngine?.stubbedStatus = sampleSyncingStatus
            XCTAssertEqual(coordinator.status, sampleSyncingStatus)
        }

        // MARK: - setSyncEnabled transitions

        func testEnableFromDisabledCreatesEngineAndStarts() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            XCTAssertTrue(createdEngines.isEmpty)

            coordinator.setSyncEnabled(true)

            XCTAssertEqual(createdEngines.count, 1)
            XCTAssertEqual(latestEngine?.startCallCount, 1)
        }

        func testEnableFromDisabledWiresOnContentChanged() {
            var callbackFired = false
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: { callbackFired = true },
                engineFactory: spyFactory()
            )

            coordinator.setSyncEnabled(true)
            latestEngine?.onContentChanged?()
            XCTAssertTrue(callbackFired)
        }

        func testEnableWhenAlreadyEnabledIsIdempotent() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            let engineCount = createdEngines.count

            coordinator.setSyncEnabled(true)

            XCTAssertEqual(createdEngines.count, engineCount, "Should not create a new engine")
        }

        func testDisableFromEnabledStopsEngine() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            let engine = latestEngine!

            coordinator.setSyncEnabled(false)

            XCTAssertEqual(engine.stopCallCount, 1)
        }

        func testDisableFromEnabledReturnsStatusToIdle() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            latestEngine?.stubbedStatus = sampleSyncingStatus

            coordinator.setSyncEnabled(false)

            XCTAssertEqual(coordinator.status, .idle)
        }

        func testDisableWhenAlreadyDisabledIsIdempotent() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.setSyncEnabled(false)

            XCTAssertTrue(createdEngines.isEmpty)
        }

        func testReEnableCreatesNewEngine() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            let firstEngine = latestEngine!

            coordinator.setSyncEnabled(false)
            coordinator.setSyncEnabled(true)

            XCTAssertEqual(createdEngines.count, 2)
            XCTAssertTrue(latestEngine !== firstEngine)
            XCTAssertEqual(latestEngine?.startCallCount, 1)
        }

        // MARK: - Scene phase handling

        func testActivePhaseStartsEngineWhenEnabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.handleScenePhaseChange(.active)

            XCTAssertEqual(latestEngine?.startCallCount, 1)
        }

        func testBackgroundPhaseStopsEngineWhenEnabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.handleScenePhaseChange(.background)

            XCTAssertEqual(latestEngine?.stopCallCount, 1)
        }

        func testInactivePhaseLeavesEngineRunningWhenEnabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.handleScenePhaseChange(.inactive)

            XCTAssertEqual(latestEngine?.stopCallCount, 0)
        }

        func testScenePhaseChangesAreNoOpWhenDisabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.handleScenePhaseChange(.active)
            coordinator.handleScenePhaseChange(.background)
            coordinator.handleScenePhaseChange(.inactive)

            XCTAssertTrue(createdEngines.isEmpty)
        }

        func testActiveBackgroundActiveRestartsEngine() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.handleScenePhaseChange(.active)
            coordinator.handleScenePhaseChange(.background)
            coordinator.handleScenePhaseChange(.active)

            XCTAssertEqual(latestEngine?.startCallCount, 2)
            XCTAssertEqual(latestEngine?.stopCallCount, 1)
        }

        func testPrepareForSuspensionAwaitsEngineWhenEnabled() async {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            await coordinator.prepareForSuspension()

            XCTAssertEqual(latestEngine?.prepareForSuspendCallCount, 1)
        }

        func testPrepareForSuspensionIsNoOpWhenDisabled() async {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            await coordinator.prepareForSuspension()

            XCTAssertTrue(createdEngines.isEmpty)
        }

        // MARK: - Remote notification

        func testRemoteNotificationForwardsWhenEnabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.handleRemoteNotification()

            XCTAssertEqual(latestEngine?.startCallCount, 1)
            XCTAssertEqual(latestEngine?.handleRemoteNotificationCallCount, 1)
        }

        func testRemoteNotificationIsNoOpWhenDisabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            coordinator.handleRemoteNotification()

            XCTAssertTrue(createdEngines.isEmpty)
        }

        func testPerformRemoteNotificationSyncRunsBackgroundCycleWhenEnabled() async {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            let result = await coordinator.performRemoteNotificationSync()

            XCTAssertEqual(result, .completed)
            XCTAssertEqual(latestEngine?.runBackgroundSyncCycleCallCount, 1)
        }

        func testPerformRemoteNotificationSyncReturnsUnavailableWhenDisabled() async {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory()
            )

            let result = await coordinator.performRemoteNotificationSync()

            XCTAssertEqual(result, .unavailable)
            XCTAssertTrue(createdEngines.isEmpty)
        }
    }

#endif
