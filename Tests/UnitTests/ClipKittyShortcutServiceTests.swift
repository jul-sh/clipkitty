import ClipKittyRust
import ClipKittyShared
@testable import ClipKittyShortcuts
import XCTest

final class ClipKittyShortcutServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-shortcuts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testSaveTextAndFetchRecentText() async throws {
        let service = ClipKittyShortcutService(databasePath: dbPath())

        let saved = try await service.saveText("hello from shortcuts")
        switch saved {
        case let .inserted(id):
            XCTAssertFalse(id.isEmpty)
        case .duplicate:
            XCTFail("First save should insert a new clip")
        }

        let values = try await service.fetchRecentText(limit: 3)
        XCTAssertEqual(values.first, "hello from shortcuts")
    }

    func testDuplicateSaveIsExplicitState() async throws {
        let service = ClipKittyShortcutService(databasePath: dbPath())

        _ = try await service.saveText("same clip")
        let savedAgain = try await service.saveText("same clip")

        switch savedAgain {
        case .inserted:
            XCTFail("Duplicate save should not report a new clip")
        case .duplicate:
            break
        }
    }

    func testSaveTextRejectsEmptyInput() async {
        let service = ClipKittyShortcutService(databasePath: dbPath())

        do {
            _ = try await service.saveText(" \n\t ")
            XCTFail("Expected empty text to throw")
        } catch ClipKittyShortcutError.emptyText {
            return
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSearchTextHonorsLimit() async throws {
        let service = ClipKittyShortcutService(databasePath: dbPath())

        _ = try await service.saveText("shortcut alpha")
        _ = try await service.saveText("shortcut beta")
        _ = try await service.saveText("shortcut gamma")

        let values = try await service.searchText(query: "shortcut", limit: 2)
        XCTAssertEqual(values.count, 2)
    }

    func testUsesProvidedRepositoryInsteadOfOpeningSecondStore() async throws {
        let rustStore = try ClipKittyRust.ClipboardStore(dbPath: dbPath())
        let repository = ClipboardRepository(store: rustStore)
        let service = ClipKittyShortcutService(repositoryProvider: {
            .ready(repository)
        })

        _ = await repository.saveText(
            text: "existing app repository",
            sourceApp: "Test",
            sourceAppBundleId: nil
        )

        let values = try await service.searchText(query: "existing", limit: 1)
        XCTAssertEqual(values, ["existing app repository"])
    }

    private func dbPath() -> String {
        tempDir.appendingPathComponent("clipboard.sqlite").path
    }
}
