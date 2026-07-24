import ClipKittyCore
@testable import ClipKittyiOS
import XCTest

final class PendingShareQueueTests: TemporaryDirectoryTestCase {
    func testEnqueueCarriesOrigin() throws {
        try PendingShareQueue.enqueueText("from share sheet", in: temporaryDirectory)

        let dequeued = PendingShareQueue.dequeueAll(in: temporaryDirectory)
        XCTAssertEqual(dequeued.count, 1)
        XCTAssertEqual(dequeued.first?.origin, .shareSheet)
    }

    func testLegacyManifestWithoutOriginDequeuesAsShareSheet() throws {
        // Manifests written before `origin` existed were a bare PendingItem.
        let itemDir = temporaryDirectory
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        let legacy = #"{"type":"text","text":"old format"}"#
        try Data(legacy.utf8).write(to: itemDir.appendingPathComponent("manifest.json"))

        let dequeued = try XCTUnwrap(PendingShareQueue.dequeueAll(in: temporaryDirectory).first)
        XCTAssertEqual(dequeued.origin, .shareSheet)
        if case let .text(value) = dequeued.payload {
            XCTAssertEqual(value, "old format")
        } else {
            XCTFail("Expected text item")
        }
    }

    func testImageRoundTripsThumbnailAndData() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01])
        let thumbnail = Data([0x01, 0x02])
        try PendingShareQueue.enqueueImage(
            imageData: imageData,
            thumbnail: thumbnail,
            in: temporaryDirectory
        )

        let dequeued = try XCTUnwrap(PendingShareQueue.dequeueAll(in: temporaryDirectory).first)
        guard case let .image(dequeuedData, dequeuedThumbnail) = dequeued.payload else {
            return XCTFail("Expected image payload")
        }
        XCTAssertEqual(dequeuedThumbnail, thumbnail)
        XCTAssertEqual(dequeuedData, imageData)
    }

    func testImageManifestWithoutImageDataIsDiscarded() throws {
        let itemDir = temporaryDirectory
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        let manifest = #"{"item":{"type":"image"},"origin":"shareSheet"}"#
        try Data(manifest.utf8).write(to: itemDir.appendingPathComponent("manifest.json"))

        XCTAssertTrue(PendingShareQueue.dequeueAll(in: temporaryDirectory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDir.path))
    }
}
