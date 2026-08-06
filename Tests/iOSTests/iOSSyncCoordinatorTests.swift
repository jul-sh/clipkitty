#if ENABLE_ICLOUD_SYNC

    import ClipKittyCloudSync
    @testable import ClipKittyiOS
    import ClipKittyRust
    import SwiftUI
    import UIKit
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
        var prepareForSuspendHandler: (() async -> Void)?
        var status: SyncEngine.SyncStatus {
            stubbedStatus
        }

        func start() {
            startCallCount += 1
        }

        func stop() {
            stopCallCount += 1
        }

        func prepareForSuspend() async {
            prepareForSuspendCallCount += 1
            await prepareForSuspendHandler?()
        }

        func handleRemoteNotification() {
            handleRemoteNotificationCallCount += 1
        }

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
        private var scheduleBackgroundSyncCallCount: Int!

        override func setUp() {
            super.setUp()
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipkitty-sync-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dbPath = tempDir.appendingPathComponent("test.db").path
            store = try! ClipKittyRust.ClipboardStore(dbPath: dbPath)
            createdEngines = []
            scheduleBackgroundSyncCallCount = 0
        }

        override func tearDown() {
            store = nil
            createdEngines = nil
            scheduleBackgroundSyncCallCount = nil
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

        private func countBackgroundSchedule() {
            scheduleBackgroundSyncCallCount += 1
        }

        private func waitUntil(
            timeout: TimeInterval = 1.0,
            pollIntervalNanoseconds: UInt64 = 10_000_000,
            file: StaticString = #filePath,
            line: UInt = #line,
            condition: @escaping @MainActor () -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() {
                    return
                }
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
            XCTFail("Timed out waiting for condition", file: file, line: line)
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

        func testInitEnabledSchedulesBackgroundSync() {
            _ = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory(),
                scheduleBackgroundSync: countBackgroundSchedule
            )

            XCTAssertEqual(scheduleBackgroundSyncCallCount, 1)
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

        func testEnableFromDisabledSchedulesBackgroundSync() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: false,
                onContentChanged: {},
                engineFactory: spyFactory(),
                scheduleBackgroundSync: countBackgroundSchedule
            )

            coordinator.setSyncEnabled(true)

            XCTAssertEqual(scheduleBackgroundSyncCallCount, 1)
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

        func testDisableFromEnabledStopsEngine() throws {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            let engine = try XCTUnwrap(latestEngine)

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

        func testReEnableReusesTheStoppedEngine() throws {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            let firstEngine = try XCTUnwrap(latestEngine)

            coordinator.setSyncEnabled(false)
            coordinator.setSyncEnabled(true)

            XCTAssertEqual(createdEngines.count, 1)
            XCTAssertTrue(latestEngine === firstEngine)
            XCTAssertEqual(firstEngine.startCallCount, 1)
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

        func testBackgroundPhaseSchedulesBackgroundSyncWhenEnabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory(),
                scheduleBackgroundSync: countBackgroundSchedule
            )
            scheduleBackgroundSyncCallCount = 0

            coordinator.handleScenePhaseChange(.background)

            XCTAssertEqual(scheduleBackgroundSyncCallCount, 1)
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
                engineFactory: spyFactory(),
                scheduleBackgroundSync: countBackgroundSchedule
            )
            scheduleBackgroundSyncCallCount = 0

            await coordinator.prepareForSuspension()

            XCTAssertEqual(latestEngine?.prepareForSuspendCallCount, 1)
            XCTAssertEqual(scheduleBackgroundSyncCallCount, 1)
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

        func testPrepareForSuspensionJoinsAnEngineStoppedByTheSetting() async throws {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory()
            )
            let engine = try XCTUnwrap(latestEngine)
            coordinator.setSyncEnabled(false)

            await coordinator.prepareForSuspension()

            XCTAssertEqual(engine.stopCallCount, 1)
            XCTAssertEqual(engine.prepareForSuspendCallCount, 1)
        }

        func testSuspensionIsTerminalAndRepeatedPreparationIsIdempotent() async throws {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory(),
                scheduleBackgroundSync: countBackgroundSchedule
            )
            let engine = try XCTUnwrap(latestEngine)

            await coordinator.prepareForSuspension()
            let scheduledAtSuspension = scheduleBackgroundSyncCallCount

            coordinator.setSyncEnabled(false)
            coordinator.setSyncEnabled(true)
            coordinator.handleScenePhaseChange(.active)
            coordinator.handleRemoteNotification()
            let notificationResult = await coordinator.performRemoteNotificationSync()
            await coordinator.prepareForSuspension()

            XCTAssertEqual(notificationResult, .unavailable)
            XCTAssertEqual(engine.prepareForSuspendCallCount, 1)
            XCTAssertEqual(engine.startCallCount, 0)
            XCTAssertEqual(engine.handleRemoteNotificationCallCount, 0)
            XCTAssertEqual(engine.runBackgroundSyncCycleCallCount, 0)
            XCTAssertEqual(scheduleBackgroundSyncCallCount, scheduledAtSuspension)
            XCTAssertEqual(createdEngines.count, 1)
        }

        func testSuspendingStateRejectsLateWorkAndJoinsTheSameDrain() async throws {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory(),
                scheduleBackgroundSync: countBackgroundSchedule
            )
            let engine = try XCTUnwrap(latestEngine)
            var releasePreparation: CheckedContinuation<Void, Never>?
            engine.prepareForSuspendHandler = {
                await withCheckedContinuation { continuation in
                    releasePreparation = continuation
                }
            }

            let firstPreparation = Task { @MainActor in
                await coordinator.prepareForSuspension()
            }
            await waitUntil { engine.prepareForSuspendCallCount == 1 }

            coordinator.setSyncEnabled(false)
            coordinator.handleScenePhaseChange(.active)
            coordinator.handleRemoteNotification()
            let notificationResult = await coordinator.performRemoteNotificationSync()
            let secondPreparation = Task { @MainActor in
                await coordinator.prepareForSuspension()
            }

            XCTAssertEqual(notificationResult, .unavailable)
            XCTAssertEqual(engine.startCallCount, 0)
            XCTAssertEqual(engine.handleRemoteNotificationCallCount, 0)
            XCTAssertEqual(engine.runBackgroundSyncCycleCallCount, 0)
            XCTAssertEqual(engine.prepareForSuspendCallCount, 1)

            releasePreparation?.resume()
            await firstPreparation.value
            await secondPreparation.value
            XCTAssertEqual(engine.prepareForSuspendCallCount, 1)
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

        func testRemoteNotificationSchedulesBackgroundSyncWhenEnabled() {
            let coordinator = iOSSyncCoordinator(
                store: store,
                enabled: true,
                onContentChanged: {},
                engineFactory: spyFactory(),
                scheduleBackgroundSync: countBackgroundSchedule
            )
            scheduleBackgroundSyncCallCount = 0

            coordinator.handleRemoteNotification()

            XCTAssertEqual(scheduleBackgroundSyncCallCount, 1)
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

        // MARK: - Background runner cancellation

        func testForegroundStoreClaimRejectsHeadlessOpenUntilReleased() async {
            var startCount = 0
            let runner = iOSBackgroundSyncRunner {
                startCount += 1
                return .newData
            }
            let claimID = UUID()

            runner.claimForegroundStore(claimID)
            let rejected = await runner.performScheduledSync()
            XCTAssertEqual(rejected, .failed)
            XCTAssertEqual(startCount, 0)

            runner.releaseForegroundStore(claimID)
            let admitted = await runner.performScheduledSync()
            XCTAssertEqual(admitted, .newData)
            XCTAssertEqual(startCount, 1)
        }

        func testCancelInFlightSyncKeepsLaterWakeJoinedUntilOperationFinishes() async {
            var startCount = 0
            var allowFinish = false
            let runner = iOSBackgroundSyncRunner {
                startCount += 1
                while !allowFinish {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return Task.isCancelled ? .failed : .newData
            }

            let firstWake = Task { @MainActor in
                await runner.performScheduledSync()
            }
            await waitUntil {
                startCount == 1
            }

            runner.cancelInFlightSync()
            let secondWake = Task { @MainActor in
                await runner.performRemoteNotificationSync()
            }
            try? await Task.sleep(nanoseconds: 50_000_000)

            XCTAssertEqual(startCount, 1)
            allowFinish = true

            let firstResult = await firstWake.value
            let secondResult = await secondWake.value
            XCTAssertEqual(firstResult, .failed)
            XCTAssertEqual(secondResult, .failed)
            XCTAssertEqual(startCount, 1)
        }
    }

#endif
