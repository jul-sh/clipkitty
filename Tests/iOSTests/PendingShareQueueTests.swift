import ClipKittyCore
@testable import ClipKittyiOS
import XCTest

final class PendingShareQueueTests: TemporaryDirectoryTestCase {
    func testTextRoundTrips() throws {
        try PendingShareQueue.enqueueText("from share sheet", in: temporaryDirectory)

        let pending = try XCTUnwrap(PendingShareQueue.loadAll(in: temporaryDirectory).first)
        guard case let .text(text) = pending.payload else {
            return XCTFail("Expected text payload")
        }
        XCTAssertEqual(text, "from share sheet")

        XCTAssertEqual(PendingShareQueue.loadAll(in: temporaryDirectory).count, 1)
        PendingShareQueue.acknowledge(pending, in: temporaryDirectory)
        XCTAssertTrue(PendingShareQueue.loadAll(in: temporaryDirectory).isEmpty)
    }

    func testImageRoundTripsThumbnailAndData() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01])
        let thumbnail = Data([0x01, 0x02])
        try PendingShareQueue.enqueueImage(
            imageData: imageData,
            thumbnail: thumbnail,
            in: temporaryDirectory
        )

        let pending = try XCTUnwrap(PendingShareQueue.loadAll(in: temporaryDirectory).first)
        guard case let .image(dequeuedData, dequeuedThumbnail) = pending.payload else {
            return XCTFail("Expected image payload")
        }
        XCTAssertEqual(dequeuedThumbnail, thumbnail)
        XCTAssertEqual(dequeuedData, imageData)
    }

    func testImageManifestWithoutReadableImageDataRemainsQueued() throws {
        let itemDir = temporaryDirectory
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        let manifest = #"{"type":"image"}"#
        try Data(manifest.utf8).write(to: itemDir.appendingPathComponent("manifest.json"))

        XCTAssertTrue(PendingShareQueue.loadAll(in: temporaryDirectory).isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: itemDir.path),
            "A transiently unreadable payload must remain queued for retry"
        )
    }

    func testUnpublishedStagingDirectoryIsNeverConsumed() throws {
        let pendingDirectory = temporaryDirectory
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        let itemID = UUID().uuidString
        let stagingDirectory = pendingDirectory
            .appendingPathComponent(".\(itemID).staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"text","text":"not published yet"}"#.utf8)
            .write(to: stagingDirectory.appendingPathComponent("manifest.json"))

        XCTAssertTrue(PendingShareQueue.loadAll(in: temporaryDirectory).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.path))

        let publishedDirectory = pendingDirectory.appendingPathComponent(itemID, isDirectory: true)
        try FileManager.default.moveItem(at: stagingDirectory, to: publishedDirectory)

        let item = try XCTUnwrap(PendingShareQueue.loadAll(in: temporaryDirectory).first)
        guard case let .text(text) = item.payload else {
            return XCTFail("Expected text payload")
        }
        XCTAssertEqual(text, "not published yet")
    }
}
