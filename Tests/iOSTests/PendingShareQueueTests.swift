@testable import ClipKittyiOS
import ClipKittyShared
import XCTest

final class PendingShareQueueTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-pending-queue-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testEnqueueCarriesOrigin() throws {
        try PendingShareQueue.enqueueText("from share sheet", in: tempDir)

        let dequeued = PendingShareQueue.dequeueAll(in: tempDir)
        XCTAssertEqual(dequeued.count, 1)
        XCTAssertEqual(dequeued.first?.origin, .shareSheet)
    }

    func testLegacyManifestWithoutOriginDequeuesAsShareSheet() throws {
        // Manifests written before `origin` existed were a bare PendingItem.
        let itemDir = tempDir
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        let legacy = #"{"type":"text","text":"old format"}"#
        try Data(legacy.utf8).write(to: itemDir.appendingPathComponent("manifest.json"))

        let dequeued = PendingShareQueue.dequeueAll(in: tempDir)
        XCTAssertEqual(dequeued.count, 1)
        XCTAssertEqual(dequeued.first?.origin, .shareSheet)
        if case let .text(value) = dequeued.first?.item {
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
            in: tempDir
        )

        let dequeued = try XCTUnwrap(PendingShareQueue.dequeueAll(in: tempDir).first)
        XCTAssertEqual(dequeued.thumbnailData, thumbnail)
        XCTAssertEqual(dequeued.imageData, imageData)
    }
}
