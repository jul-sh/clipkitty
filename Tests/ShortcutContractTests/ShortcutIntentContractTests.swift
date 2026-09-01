import AppIntents
import ClipKittyCore
@testable import ClipKittyShortcuts
import XCTest

@MainActor
final class ShortcutIntentContractTests: ShortcutIntentTestCase {
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

    func testSavingTheSameTextTwiceReportsDuplicate() async throws {
        let service = makeService()
        let first = try await service.saveText("dedupe me")
        guard case .inserted = first else {
            return XCTFail("Expected first save to insert, got \(first)")
        }

        let second = try await service.saveText("dedupe me")
        XCTAssertEqual(second, .duplicate)
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

    func testSaveTextIntentQueuesWhileStoreSuspended() async throws {
        let service = ClipKittyShortcutService(
            sessionProvider: { .suspended },
            imageDescriptionGenerator: { _ in nil },
            pendingShareDirectory: temporaryDirectory
        )
        let intent = SaveTextToClipKittyIntent()
        intent.text = "queued through intent"

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertEqual(result.value, "queued through intent")
        let pending = PendingShareQueue.loadAll(in: temporaryDirectory)
        XCTAssertEqual(pending.count, 1)
        guard case let .text(text) = pending.first?.payload else {
            return XCTFail("Expected a queued text payload")
        }
        XCTAssertEqual(text, "queued through intent")
    }

    func testSaveClipboardIntentQueuesWhileStoreSuspended() async throws {
        let service = ClipKittyShortcutService(
            sessionProvider: { .suspended },
            pasteboardClient: ShortcutPasteboardClient(read: {
                .content(.text("clipboard queued through intent"))
            }),
            imageDescriptionGenerator: { _ in nil },
            pendingShareDirectory: temporaryDirectory
        )
        let intent = SaveClipboardToClipKittyIntent()

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertEqual(result.value, "Saved to ClipKitty")
        let pending = PendingShareQueue.loadAll(in: temporaryDirectory)
        guard case let .text(text) = pending.first?.payload else {
            return XCTFail("Expected a queued text payload")
        }
        XCTAssertEqual(text, "clipboard queued through intent")
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
}

private func requireStringValueWithDialog(
    _: some IntentResult & ReturnsValue<String> & ProvidesDialog
) {}
