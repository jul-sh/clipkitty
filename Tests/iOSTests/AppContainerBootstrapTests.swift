@testable import ClipKittyiOS
import XCTest

@MainActor
final class AppContainerBootstrapTests: TemporaryDirectoryTestCase {
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

    func testResumeSpinnerDeadlineOnlyAdvancesMatchingResume() {
        let session = makeSession(databaseName: "resume-spinner.db")
        let currentID = UUID()
        var state = AppLaunchState.resuming(makeResumeContext(
            id: currentID,
            session: session,
            phase: .waitingForSpinner
        ))

        state.advanceResumeSpinner(for: UUID())
        guard case let .resuming(waitingContext) = state else {
            return XCTFail("Stale spinner callback changed the launch state")
        }
        XCTAssertEqual(waitingContext.phase, .waitingForSpinner)

        state.advanceResumeSpinner(for: currentID)
        guard case let .resuming(showingContext) = state else {
            return XCTFail("Current spinner callback changed the launch state shape")
        }
        XCTAssertEqual(showingContext.phase, .showingSpinner)
    }

    func testSupersededResumeCallbackCannotClaimNewerResume() {
        let session = makeSession(databaseName: "resume-identity.db")
        let oldID = UUID()
        let newID = UUID()
        let supersededOpen = Task<Void, Never> {}

        var state = AppLaunchState.suspended(.waitingForSupersededResume(
            previous: session,
            openTask: supersededOpen
        ))
        switch state.resumeCallbackDisposition(for: oldID) {
        case .current:
            XCTFail("A suspended resume callback must be superseded")
        case .superseded:
            break
        }

        state = .resuming(makeResumeContext(
            id: newID,
            session: session,
            phase: .waitingForSpinner
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

    private func makeSession(databaseName: String) -> AppSession {
        guard case let .success(container) = AppContainer.bootstrap(
            databasePath: databasePath(databaseName)
        ) else {
            fatalError("Expected test container bootstrap to succeed")
        }
        return AppSession(container: container, appState: AppState(container: container))
    }

    private func makeResumeContext(
        id: UUID,
        session: AppSession,
        phase: AppResumePhase
    ) -> AppResumeContext {
        AppResumeContext(
            id: id,
            previous: session,
            phase: phase,
            spinnerTask: Task<Void, Never> {},
            openTask: Task<Void, Never> {}
        )
    }
}
