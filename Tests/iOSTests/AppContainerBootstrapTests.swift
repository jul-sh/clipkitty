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
