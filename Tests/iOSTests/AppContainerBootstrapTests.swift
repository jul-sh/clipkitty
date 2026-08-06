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

        XCTAssertTrue(container.settings.hapticsEnabled)
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

    func testBootstrapWithInvalidPathFails() {
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
}
