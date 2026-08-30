import ClipKittyCore
import UniformTypeIdentifiers
import XCTest

final class PendingShareQueueTests: TemporaryDirectoryTestCase {
    private let tenMiB = 10 * 1024 * 1024
    private let fiftyMiB = 50 * 1024 * 1024

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
            isAnimated: true,
            in: temporaryDirectory
        )

        let pending = try XCTUnwrap(PendingShareQueue.loadAll(in: temporaryDirectory).first)
        guard case let .image(dequeuedData, dequeuedThumbnail, isAnimated) = pending.payload else {
            return XCTFail("Expected image payload")
        }
        XCTAssertEqual(dequeuedThumbnail, thumbnail)
        XCTAssertEqual(dequeuedData, imageData)
        XCTAssertTrue(isAnimated)
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

    func testEnqueueRejectsTextOverTenMiBBeforePublishing() throws {
        let oversizedText = String(repeating: "x", count: tenMiB + 1)

        XCTAssertThrowsError(
            try PendingShareQueue.enqueueText(oversizedText, in: temporaryDirectory)
        ) { error in
            XCTAssertEqual(error as? PendingShareQueue.EnqueueError, .itemTooLarge)
        }

        XCTAssertTrue(PendingShareQueue.loadAll(in: temporaryDirectory).isEmpty)
        XCTAssertEqual(try publishedEntriesIfPresent().count, 0)
    }

    func testEnqueueRejectsURLOverTenMiBBeforePublishing() throws {
        let oversizedURL = "https://example.com/" + String(
            repeating: "x",
            count: tenMiB
        )

        XCTAssertThrowsError(
            try PendingShareQueue.enqueueURL(oversizedURL, in: temporaryDirectory)
        ) { error in
            XCTAssertEqual(error as? PendingShareQueue.EnqueueError, .itemTooLarge)
        }
        XCTAssertEqual(try publishedEntriesIfPresent().count, 0)
    }

    func testEnqueueRejectsExpandedManifestBeforePublishing() throws {
        // JSON escaping doubles every backslash, so the semantic text remains
        // under 10 MiB while its serialized manifest exceeds the queue ceiling.
        let text = String(repeating: "\\", count: 6 * 1024 * 1024)

        XCTAssertThrowsError(
            try PendingShareQueue.enqueueText(text, in: temporaryDirectory)
        ) { error in
            XCTAssertEqual(error as? PendingShareQueue.EnqueueError, .metadataTooLarge)
        }
        XCTAssertEqual(try publishedEntriesIfPresent().count, 0)
    }

    func testEnqueueRejectsOversizedImageAndThumbnailBeforePublishing() throws {
        XCTAssertThrowsError(
            try PendingShareQueue.enqueueImage(
                imageData: Data(count: fiftyMiB + 1),
                thumbnail: nil,
                in: temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(error as? PendingShareQueue.EnqueueError, .itemTooLarge)
        }
        XCTAssertThrowsError(
            try PendingShareQueue.enqueueImage(
                imageData: Data([0x01]),
                thumbnail: Data(
                    count: PendingShareQueue.Limits.maximumThumbnailByteCount + 1
                ),
                in: temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(error as? PendingShareQueue.EnqueueError, .itemTooLarge)
        }
        XCTAssertEqual(try publishedEntriesIfPresent().count, 0)
    }

    func testEnqueueRejectsImageAndThumbnailOverAggregateLimit() throws {
        XCTAssertThrowsError(
            try PendingShareQueue.enqueueImage(
                imageData: Data(count: fiftyMiB),
                thumbnail: Data([0x01]),
                in: temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(error as? PendingShareQueue.EnqueueError, .aggregateTooLarge)
        }
        XCTAssertEqual(try publishedEntriesIfPresent().count, 0)
    }

    func testShareTextLoaderDoesNotBypassOversizedFileWithObjectFallback() async throws {
        let oversizedFile = temporaryDirectory.appendingPathComponent("oversized.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedFile.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversizedFile)
        try handle.truncate(
            atOffset: UInt64(PendingShareQueue.Limits.maximumTextByteCount + 1)
        )
        try handle.close()

        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(oversizedFile, false, nil)
            return nil
        }
        provider.registerObject("must not load" as NSString, visibility: .all)

        let payload = await ShareItemProviderLoader.load(
            from: provider,
            maximumAggregateByteCount: PendingShareQueue.Limits.maximumAggregateByteCount
        )

        XCTAssertNil(payload)
    }

    func testImageOverFiftyMiBIsRejectedBeforeReadAndPreserved() throws {
        let itemID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let itemDirectory = try createPublishedImageItem(
            id: itemID,
            imageByteCount: fiftyMiB + 1
        )

        XCTAssertTrue(PendingShareQueue.loadAll(in: temporaryDirectory).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemDirectory.path))
    }

    func testLoadBatchIsLimitedToFiftyItemsInDeterministicOrder() throws {
        for index in 0 ..< 51 {
            try PendingShareQueue.enqueueText("item-\(index)", in: temporaryDirectory)
        }

        let firstLoad = PendingShareQueue.loadAll(in: temporaryDirectory)
        let secondLoad = PendingShareQueue.loadAll(in: temporaryDirectory)
        let firstIDs = firstLoad.map(\.id)

        XCTAssertEqual(firstLoad.count, 50)
        XCTAssertEqual(secondLoad.map(\.id), firstIDs)
        XCTAssertEqual(
            firstIDs.map(\.uuidString),
            firstIDs.map(\.uuidString).sorted()
        )
        XCTAssertEqual(try publishedEntries().count, 51)
    }

    func testLoadBatchPayloadIsLimitedToFiftyMiB() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let imageByteCount = 26 * 1024 * 1024
        _ = try createPublishedImageItem(id: firstID, imageByteCount: imageByteCount)
        _ = try createPublishedImageItem(id: secondID, imageByteCount: imageByteCount)

        let loaded = PendingShareQueue.loadAll(in: temporaryDirectory)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, firstID)
        guard case let .image(data, thumbnail, isAnimated) = loaded.first?.payload else {
            return XCTFail("Expected the first bounded image")
        }
        XCTAssertEqual(data.count, imageByteCount)
        XCTAssertNil(thumbnail)
        XCTAssertFalse(isAnimated, "Legacy image manifests must default to static")
        XCTAssertEqual(try publishedEntries().count, 2)
    }

    private var pendingDirectory: URL {
        temporaryDirectory
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
    }

    private func publishedEntries() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    private func publishedEntriesIfPresent() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: pendingDirectory.path) else {
            return []
        }
        return try publishedEntries()
    }

    @discardableResult
    private func createPublishedImageItem(id: UUID, imageByteCount: Int) throws -> URL {
        let itemDirectory = pendingDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: itemDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"type":"image"}"#.utf8)
            .write(to: itemDirectory.appendingPathComponent("manifest.json"))

        let imageURL = itemDirectory.appendingPathComponent("image.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: imageURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(imageByteCount))
        try handle.close()
        return itemDirectory
    }
}
