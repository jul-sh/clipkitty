@testable import ClipKittyiOS
import ClipKittyShared
import XCTest

final class KeyboardFeedStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-keyboard-feed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    private func makeItem(
        id: String,
        kind: KeyboardFeedStore.Item.Kind = .text,
        text: String = "hello",
        colorRGBA: UInt32? = nil
    ) -> KeyboardFeedStore.Item {
        KeyboardFeedStore.Item(
            id: id,
            kind: kind,
            text: text,
            sourceApp: "Pasteboard",
            timestampUnix: 1_750_000_000,
            colorRGBA: colorRGBA
        )
    }

    // MARK: - Snapshot round trip

    func testWriteThenLoadRoundTripsItemsInOrder() throws {
        let items = [
            makeItem(id: "a", kind: .text, text: "first clip"),
            makeItem(id: "b", kind: .link, text: "https://example.com"),
            makeItem(id: "c", kind: .color, text: "#FF8800", colorRGBA: 0xFF88_00FF),
        ]

        try KeyboardFeedStore.write(items: items, in: tempDir)

        let snapshot = try XCTUnwrap(KeyboardFeedStore.loadSnapshot(in: tempDir))
        XCTAssertEqual(snapshot.version, KeyboardFeedStore.schemaVersion)
        XCTAssertEqual(snapshot.items, items)
    }

    func testLoadReturnsNilWhenNoSnapshotExists() {
        XCTAssertNil(KeyboardFeedStore.loadSnapshot(in: tempDir))
    }

    func testWriteCapsItemCount() throws {
        let items = (0 ..< (KeyboardFeedStore.maxItems + 10)).map { makeItem(id: "item-\($0)") }

        try KeyboardFeedStore.write(items: items, in: tempDir)

        let snapshot = try XCTUnwrap(KeyboardFeedStore.loadSnapshot(in: tempDir))
        XCTAssertEqual(snapshot.items.count, KeyboardFeedStore.maxItems)
        XCTAssertEqual(snapshot.items.first?.id, "item-0")
    }

    func testRewriteReplacesPreviousSnapshot() throws {
        try KeyboardFeedStore.write(items: [makeItem(id: "old")], in: tempDir)
        try KeyboardFeedStore.write(items: [makeItem(id: "new")], in: tempDir)

        let snapshot = try XCTUnwrap(KeyboardFeedStore.loadSnapshot(in: tempDir))
        XCTAssertEqual(snapshot.items.map(\.id), ["new"])
    }

    func testLoadRejectsUnknownSchemaVersion() throws {
        let dir = tempDir
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent("keyboard", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let alien = """
        {"version": \(KeyboardFeedStore.schemaVersion + 1), "generatedAtUnix": 0, "items": []}
        """
        try Data(alien.utf8).write(to: dir.appendingPathComponent("snapshot.json"))

        XCTAssertNil(KeyboardFeedStore.loadSnapshot(in: tempDir))
    }

    // MARK: - Activation marker

    func testKeyboardLastOpenedIsNilBeforeFirstOpen() {
        XCTAssertNil(KeyboardFeedStore.keyboardLastOpened(in: tempDir))
    }

    func testRecordKeyboardOpenedRoundTrips() throws {
        let opened = Date(timeIntervalSince1970: 1_750_000_123)
        KeyboardFeedStore.recordKeyboardOpened(now: opened, in: tempDir)

        let read = try XCTUnwrap(KeyboardFeedStore.keyboardLastOpened(in: tempDir))
        XCTAssertEqual(read.timeIntervalSince1970, opened.timeIntervalSince1970, accuracy: 1)
    }
}

// MARK: - Feed generation end to end

@MainActor
final class KeyboardFeedServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-keyboard-service-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testSuspensionRefreshSnapshotsInsertableClipsNewestFirst() async throws {
        let dbPath = tempDir.appendingPathComponent("test.db").path
        guard case let .success(container) = AppContainer.bootstrap(databasePath: dbPath) else {
            XCTFail("Bootstrap failed")
            return
        }
        defer { container.prepareForSuspension() }

        _ = await container.repository.saveText(text: "oldest text", sourceApp: nil, sourceAppBundleId: nil)
        _ = await container.repository.saveText(text: "https://example.com/page", sourceApp: nil, sourceAppBundleId: nil)
        // A 1x1 PNG: images are not insertable and must stay out of the feed.
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let png = try XCTUnwrap(Data(base64Encoded: pngBase64))
        _ = await container.repository.saveImage(
            imageData: png,
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil,
            isAnimated: false
        )
        _ = await container.repository.saveText(text: "newest text", sourceApp: nil, sourceAppBundleId: nil)

        let service = KeyboardFeedService(repository: container.repository, baseDirectory: tempDir)
        await service.refreshOnSuspension()

        let snapshot = try XCTUnwrap(KeyboardFeedStore.loadSnapshot(in: tempDir))
        XCTAssertEqual(snapshot.items.first?.text, "newest text")
        XCTAssertTrue(snapshot.items.contains { $0.text == "oldest text" })
        XCTAssertFalse(
            snapshot.items.contains { $0.kind != .text && $0.kind != .link && $0.kind != .color },
            "only insertable kinds belong in the keyboard feed"
        )
        XCTAssertEqual(snapshot.items.count, 3, "the image clip must not appear")
    }
}
