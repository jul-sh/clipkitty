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
        case .duplicate:
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
        case .inserted:
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
