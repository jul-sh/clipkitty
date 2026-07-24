import ClipKittyContentServices
import ClipKittyRust
import ClipKittyStore
import XCTest

final class ImageDescriptionUpdaterTests: TemporaryDirectoryTestCase {
    func testUpdaterStoresGeneratedImageDescription() async throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: databasePath())
        let repository = ClipboardRepository(store: store)
        let saveResult = await repository.saveImage(
            imageData: Data([0x01, 0x02, 0x03]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        )
        let itemId = try saveResult.get()

        let updater = ImageDescriptionUpdater(repository: repository) { _ in
            "  red bicycle  "
        }
        let didUpdate = try await updater.update(itemId: itemId, imageData: Data([0xFF])).get()

        XCTAssertTrue(didUpdate)
        let item = await repository.fetchItem(id: itemId)
        guard case let .image(_, description, _) = item?.content else {
            XCTFail("Expected saved item to be an image")
            return
        }
        XCTAssertEqual(description, "Image: red bicycle")
    }

    func testUpdaterSkipsEmptyGeneratedDescription() async throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: databasePath())
        let repository = ClipboardRepository(store: store)
        let saveResult = await repository.saveImage(
            imageData: Data([0x01, 0x02, 0x03]),
            thumbnail: nil,
            sourceApp: "Test",
            sourceAppBundleId: nil,
            isAnimated: false
        )
        let itemId = try saveResult.get()

        let updater = ImageDescriptionUpdater(repository: repository) { _ in
            "   "
        }
        let didUpdate = try await updater.update(itemId: itemId, imageData: Data([0xFF])).get()

        XCTAssertFalse(didUpdate)
        let item = await repository.fetchItem(id: itemId)
        guard case let .image(_, description, _) = item?.content else {
            XCTFail("Expected saved item to be an image")
            return
        }
        XCTAssertEqual(description, "Image")
    }
}
