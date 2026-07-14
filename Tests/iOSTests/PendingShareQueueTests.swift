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
        try PendingShareQueue.enqueueText("from keyboard", origin: .keyboard, in: tempDir)
        try PendingShareQueue.enqueueText("from share sheet", in: tempDir)

        let dequeued = PendingShareQueue.dequeueAll(in: tempDir)
        XCTAssertEqual(dequeued.count, 2)

        let byText = { (text: String) -> PendingShareQueue.DequeuedItem? in
            dequeued.first {
                if case let .text(value) = $0.item { return value == text }
                return false
            }
        }
        XCTAssertEqual(try XCTUnwrap(byText("from keyboard")).origin, .keyboard)
        XCTAssertEqual(try XCTUnwrap(byText("from share sheet")).origin, .shareSheet)
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

    func testPeekDoesNotRemoveItems() throws {
        try PendingShareQueue.enqueueText("captured", origin: .keyboard, in: tempDir)

        let peeked = PendingShareQueue.peekAll(in: tempDir)
        XCTAssertEqual(peeked.count, 1)
        XCTAssertEqual(peeked.first?.origin, .keyboard)

        // Still there for the app to ingest.
        let dequeued = PendingShareQueue.dequeueAll(in: tempDir)
        XCTAssertEqual(dequeued.count, 1)
        XCTAssertTrue(PendingShareQueue.peekAll(in: tempDir).isEmpty)
    }

    func testPeekedImageExposesThumbnailAndFileURL() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01])
        let thumbnail = Data([0x01, 0x02])
        try PendingShareQueue.enqueueImage(
            imageData: imageData,
            thumbnail: thumbnail,
            origin: .keyboard,
            in: tempDir
        )

        let peeked = try XCTUnwrap(PendingShareQueue.peekAll(in: tempDir).first)
        XCTAssertEqual(peeked.thumbnailData, thumbnail)
        let fileURL = try XCTUnwrap(peeked.imageFileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), imageData)
    }
}

final class PasteboardIngestStateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PasteboardIngestStateTests")!
        defaults.removePersistentDomain(forName: "PasteboardIngestStateTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "PasteboardIngestStateTests")
        defaults = nil
        super.tearDown()
    }

    func testNilBeforeFirstRecord() {
        XCTAssertNil(PasteboardIngestState.lastChangeCount(defaults: defaults))
    }

    func testRecordRoundTrips() {
        PasteboardIngestState.recordChangeCount(7, defaults: defaults)
        XCTAssertEqual(PasteboardIngestState.lastChangeCount(defaults: defaults), 7)

        PasteboardIngestState.recordChangeCount(9, defaults: defaults)
        XCTAssertEqual(PasteboardIngestState.lastChangeCount(defaults: defaults), 9)
    }
}
