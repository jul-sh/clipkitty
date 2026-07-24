import AppIntents
@testable import ClipKittyiOS
import ClipKittyRust
@testable import ClipKittyShortcuts
import ClipKittyStore
import UIKit
import XCTest

/// Exercises the Shortcuts intents on iOS against the real Rust store,
/// the live UIPasteboard, and the production registry wiring that
/// ClipKittyiOSApp installs. Platform-neutral intent behavior lives in
/// ShortcutIntentContractTests and runs unchanged on both Apple platforms.
@MainActor
final class ShortcutIntentsiOSTests: ShortcutIntentTestCase {
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

        let repository = try ClipboardRepository(store: ClipboardStore(dbPath: databasePath()))
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

    func testIntentUsesStoreSessionProviderInstalledByApp() async throws {
        guard case let .success(container) = AppContainer.bootstrap(databasePath: databasePath()) else {
            return XCTFail("AppContainer bootstrap failed")
        }
        ClipKittyShortcutRuntime.useStoreProvider {
            container.shortcutStoreAvailability()
        }

        let intent = SaveTextToClipKittyIntent()
        intent.text = "through app container"
        _ = try await intent.perform()

        let recent = try await ClipKittyShortcutRuntime.makeService().fetchRecentText(limit: 1)
        XCTAssertEqual(recent, ["through app container"])
    }

    func testIntentSurfacesUnavailableStoreSessionProvider() async {
        ClipKittyShortcutRuntime.useStoreProvider {
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

    private static func makeTestImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
}
