import ClipKittyRust
import ClipKittyShared
@testable import ClipKittyiOS
import XCTest

@MainActor
final class IntentTests: XCTestCase {
    private var tempDir: URL!
    private var store: ClipKittyRust.ClipboardStore!
    private var repository: ClipboardRepository!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-intent-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.db").path
        store = try! ClipKittyRust.ClipboardStore(dbPath: dbPath)
        repository = ClipboardRepository(store: store)
        IntentAppContainer.testRepositoryOverride = repository
    }

    override func tearDown() {
        IntentAppContainer.testRepositoryOverride = nil
        repository = nil
        store = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - AddClipboardItemIntent

    func testAddIntentSavesText() async throws {
        var intent = AddClipboardItemIntent()
        intent.text = "Hello from Shortcuts"

        _ = try await intent.perform()

        let outcome = await repository.search(query: "Hello from Shortcuts", filter: .all, presentation: .card)
        guard case let .success(result) = outcome else {
            XCTFail("Search failed after adding via intent")
            return
        }
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertTrue(result.matches[0].itemMetadata.snippet.contains("Hello from Shortcuts"))
    }

    func testAddIntentSetsSourceAppToShortcuts() async throws {
        var intent = AddClipboardItemIntent()
        intent.text = "Shortcut test item"

        _ = try await intent.perform()

        let outcome = await repository.search(query: "Shortcut test item", filter: .all, presentation: .card)
        guard case let .success(result) = outcome else {
            XCTFail("Search failed")
            return
        }
        XCTAssertEqual(result.matches.first?.itemMetadata.sourceApp, "Shortcuts")
    }

    func testAddIntentCanSaveMultipleItems() async throws {
        for i in 1 ... 3 {
            var intent = AddClipboardItemIntent()
            intent.text = "Item number \(i)"
            _ = try await intent.perform()
        }

        let outcome = await repository.search(query: "", filter: .all, presentation: .card)
        guard case let .success(result) = outcome else {
            XCTFail("Search failed")
            return
        }
        XCTAssertEqual(result.totalCount, 3)
    }

    // MARK: - SearchClipboardIntent

    func testSearchIntentFindsMatchingItems() async throws {
        // Seed data
        _ = await repository.saveText(text: "Swift programming", sourceApp: "Test", sourceAppBundleId: nil)
        _ = await repository.saveText(text: "Rust programming", sourceApp: "Test", sourceAppBundleId: nil)
        _ = await repository.saveText(text: "Something else", sourceApp: "Test", sourceAppBundleId: nil)

        var intent = SearchClipboardIntent()
        intent.query = "programming"
        intent.filter = .all

        let result = try await intent.perform()
        let value = result.value
        XCTAssertTrue(value?.contains("Found 2 item") == true, "Expected 2 results, got: \(value ?? "nil")")
    }

    func testSearchIntentReturnsNoResultsMessage() async throws {
        var intent = SearchClipboardIntent()
        intent.query = "nonexistent query xyz"
        intent.filter = .all

        let result = try await intent.perform()
        let value = result.value
        XCTAssertTrue(value?.contains("No items found") == true, "Expected no results message, got: \(value ?? "nil")")
    }

    func testSearchIntentWithTextFilter() async throws {
        _ = await repository.saveText(text: "Filtered text item", sourceApp: "Test", sourceAppBundleId: nil)

        var intent = SearchClipboardIntent()
        intent.query = "Filtered"
        intent.filter = .text

        let result = try await intent.perform()
        let value = result.value
        XCTAssertTrue(value?.contains("Found") == true, "Expected results, got: \(value ?? "nil")")
    }

    func testSearchIntentWithBookmarkFilter() async throws {
        // Save an item but don't bookmark it
        _ = await repository.saveText(text: "Unbookmarked item", sourceApp: "Test", sourceAppBundleId: nil)

        var intent = SearchClipboardIntent()
        intent.query = ""
        intent.filter = .bookmarks

        let result = try await intent.perform()
        let value = result.value
        XCTAssertTrue(value?.contains("No items found") == true, "Expected no bookmarked items, got: \(value ?? "nil")")
    }

    func testSearchIntentSnippetTruncation() async throws {
        let longText = String(repeating: "A", count: 200)
        _ = await repository.saveText(text: longText, sourceApp: "Test", sourceAppBundleId: nil)

        var intent = SearchClipboardIntent()
        intent.query = ""
        intent.filter = .all

        let result = try await intent.perform()
        let value = result.value ?? ""
        // Snippets are truncated to 80 chars in the intent
        XCTAssertTrue(value.count < longText.count, "Snippet should be truncated")
    }

    // MARK: - ClipboardSearchFilter

    func testAllFilterCasesExist() {
        let cases: [ClipboardSearchFilter] = [.all, .bookmarks, .text, .images, .links, .colors]
        XCTAssertEqual(cases.count, 6)
    }
}
