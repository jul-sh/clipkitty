@testable import ClipKittyiOS
import XCTest

@MainActor
final class AppContainerBootstrapTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-bootstrap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    private func isolatedDbPath() -> String {
        tempDir.appendingPathComponent("test.db").path
    }

    func testBootstrapSucceeds() {
        let result = AppContainer.bootstrap(databasePath: isolatedDbPath())
        switch result {
        case .success:
            break
        case let .failure(error):
            XCTFail("Bootstrap failed: \(error.localizedDescription)")
        }
    }

    func testBootstrapCreatesAllServices() {
        guard case let .success(container) = AppContainer.bootstrap(databasePath: isolatedDbPath()) else {
            XCTFail("Bootstrap failed")
            return
        }

        XCTAssertNotNil(container.repository)
        XCTAssertNotNil(container.previewLoader)
        XCTAssertNotNil(container.imageDescriptionUpdater)
        XCTAssertNotNil(container.storeClient)
        XCTAssertNotNil(container.clipboardService)
        XCTAssertNotNil(container.settings)
        XCTAssertNotNil(container.haptics)
    }

    func testSettingsDefaultValues() {
        guard case let .success(container) = AppContainer.bootstrap(databasePath: isolatedDbPath()) else {
            XCTFail("Bootstrap failed")
            return
        }

        XCTAssertTrue(container.settings.hapticsEnabled)
        XCTAssertTrue(container.settings.generateLinkPreviews)
    }

    /// The resume path opens the store OFF the main actor (so the last known
    /// state keeps rendering) and assembles the container on it afterwards;
    /// the split must produce a container that can actually write.
    func testOpenStoreOffMainThenAssembleProducesWorkingContainer() async {
        let path = isolatedDbPath()

        let opened = await Task.detached(priority: .userInitiated) {
            AppContainer.openStore(databasePath: path)
        }.value
        guard case let .success(store) = opened else {
            return XCTFail("openStore should succeed for a fresh database path")
        }

        let container = AppContainer.assemble(store: store)
        let saved = await container.repository.saveText(
            text: "resume smoke",
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        guard case .success = saved else {
            return XCTFail("Assembled container should be able to write to the store")
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
        let path1 = tempDir.appendingPathComponent("db1.db").path
        let path2 = tempDir.appendingPathComponent("db2.db").path

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
