@testable import ClipKittyiOS
import ClipKittyRust
import UIKit
import XCTest

@MainActor
private final class AppBackgroundTaskClientProbe {
    enum BeginBehavior {
        case returnIdentifier(UIBackgroundTaskIdentifier)
        case expireThenReturn(UIBackgroundTaskIdentifier)
    }

    enum Event: Equatable {
        case cleanup
        case ended(UIBackgroundTaskIdentifier)
    }

    private let beginBehavior: BeginBehavior
    private var expirationHandler: (@MainActor @Sendable () -> Void)?
    private(set) var events: [Event] = []

    init(beginBehavior: BeginBehavior) {
        self.beginBehavior = beginBehavior
    }

    func makeClient() -> AppBackgroundTaskClient {
        AppBackgroundTaskClient(
            begin: { [self] _, expirationHandler in
                self.expirationHandler = expirationHandler
                switch beginBehavior {
                case let .returnIdentifier(identifier):
                    return identifier
                case let .expireThenReturn(identifier):
                    expirationHandler()
                    return identifier
                }
            },
            end: { [self] identifier in
                events.append(.ended(identifier))
            }
        )
    }

    func recordCleanup() {
        events.append(.cleanup)
    }

    func expire() {
        guard let expirationHandler else {
            XCTFail("Expected the client to retain an expiration handler")
            return
        }
        expirationHandler()
    }
}

private final class AppBackgroundTaskCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func recordedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
final class AppContainerBootstrapTests: TemporaryDirectoryTestCase {
    func testBackgroundCancellationBeforeInstallationRunsInstalledActionOnce() {
        let cancellation = AppBackgroundTaskCancellation()
        let probe = AppBackgroundTaskCancellationProbe()

        cancellation.cancel()
        cancellation.install { probe.record() }
        cancellation.cancel()

        XCTAssertEqual(probe.recordedCount(), 1)
    }

    func testBackgroundCancellationAfterInstallationRunsActionOnce() {
        let cancellation = AppBackgroundTaskCancellation()
        let probe = AppBackgroundTaskCancellationProbe()

        cancellation.install { probe.record() }
        cancellation.cancel()
        cancellation.cancel()

        XCTAssertEqual(probe.recordedCount(), 1)
    }

    func testCompletedBackgroundCancellationDropsInstalledAction() {
        let cancellation = AppBackgroundTaskCancellation()
        let probe = AppBackgroundTaskCancellationProbe()

        cancellation.install { probe.record() }
        cancellation.complete()
        cancellation.cancel()

        XCTAssertEqual(probe.recordedCount(), 0)
    }

    func testBackgroundTaskReservationIsUnavailableForInvalidIdentifier() {
        let probe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(.invalid)
        )

        let reservation = AppBackgroundTaskLease.acquire(
            named: "invalid-reservation",
            client: probe.makeClient(),
            onExpiration: { probe.recordCleanup() }
        )

