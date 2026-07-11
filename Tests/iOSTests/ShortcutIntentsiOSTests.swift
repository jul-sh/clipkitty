import AppIntents
@testable import ClipKittyiOS
import ClipKittyRust
import ClipKittyShared
@testable import ClipKittyShortcuts
import UIKit
import XCTest

/// Exercises the Shortcuts intents on iOS against the real Rust store,
/// the live UIPasteboard, and the production registry wiring that
/// ClipKittyiOSApp installs. The intent suite in Tests/UnitTests runs
/// only on macOS; this is the iOS-side counterpart.
@MainActor
final class ShortcutIntentsiOSTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-shortcut-ios-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Intents against the real store

    func testSaveTextIntentPersistsIntoStore() async throws {
        let service = makeService()
        let intent = SaveTextToClipKittyIntent()
        intent.text = "saved on iOS"

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertEqual(result.value, "saved on iOS")
        let recent = try await service.fetchRecentText(limit: 1)
        XCTAssertEqual(recent, ["saved on iOS"])
    }

    func testSaveTextIntentRejectsWhitespaceOnlyText() async {
        let service = makeService()
        let intent = SaveTextToClipKittyIntent()
        intent.text = " \n\t "

        await assertThrowsShortcutError(.emptyText) {
            _ = try await withShortcutService(service) {
                try await intent.perform()
            }
        }
    }

    func testSaveTextTwiceReportsDuplicate() async throws {
        let service = makeService()
        let first = try await service.saveText("dedupe me")
        guard case .inserted = first else {
            return XCTFail("Expected first save to insert, got \(first)")
        }
        let second = try await service.saveText("dedupe me")
        XCTAssertEqual(second, .duplicate)
    }

    func testSearchTextIntentFindsMatchesInTrigramIndex() async throws {
        let service = makeService()
        _ = try await service.saveText("ios intent alpha")
        _ = try await service.saveText("ios intent beta")
        _ = try await service.saveText("unrelated entry")

        let intent = SearchClipKittyTextIntent()
        intent.query = "intent"
        intent.limit = 5

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertEqual(result.value?.count, 2)
        XCTAssertTrue(result.value?.contains("ios intent alpha") ?? false)
        XCTAssertTrue(result.value?.contains("ios intent beta") ?? false)
    }

    func testGetRecentTextIntentReturnsNewestFirst() async throws {
        let service = makeService()
        _ = try await service.saveText("older ios clip")
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await service.saveText("newer ios clip")

        let intent = GetRecentClipKittyTextIntent()
        intent.limit = 1

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertEqual(result.value, ["newer ios clip"])
    }

    // MARK: - Live UIPasteboard paths

    func testSaveClipboardIntentReadsLiveTextPasteboard() async throws {
        UIPasteboard.general.string = "live pasteboard text"
        let service = makeService(pasteboardClient: .live)
        let intent = SaveClipboardToClipKittyIntent()

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        XCTAssertFalse(result.value?.isEmpty ?? true)
        let recent = try await service.fetchRecentText(limit: 1)
        XCTAssertEqual(recent, ["live pasteboard text"])
    }

    func testSaveClipboardIntentSavesLiveURLPasteboardAsLinkItem() async throws {
        UIPasteboard.general.url = try XCTUnwrap(URL(string: "https://example.com/clip"))
        let service = makeService(pasteboardClient: .live)
        let intent = SaveClipboardToClipKittyIntent()

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        // The store classifies URL text as a link item, so the save
        // succeeds but the clip is intentionally not surfaced by the
        // text-only search/recent intents.
        let itemId = try XCTUnwrap(result.value)
        XCTAssertFalse(itemId.isEmpty)
        let recent = try await service.fetchRecentText(limit: 5)
        XCTAssertFalse(recent.contains("https://example.com/clip"))

        let repository = try ClipboardRepository(store: ClipboardStore(dbPath: dbPath()))
        let item = await repository.fetchItem(id: itemId)
        guard case let .link(url, _) = item?.content else {
            return XCTFail("Expected a link item, got \(String(describing: item?.content))")
        }
        XCTAssertEqual(url, "https://example.com/clip")
    }

    func testSaveClipboardIntentReadsLiveImagePasteboard() async throws {
        UIPasteboard.general.image = Self.makeTestImage()
        let service = makeService(pasteboardClient: .live)
        let intent = SaveClipboardToClipKittyIntent()

        let result = try await withShortcutService(service) {
            try await intent.perform()
        }

        // An image insert returns the new item id as the intent value.
        XCTAssertFalse(result.value?.isEmpty ?? true)
        XCTAssertNotEqual(result.value, "Already in ClipKitty")
    }

    func testSaveClipboardIntentReportsEmptyPasteboard() async {
        UIPasteboard.general.items = []
        let service = makeService(pasteboardClient: .live)
        let intent = SaveClipboardToClipKittyIntent()

        await assertThrowsShortcutError(.emptyClipboard) {
            _ = try await withShortcutService(service) {
                try await intent.perform()
            }
        }
    }

    // MARK: - Production registry wiring (ClipKittyiOSApp.makeSession path)

    func testIntentUsesRepositoryProviderInstalledByApp() async throws {
        guard case let .success(container) = AppContainer.bootstrap(databasePath: dbPath()) else {
            return XCTFail("AppContainer bootstrap failed")
        }
        ClipKittyShortcutRuntime.useRepositoryProvider {
            container.shortcutRepositoryAvailability()
        }

        let intent = SaveTextToClipKittyIntent()
        intent.text = "through app container"
        _ = try await intent.perform()

        let recent = try await ClipKittyShortcutRuntime.makeService().fetchRecentText(limit: 1)
        XCTAssertEqual(recent, ["through app container"])
    }

    func testIntentSurfacesUnavailableRepositoryProvider() async {
        ClipKittyShortcutRuntime.useRepositoryProvider {
            .unavailable("store is suspended for testing")
        }

        let intent = GetRecentClipKittyTextIntent()
        intent.limit = 1

        await assertThrowsShortcutError(.databaseOpenFailed("store is suspended for testing")) {
            _ = try await intent.perform()
        }
    }

    // MARK: - App Shortcuts provider

    func testAppShortcutsProviderExposesAllIntents() {
        XCTAssertEqual(ClipKittyAppShortcuts.appShortcuts.count, 4)
    }

    // MARK: - Helpers

    private func makeService(
        pasteboardClient: ShortcutPasteboardClient = ShortcutPasteboardClient(read: { .empty })
    ) -> ClipKittyShortcutService {
        ClipKittyShortcutService(
            databasePath: dbPath(),
            pasteboardClient: pasteboardClient,
            imageDescriptionGenerator: { _ in nil }
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

    private static func makeTestImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
}
