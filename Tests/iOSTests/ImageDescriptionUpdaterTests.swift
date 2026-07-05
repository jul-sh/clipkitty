import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import XCTest

final class ImageDescriptionUpdaterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-image-description-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testUpdaterStoresGeneratedImageDescription() async throws {
        let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath())
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
        let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath())
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

    private func dbPath() -> String {
        tempDir.appendingPathComponent("clipboard.sqlite").path
    }
}
