import ClipKittyCore
import ClipKittyRust
@testable import ClipKittyShortcuts
import ClipKittyStore
import XCTest

final class ClipKittyShortcutServiceTests: TemporaryDirectoryTestCase {
    func testSaveTextAndFetchRecentText() async throws {
        let service = ClipKittyShortcutService(databasePath: databasePath())

        let saved = try await service.saveText("hello from shortcuts")
        switch saved {
        case let .inserted(id):
            XCTAssertFalse(id.isEmpty)
        case .duplicate, .queued:
            XCTFail("First save should insert a new clip")
        }

        let values = try await service.fetchRecentText(limit: 3)
        XCTAssertEqual(values.first, "hello from shortcuts")
    }

    func testDuplicateSaveIsExplicitState() async throws {
        let service = ClipKittyShortcutService(databasePath: databasePath())

        _ = try await service.saveText("same clip")
        let savedAgain = try await service.saveText("same clip")

        switch savedAgain {
        case .inserted, .queued:
            XCTFail("Duplicate save should not report a new clip")
        case .duplicate:
            break
        }
    }

    func testSaveTextRejectsEmptyInput() async {
        let service = ClipKittyShortcutService(databasePath: databasePath())

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
        let service = ClipKittyShortcutService(databasePath: databasePath())

        _ = try await service.saveText("shortcut alpha")
        _ = try await service.saveText("shortcut beta")
        _ = try await service.saveText("shortcut gamma")

        let values = try await service.searchText(query: "shortcut", limit: 2)
        XCTAssertEqual(values.count, 2)
    }

    func testUsesProvidedSessionInsteadOfOpeningSecondStore() async throws {
        let rustStore = try ClipKittyRust.ClipboardStore(dbPath: databasePath())
        let session = StoreSession(store: rustStore)
        let service = ClipKittyShortcutService(sessionProvider: {
            .ready(session)
        })

        _ = await session.repository.saveText(
            text: "existing app repository",
            sourceApp: "Test",
            sourceAppBundleId: nil
        )

        let values = try await service.searchText(query: "existing", limit: 1)
        XCTAssertEqual(values, ["existing app repository"])
    }

    func testSaveTextQueuesDurablyWhileStoreSuspended() async throws {
        let service = ClipKittyShortcutService(
            sessionProvider: { .suspended },
            imageDescriptionGenerator: { _ in nil },
            pendingShareDirectory: temporaryDirectory
        )

        let saved = try await service.saveText("queued while suspended")

        XCTAssertEqual(saved, .queued)
        let pending = PendingShareQueue.loadAll(in: temporaryDirectory)
        XCTAssertEqual(pending.count, 1)
        guard case let .text(text) = pending.first?.payload else {
            return XCTFail("Expected a queued text payload")
        }
        XCTAssertEqual(text, "queued while suspended")
        XCTAssertEqual(pending.first?.sourceApp, "Shortcuts")
        XCTAssertEqual(pending.first?.sourceAppBundleId, "com.apple.shortcuts")
    }

    func testSaveTextQueuesDurablyBeforeFirstStoreOpen() async throws {
        let service = ClipKittyShortcutService(
            sessionProvider: { .unopened },
            imageDescriptionGenerator: { _ in nil },
            pendingShareDirectory: temporaryDirectory
        )

        let saved = try await service.saveText("queued before first open")

        XCTAssertEqual(saved, .queued)
        XCTAssertEqual(PendingShareQueue.loadAll(in: temporaryDirectory).count, 1)
    }

    func testQueuedSavePostsEnqueueNotification() async throws {
        let posted = XCTNSNotificationExpectation(
            name: PendingShareQueue.didEnqueueItemNotification
        )
        let service = ClipKittyShortcutService(
            sessionProvider: { .suspended },
            imageDescriptionGenerator: { _ in nil },
            pendingShareDirectory: temporaryDirectory
        )

        _ = try await service.saveText("nudges the drain")

        await fulfillment(of: [posted], timeout: 2)
    }

    func testSaveClipboardImageQueuesWhileStoreSuspended() async throws {
        let pasteboardClient = ShortcutPasteboardClient(read: {
            .content(.image(data: Data([0x10]), thumbnail: nil, isAnimated: true))
        })
        let service = ClipKittyShortcutService(
            sessionProvider: { .suspended },
            pasteboardClient: pasteboardClient,
            imageDescriptionGenerator: { _ in nil },
            pendingShareDirectory: temporaryDirectory
        )

        let saved = try await service.saveCurrentClipboard()

        XCTAssertEqual(saved, .queued)
        let pending = PendingShareQueue.loadAll(in: temporaryDirectory)
        guard case let .image(data, _, isAnimated) = pending.first?.payload else {
            return XCTFail("Expected a queued image payload")
        }
        XCTAssertEqual(data, Data([0x10]))
        XCTAssertTrue(isAnimated)
    }

    func testRecentTextFailsWhileStoreSuspended() async {
        let service = ClipKittyShortcutService(
            sessionProvider: { .suspended },
            imageDescriptionGenerator: { _ in nil },
            pendingShareDirectory: temporaryDirectory
        )

        do {
            _ = try await service.fetchRecentText(limit: 1)
            XCTFail("Expected a suspended store to fail reads")
        } catch ClipKittyShortcutError.databaseOpenFailed("ClipKitty is suspended.") {
            return
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecentTextOpensStandaloneStoreBeforeFirstOpen() async throws {
        let path = databasePath()
        let writer = ClipKittyShortcutService(databasePath: path)
        _ = try await writer.saveText("visible to standalone reads")

        let service = ClipKittyShortcutService(
            sessionProvider: { .unopened },
            imageDescriptionGenerator: { _ in nil },
            standaloneDatabasePathProvider: { path },
            pendingShareDirectory: temporaryDirectory
        )

        let recent = try await service.fetchRecentText(limit: 1)
        XCTAssertEqual(recent, ["visible to standalone reads"])
    }

    func testSaveCurrentClipboardImageGeneratesDescription() async throws {
        let path = databasePath()
        let pasteboardClient = ShortcutPasteboardClient(read: {
            .content(.image(data: Data([0x10]), thumbnail: nil, isAnimated: false))
        })
        let service = ClipKittyShortcutService(
            databasePath: path,
            pasteboardClient: pasteboardClient,
            imageDescriptionGenerator: { _ in "shortcut image" }
        )

        let saved = try await service.saveCurrentClipboard()
        guard case let .inserted(itemId) = saved else {
            XCTFail("Image clipboard save should insert a new clip")
            return
        }

        let repository = try ClipboardRepository(store: ClipKittyRust.ClipboardStore(dbPath: path))
        let item = await repository.fetchItem(id: itemId)
        guard case let .image(_, description, _) = item?.content else {
            XCTFail("Expected saved item to be an image")
            return
        }
        XCTAssertEqual(description, "Image: shortcut image")
    }
}