        switch reservation {
        case .granted:
            XCTFail("An invalid UIKit identifier must not grant background protection")
        case .unavailable:
            break
        }
        XCTAssertEqual(probe.events, [])
    }

    func testExpirationDuringReservationCleansOnceAndEndsReturnedIdentifier() {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 41)
        let probe = AppBackgroundTaskClientProbe(
            beginBehavior: .expireThenReturn(identifier)
        )

        let reservation = AppBackgroundTaskLease.acquire(
            named: "synchronous-expiration",
            client: probe.makeClient(),
            onExpiration: { probe.recordCleanup() }
        )

        switch reservation {
        case .granted:
            XCTFail("A reservation that expired during begin must not be granted")
        case .unavailable:
            break
        }
        XCTAssertEqual(probe.events, [.cleanup, .ended(identifier)])
    }

    func testGrantedBackgroundTaskExpirationCleansBeforeEndingLease() {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
        let probe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(identifier)
        )

        let reservation = AppBackgroundTaskLease.acquire(
            named: "granted-expiration",
            client: probe.makeClient(),
            onExpiration: { probe.recordCleanup() }
        )
        let lease: AppBackgroundTaskLease
        switch reservation {
        case let .granted(grantedLease):
            lease = grantedLease
        case .unavailable:
            return XCTFail("Expected a valid UIKit identifier to grant a lease")
        }

        probe.expire()
        lease.end()

        XCTAssertEqual(probe.events, [.cleanup, .ended(identifier)])
    }

    func testDroppingGrantedBackgroundTaskLeaseEndsReservationExactlyOnce() {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 43)
        let probe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(identifier)
        )
        var lease: AppBackgroundTaskLease?

        switch AppBackgroundTaskLease.acquire(
            named: "abandoned-reservation",
            client: probe.makeClient(),
            onExpiration: { probe.recordCleanup() }
        ) {
        case let .granted(grantedLease):
            lease = grantedLease
        case .unavailable:
            return XCTFail("Expected a valid UIKit identifier to grant a lease")
        }

        weak let weakLease = lease
        lease = nil

        XCTAssertNil(weakLease)
        XCTAssertEqual(probe.events, [.ended(identifier)])
    }

    func testForegroundTaskIsCancelledAndJoinedByAppStateSuspension() async {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("foreground-task-suspension.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let taskID = UUID()
        let foregroundTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Cancellation is the expected terminal path.
            }
        }
        XCTAssertTrue(appState.registerForegroundTask(id: taskID, task: foregroundTask))

        let suspension = appState.prepareForSuspension()
        guard case let .awaiting(join) = suspension else {
            return XCTFail("The registered foreground task must make suspension joinable")
        }
        await join.value

        XCTAssertTrue(foregroundTask.isCancelled)
        var rejectedTaskStartedStoreWork = false
        let rejectedTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            rejectedTaskStartedStoreWork = true
        }
        XCTAssertFalse(appState.registerForegroundTask(id: UUID(), task: rejectedTask))
        await rejectedTask.value
        XCTAssertTrue(rejectedTask.isCancelled)
        XCTAssertFalse(rejectedTaskStartedStoreWork)
    }

    func testCancelledForegroundTaskCanReconcileCommittedWriteDuringSuspension() async {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("committed-write-reconciliation.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let taskID = UUID()
        let foregroundTask = Task { @MainActor in
            defer { appState.finishForegroundTask(id: taskID) }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Model an admitted repository operation that reports its
                // committed success only after terminal cancellation.
            }
            appState.refreshFeed()
        }
        XCTAssertTrue(appState.registerForegroundTask(id: taskID, task: foregroundTask))

        let suspension = appState.prepareForSuspension()
        guard case let .awaiting(join) = suspension else {
            return XCTFail("Committed foreground work must remain joinable")
        }
        await join.value

        XCTAssertTrue(foregroundTask.isCancelled)
        XCTAssertEqual(appState.contentRevision, 1)
        guard case .idle = appState.viewModel.contentState else {
            return XCTFail("Reconciliation must not start browser work on the outgoing session")
        }
    }

    func testRefreshAfterSuspensionDefersBrowserWorkButPreservesRevision() {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("deferred-background-refresh.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)

        _ = appState.prepareForSuspension()
        appState.refreshFeed()

        XCTAssertEqual(appState.contentRevision, 1)
        guard case .idle = appState.viewModel.contentState else {
            return XCTFail("A suspended refresh must not start BrowserViewModel work")
        }
    }

    func testImageDescriptionWorkerProcessesCommittedImagesSeriallyInFIFOOrder() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("serial-image-description-worker.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let firstStarted = expectation(description: "first image description started")
        let secondStarted = expectation(description: "second image description started")
        let firstRelease = AppSessionWorkCompletion()
        let secondRelease = AppSessionWorkCompletion()
        var startedItemIDs: [String] = []
        var activeUpdateCount = 0
        var maximumActiveUpdateCount = 0
        let appState = AppState(
            container: container,
            imageDescriptionUpdate: { itemID in
                let index = startedItemIDs.count
                startedItemIDs.append(itemID)
                activeUpdateCount += 1
                maximumActiveUpdateCount = max(
                    maximumActiveUpdateCount,
                    activeUpdateCount
                )
                if index == 0 {
                    firstStarted.fulfill()
                    await firstRelease.wait()
                } else {
                    secondStarted.fulfill()
                    await secondRelease.wait()
                }
                activeUpdateCount -= 1
                return .success(true)
            }
        )

        let firstItemID = try await appState.saveImage(
            imageData: Data([0x01]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        ).get()
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondItemID = try await appState.saveImage(
            imageData: Data([0x02]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        ).get()

        XCTAssertEqual(startedItemIDs, [firstItemID])
        XCTAssertEqual(maximumActiveUpdateCount, 1)
        firstRelease.finish()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(startedItemIDs, [firstItemID, secondItemID])
        XCTAssertEqual(maximumActiveUpdateCount, 1)

        secondRelease.finish()
        await eventually { appState.contentRevision == 2 }
        XCTAssertEqual(activeUpdateCount, 0)
    }

    func testImageDescriptionWorkerSuspensionDropsQueueAndReconcilesCurrentCommit() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("suspended-image-description-worker.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let firstStarted = expectation(description: "image description started")
        var startedItemIDs: [String] = []
        var observedCancellation = false
        let appState = AppState(
            container: container,
            imageDescriptionUpdate: { itemID in
                startedItemIDs.append(itemID)
                if startedItemIDs.count == 1 {
                    firstStarted.fulfill()
                }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    observedCancellation = Task.isCancelled
                }
                // Model a repository description mutation that committed just
                // before cancellation became observable to its caller.
                return .success(true)
            }
        )

        let firstItemID = try await appState.saveImage(
            imageData: Data([0x01]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        ).get()
        await fulfillment(of: [firstStarted], timeout: 2)
        _ = try await appState.saveImage(
            imageData: Data([0x02]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        ).get()
        XCTAssertEqual(startedItemIDs, [firstItemID])

        guard case let .awaiting(join) = appState.prepareForSuspension() else {
            return XCTFail("The serial image description worker must be joined")
        }
        await join.value

        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(startedItemIDs, [firstItemID])
        XCTAssertEqual(appState.contentRevision, 1)
        guard case .idle = appState.viewModel.contentState else {
            return XCTFail("A suspended description commit must not start browser work")
        }
    }

    func testExternalTransferLeaseKeepsSuspensionPendingUntilTransferFinishes() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("external-transfer-suspension.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(UIBackgroundTaskIdentifier(rawValue: 51))
        )
        let lease = try XCTUnwrap(appState.beginExternalTransfer(
            backgroundTaskClient: backgroundProbe.makeClient()
        ))
        lease.installExpirationHandler {}

        guard case let .awaiting(join) = appState.prepareForSuspension() else {
            return XCTFail("An external transfer must be joined before suspension")
        }
        var didJoin = false
        let observer = Task { @MainActor in
            await join.value
            didJoin = true
        }
        await Task.yield()
        XCTAssertFalse(didJoin)

        lease.finish()
        await observer.value

        XCTAssertTrue(didJoin)
        XCTAssertEqual(
            backgroundProbe.events,
            [.ended(UIBackgroundTaskIdentifier(rawValue: 51))]
        )
    }

    func testExternalTransferBackgroundExpirationCancelsAndReleasesSuspension() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("expired-external-transfer.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(UIBackgroundTaskIdentifier(rawValue: 52))
        )
        let cancellationProbe = AppBackgroundTaskCancellationProbe()
        let lease = try XCTUnwrap(appState.beginExternalTransfer(
            backgroundTaskClient: backgroundProbe.makeClient()
        ))
        lease.installExpirationHandler {
            cancellationProbe.record()
        }

        guard case let .awaiting(join) = appState.prepareForSuspension() else {
            return XCTFail("An external transfer must be joined before suspension")
        }
        backgroundProbe.expire()
        await join.value

        XCTAssertEqual(cancellationProbe.recordedCount(), 1)
        XCTAssertEqual(
            backgroundProbe.events,
            [.ended(UIBackgroundTaskIdentifier(rawValue: 52))]
        )
    }

    func testExternalTransferExpirationBeforeHandlerInstallationCancelsImmediately() throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("early-expired-external-transfer.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let identifier = UIBackgroundTaskIdentifier(rawValue: 53)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(identifier)
        )
        let cancellationProbe = AppBackgroundTaskCancellationProbe()
        let lease = try XCTUnwrap(appState.beginExternalTransfer(
            backgroundTaskClient: backgroundProbe.makeClient()
        ))

        backgroundProbe.expire()
        lease.installExpirationHandler {
            cancellationProbe.record()
        }
        lease.finish()

        XCTAssertEqual(cancellationProbe.recordedCount(), 1)
        XCTAssertEqual(backgroundProbe.events, [.ended(identifier)])
    }

    func testDroppingExternalTransferLeaseReleasesSuspensionAndReservation() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("abandoned-external-transfer.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let identifier = UIBackgroundTaskIdentifier(rawValue: 54)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(identifier)
        )
        var lease: AppExternalTransferLease? = try XCTUnwrap(
            appState.beginExternalTransfer(backgroundTaskClient: backgroundProbe.makeClient())
        )
        lease?.installExpirationHandler {}

        guard case let .awaiting(join) = appState.prepareForSuspension() else {
            return XCTFail("An external transfer must be joined before suspension")
        }
        weak let weakLease = lease
        lease = nil
        await join.value

        XCTAssertNil(weakLease)
        XCTAssertEqual(backgroundProbe.events, [.ended(identifier)])
    }

    func testDroppingExternalDragPayloadCancelsAndReleasesItsLease() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("abandoned-external-payload.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let identifier = UIBackgroundTaskIdentifier(rawValue: 55)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(identifier)
        )
        var lease: AppExternalTransferLease? = try XCTUnwrap(
            appState.beginExternalTransfer(backgroundTaskClient: backgroundProbe.makeClient())
        )
        var payload: ExternalCopyDragPayload? = ExternalCopyDragPayload(
            itemIDs: [],
            externalTransferLease: lease,
            fetchSnapshot: { _ in nil }
        )
        lease = nil

        guard case let .awaiting(join) = appState.prepareForSuspension() else {
            return XCTFail("The payload's lease must be joined before suspension")
        }
        payload = nil
        await join.value

        XCTAssertNil(payload)
        XCTAssertEqual(backgroundProbe.events, [.ended(identifier)])
    }

    func testCancellingProviderLoadsKeepsLeaseUntilFollowUpFinishes() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("external-follow-up-suspension.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let identifier = UIBackgroundTaskIdentifier(rawValue: 56)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(identifier)
        )
        let lease = try XCTUnwrap(
            appState.beginExternalTransfer(backgroundTaskClient: backgroundProbe.makeClient())
        )
        let payload = ExternalCopyDragPayload(
            itemIDs: [],
            externalTransferLease: lease,
            fetchSnapshot: { _ in nil }
        )

        guard case let .awaiting(join) = appState.prepareForSuspension() else {
            return XCTFail("The payload's lease must be joined before suspension")
        }
        var didJoin = false
        let observer = Task { @MainActor in
            await join.value
            didJoin = true
        }

        let allowFollowUpToFinish = AppSessionWorkCompletion()
        var didStartFollowUp = false
        let evidence = [
            ExternalCopyTransferEvidence(
                itemID: "transferred-item",
                deletionToken: "token"
            ),
        ]
        var receivedEvidence: [ExternalCopyTransferEvidence] = []
        let followUp = ExternalCopyDragFollowUp.start(
            payload: payload,
            evidence: evidence,
            completion: { completedEvidence in
                receivedEvidence = completedEvidence
                didStartFollowUp = true
                await allowFollowUpToFinish.wait()
            }
        )
        await Task.yield()
        XCTAssertTrue(didStartFollowUp)
        XCTAssertFalse(didJoin)
        XCTAssertEqual(backgroundProbe.events, [])

        allowFollowUpToFinish.finish()
        await followUp.value
        await observer.value

        XCTAssertTrue(didJoin)
        XCTAssertEqual(receivedEvidence, evidence)
        XCTAssertEqual(backgroundProbe.events, [.ended(identifier)])
    }

    func testBackgroundExpirationCancelsFollowUpAndReleasesPayloadLease() async throws {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("expired-external-follow-up.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let identifier = UIBackgroundTaskIdentifier(rawValue: 57)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(identifier)
        )
        let lease = try XCTUnwrap(
            appState.beginExternalTransfer(backgroundTaskClient: backgroundProbe.makeClient())
        )
        let payload = ExternalCopyDragPayload(
            itemIDs: [],
            externalTransferLease: lease,
            fetchSnapshot: { _ in nil }
        )

        guard case let .awaiting(join) = appState.prepareForSuspension() else {
            return XCTFail("The payload's lease must be joined before suspension")
        }
        let followUpStarted = AppSessionWorkCompletion()
        var didObserveCancellation = false
        let followUp = ExternalCopyDragFollowUp.start(
            payload: payload,
            evidence: [
                ExternalCopyTransferEvidence(itemID: "item", deletionToken: "token"),
            ],
            completion: { _ in
                followUpStarted.finish()
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    didObserveCancellation = true
                }
            }
        )
        await followUpStarted.wait()
        backgroundProbe.expire()
        await followUp.value
        await join.value

        XCTAssertTrue(didObserveCancellation)
        XCTAssertEqual(backgroundProbe.events, [.ended(identifier)])
    }

    func testUnavailableExternalTransferLeaseFailsWithoutRegisteringSuspensionWork() {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath("unavailable-external-transfer.db")
        ) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)
        let backgroundProbe = AppBackgroundTaskClientProbe(
            beginBehavior: .returnIdentifier(.invalid)
        )

        XCTAssertNil(appState.beginExternalTransfer(
            backgroundTaskClient: backgroundProbe.makeClient()
        ))

        switch appState.prepareForSuspension() {
        case .quiescent:
            break
        case .awaiting:
            XCTFail("A denied lease must not strand suspension work")
        }
        XCTAssertEqual(backgroundProbe.events, [])
    }

    func testStoreOpenGateExpirationBeforeBeginRejectsOpen() {
        let gate = AppStoreOpenGate()

        gate.expireAndDrain()

        switch gate.begin() {
        case .start:
            XCTFail("An expired gate must reject store opening")
        case .rejected:
            break
        }
    }

    func testStoreOpenGateExpirationAfterRegistrationDrainsAndRejectsWrites() throws {
        let store = try ClipKittyRust.ClipboardStore(
            dbPath: databasePath("expired-open-gate.db")
        )
        let gate = AppStoreOpenGate()
        switch gate.begin() {
        case .start:
            break
        case .rejected:
            return XCTFail("A fresh gate must permit its opening attempt")
        }
        gate.register(store)

        gate.expireAndDrain()

        switch gate.transfer() {
        case .available:
            XCTFail("An expired store must not transfer into the foreground session")
        case .expired:
            break
        }
        XCTAssertThrowsError(try store.saveText(
            text: "must be rejected",
            sourceApp: nil,
            sourceAppBundleId: nil
        )) { error in
            guard let storeError = error as? ClipKittyError else {
                return XCTFail("Expected ClipKittyError, got \(error)")
            }
            switch storeError {
            case .StoreSuspended:
                break
            default:
                XCTFail("Expected StoreSuspended, got \(storeError)")
            }
        }
    }

    func testBootstrapSucceeds() {
        let result = AppContainer.bootstrap(databasePath: databasePath("test.db"))
        switch result {
        case .success:
            break
        case let .failure(error):
            XCTFail("Bootstrap failed: \(error.localizedDescription)")
        }
    }

    func testSettingsDefaultValues() {
        guard case let .success(container) = AppContainer.bootstrap(databasePath: databasePath("test.db")) else {
            XCTFail("Bootstrap failed")
            return
        }

        XCTAssertTrue(container.settings.generateLinkPreviews)
    }

    func testStaleToastDismissDoesNotHideNewerToast() {
        guard case let .success(container) = AppContainer.bootstrap(databasePath: databasePath("test.db")) else {
            return XCTFail("Bootstrap failed")
        }
        let appState = AppState(container: container)

        appState.showNotification(.passive(message: "First", iconSystemName: "1.circle"))
        guard case let .visible(firstID, firstRequest) = appState.toast else {
            return XCTFail("Expected first passive toast")
        }
        XCTAssertEqual(
            firstRequest.kind,
            .passive(message: "First", iconSystemName: "1.circle")
        )

        appState.showNotification(.passive(message: "Second", iconSystemName: "2.circle"))
        guard case let .visible(secondID, _) = appState.toast else {
            return XCTFail("Expected second passive toast")
        }

        appState.dismissToast(id: firstID)

        guard case let .visible(currentID, currentRequest) = appState.toast else {
            return XCTFail("Stale dismissal hid the current toast")
        }
        XCTAssertEqual(currentID, secondID)
        XCTAssertEqual(
            currentRequest.kind,
            .passive(message: "Second", iconSystemName: "2.circle")
        )
    }

    /// The resume path opens the store OFF the main actor (so the last known
    /// state keeps rendering) and assembles the container on it afterwards;
    /// the split must produce a container that can actually write.
    func testOpenStoreOffMainThenAssembleProducesWorkingContainer() async {
        let path = databasePath("test.db")

        let opened = await Task.detached(priority: .userInitiated) {
            AppContainer.openStore(databasePath: path)
        }.value
        guard case let .success(storeSession) = opened else {
            return XCTFail("openStore should succeed for a fresh database path")
        }

        let container = AppContainer.assemble(storeSession: storeSession)
        let saved = await container.repository.saveText(
            text: "resume smoke",
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        guard case .success = saved else {
            return XCTFail("Assembled container should be able to write to the store")
        }
    }

    func testSupersededResumeCallbackCannotClaimNewerResume() {
        let oldID = UUID()
        let newID = UUID()
        let supersededOpen = Task<Void, Never> {}

        var state = AppLaunchState.suspended(.waitingForSupersededResume(
            openTask: supersededOpen
        ))
        switch state.resumeCallbackDisposition(for: oldID) {
        case .current:
            XCTFail("A suspended resume callback must be superseded")
        case .superseded:
            break
        }

        state = .resuming(AppResumeContext(
            id: newID,
            gate: AppStoreOpenGate(),
            protection: .unavailable,
            openTask: Task<Void, Never> {}
        ))
        switch state.resumeCallbackDisposition(for: oldID) {
        case .current:
            XCTFail("An older resume callback claimed the newer resume")
        case .superseded:
            break
        }
        switch state.resumeCallbackDisposition(for: newID) {
        case let .current(context):
            XCTAssertEqual(context.id, newID)
        case .superseded:
            XCTFail("The current resume callback was rejected")
        }
    }

    func testForegroundResumeRetryPolicyIsBounded() {
        XCTAssertNotNil(AppResumeRetryPolicy.delay(forAttempt: 0))
        XCTAssertNotNil(AppResumeRetryPolicy.delay(forAttempt: 1))
        XCTAssertNotNil(AppResumeRetryPolicy.delay(forAttempt: 2))
        XCTAssertNil(AppResumeRetryPolicy.delay(forAttempt: 3))
        XCTAssertNil(AppResumeRetryPolicy.delay(forAttempt: -1))
    }

    func testBootstrapWithInvalidPathFails() {
        // The Rust connection pool deliberately retries an unavailable path
        // for its 30-second connection timeout before surfacing the bootstrap
        // error. Give this single negative-path test explicit headroom when
        // XCTest's per-test timeout enforcement is enabled in CI.
        executionTimeAllowance = 60
        let result = AppContainer.bootstrap(databasePath: "/nonexistent/path/to/db")
        switch result {
        case .success:
            XCTFail("Expected bootstrap to fail with invalid path")
        case .failure:
            break
        }
    }

    func testMultipleBootstrapsWithDifferentPathsSucceed() {
        let path1 = databasePath("db1.db")
        let path2 = databasePath("db2.db")

        guard case .success = AppContainer.bootstrap(databasePath: path1) else {
            XCTFail("First bootstrap failed")
            return
        }
        guard case .success = AppContainer.bootstrap(databasePath: path2) else {
            XCTFail("Second bootstrap failed")
            return
        }
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}
