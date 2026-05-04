import AppIntents
@testable import ClipKittyShortcuts
import XCTest

final class ClipKittyShortcutIntentTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-shortcut-intents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testSaveTextIntentPersistsProvidedText() async throws {
        let service = makeService()
        let intent = SaveTextToClipKittyIntent()
        intent.text = "saved through intent"

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        requireStringValueWithDialog(result)
        XCTAssertEqual(result.value, "saved through intent")
        let recent = try await service.fetchRecentText(limit: 1)
        XCTAssertEqual(recent, ["saved through intent"])
    }

    func testSaveTextIntentRejectsEmptyText() async {
        let service = makeService()
        let intent = SaveTextToClipKittyIntent()
        intent.text = " \n\t "

        await assertThrowsShortcutError(.emptyText) {
            _ = try await withShortcutService(service) {
                try await intent.perform()
            }
        }
    }

    func testSaveClipboardIntentPersistsReadableTextClipboard() async throws {
        let service = makeService(pasteboardRead: .content(.text("clipboard through intent")))
        let intent = SaveClipboardToClipKittyIntent()

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        requireStringValueWithDialog(result)
        XCTAssertFalse(result.value?.isEmpty ?? true)
        let recent = try await service.fetchRecentText(limit: 1)
        XCTAssertEqual(recent, ["clipboard through intent"])
    }

    func testSaveClipboardIntentReportsEmptyClipboard() async {
        let service = makeService(pasteboardRead: .empty)
        let intent = SaveClipboardToClipKittyIntent()

        await assertThrowsShortcutError(.emptyClipboard) {
            _ = try await withShortcutService(service) {
                try await intent.perform()
            }
        }
    }

    func testSearchTextIntentReturnsMatchingValues() async throws {
        let service = makeService()
        _ = try await service.saveText("intent alpha")
        _ = try await service.saveText("intent beta")
        _ = try await service.saveText("outside query")

        let intent = SearchClipKittyTextIntent()
        intent.query = "intent"
        intent.limit = 2

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertEqual(result.value?.count, 2)
        XCTAssertTrue(result.value?.contains("intent alpha") ?? false)
        XCTAssertTrue(result.value?.contains("intent beta") ?? false)
    }

    func testGetRecentTextIntentReturnsNewestText() async throws {
        let service = makeService()
        _ = try await service.saveText("older intent clip")
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await service.saveText("newer intent clip")

        let intent = GetRecentClipKittyTextIntent()
        intent.limit = 1

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertEqual(result.value, ["newer intent clip"])
    }

    func testCopyLatestTextIntentReturnsAndWritesNewestText() async throws {
        let recorder = RecordedPasteboard()
        let service = makeService(pasteboardRecorder: recorder)
        _ = try await service.saveText("older copy intent clip")
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await service.saveText("newer copy intent clip")

        let intent = CopyLatestClipKittyTextIntent()
        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        requireStringValueWithDialog(result)
        let writtenValues = await recorder.values()
        XCTAssertEqual(result.value, "newer copy intent clip")
        XCTAssertEqual(writtenValues, ["newer copy intent clip"])
    }

    func testCopyLatestTextIntentReportsEmptyDatabase() async {
        let service = makeService()
        let intent = CopyLatestClipKittyTextIntent()

        await assertThrowsShortcutError(.noTextClips) {
            _ = try await withShortcutService(service) {
                try await intent.perform()
            }
        }
    }

    private func makeService(
        pasteboardRead: ShortcutPasteboardRead = .empty,
        pasteboardRecorder: RecordedPasteboard = RecordedPasteboard()
    ) -> ClipKittyShortcutService {
        ClipKittyShortcutService(
            databasePath: dbPath(),
            pasteboardClient: ShortcutPasteboardClient(
                read: { pasteboardRead },
                writeText: { text in
                    await pasteboardRecorder.record(text)
                }
            )
        )
    }

    private func withShortcutService<T>(
        _ service: ClipKittyShortcutService,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await ClipKittyShortcutRuntime.$serviceFactory.withValue({ service }) {
            try await operation()
        }
    }

    private func assertThrowsShortcutError<T>(
        _ expectedError: ClipKittyShortcutError,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expectedError) to throw")
        } catch let error as ClipKittyShortcutError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func dbPath() -> String {
        tempDir.appendingPathComponent("clipboard.sqlite").path
    }
}

private func requireStringValueWithDialog(
    _ result: some IntentResult & ReturnsValue<String> & ProvidesDialog
) {}

private actor RecordedPasteboard {
    private var writtenValues: [String] = []

    func record(_ value: String) {
        writtenValues.append(value)
    }

    func values() -> [String] {
        writtenValues
    }
}
