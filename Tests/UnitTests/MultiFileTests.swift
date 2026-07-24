import ClipKittyRust
import XCTest

final class MultiFileTests: XCTestCase {
    // MARK: - Rust Store Integration

    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        return try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    private func file(
        _ path: String,
        _ filename: String,
        _ fileSize: UInt64,
        _ uti: String,
        bookmarkData: Data = Data(),
        preview: FilePreviewSnapshot = .unavailable(reason: .notCaptured)
    ) -> NewFileInput {
        NewFileInput(
            path: path,
            filename: filename,
            fileSize: fileSize,
            uti: uti,
            bookmarkData: bookmarkData,
            preview: preview
        )
    }

    // MARK: - saveFiles roundtrip

    func testSaveFilesRoundtripThreeFiles() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            files: [
                file("/tmp/a.pdf", "a.pdf", 1000, "com.adobe.pdf", bookmarkData: Data([1, 2])),
                file("/tmp/b.txt", "b.txt", 2000, "public.plain-text", bookmarkData: Data([3, 4])),
                file("/tmp/c.png", "c.png", 3000, "public.png", bookmarkData: Data([5, 6])),
            ],
            sourceApp: "Finder",
            sourceAppBundleId: "com.apple.finder"
        )
        XCTAssertFalse(id.isEmpty, "New multi-file entry should return a stable ID")

        let items = try store.fetchByIds(itemIds: [id])
        XCTAssertEqual(items.count, 1)

        guard case let .file(displayName, files) = items[0].content else {
            XCTFail("Expected File content, got \(items[0].content)")
            return
        }

        XCTAssertEqual(displayName, "3 Files: a.pdf and 2 more", "Display name for 3 files")
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].path, "/tmp/a.pdf", "Primary path should be first file")
        XCTAssertEqual(files[0].filename, "a.pdf")
        XCTAssertEqual(files[0].fileSize, 1000, "Primary file size")
        XCTAssertEqual(files[1].filename, "b.txt")
        XCTAssertEqual(files[2].filename, "c.png")
    }

    func testSaveFilesSingleFileEquivalent() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            files: [
                file("/tmp/solo.txt", "solo.txt", 42, "public.plain-text", bookmarkData: Data([1, 2, 3])),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertFalse(id.isEmpty)

        let items = try store.fetchByIds(itemIds: [id])
        guard case let .file(displayName, files) = items[0].content else {
            XCTFail("Expected File content")
            return
        }

        XCTAssertEqual(displayName, "File: solo.txt")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].filename, "solo.txt")
    }

    func testSaveFilesRejectsEmptyCollection() throws {
        let store = try makeStore()

        XCTAssertThrowsError(try store.saveFiles(
            files: [],
            sourceApp: nil,
            sourceAppBundleId: nil
        ))
    }

    // MARK: - Deduplication

    func testSaveFilesDedup() throws {
        let store = try makeStore()

        let files = [
            file("/tmp/a.txt", "a.txt", 100, "public.plain-text", bookmarkData: Data([1])),
            file("/tmp/b.txt", "b.txt", 200, "public.plain-text", bookmarkData: Data([2])),
        ]
        let id1 = try store.saveFiles(
            files: files,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertFalse(id1.isEmpty)

        let id2 = try store.saveFiles(
            files: files,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertTrue(id2.isEmpty, "Duplicate multi-file should return an empty ID")
    }

    func testSaveFilesDedupOrderIndependent() throws {
        let store = try makeStore()

        let id1 = try store.saveFiles(
            files: [
                file("/tmp/a.txt", "a.txt", 100, "public.plain-text", bookmarkData: Data([1])),
                file("/tmp/b.txt", "b.txt", 200, "public.plain-text", bookmarkData: Data([2])),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertFalse(id1.isEmpty)

        // Same files, reversed order
        let id2 = try store.saveFiles(
            files: [
                file("/tmp/b.txt", "b.txt", 200, "public.plain-text", bookmarkData: Data([2])),
                file("/tmp/a.txt", "a.txt", 100, "public.plain-text", bookmarkData: Data([1])),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertTrue(id2.isEmpty, "Same files in different order should deduplicate")
    }

    // MARK: - Display name generation

    func testTwoFilesDisplayName() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            files: [
                file("/tmp/a.txt", "a.txt", 100, "public.plain-text", bookmarkData: Data([1])),
                file("/tmp/b.txt", "b.txt", 200, "public.plain-text", bookmarkData: Data([2])),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        XCTAssertEqual(items[0].content.textContent, "2 Files: a.txt, b.txt")
    }

    func testThreeFilesDisplayName() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            files: [
                file("/tmp/a.txt", "a.txt", 100, "public.plain-text", bookmarkData: Data([1])),
                file("/tmp/b.txt", "b.txt", 200, "public.plain-text", bookmarkData: Data([2])),
                file("/tmp/c.txt", "c.txt", 300, "public.plain-text", bookmarkData: Data([3])),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        XCTAssertEqual(items[0].content.textContent, "3 Files: a.txt and 2 more")
    }

    // MARK: - Search

    func testSearchFindsAdditionalFilenames() async throws {
        let store = try makeStore()

        _ = try store.saveFiles(
            files: [
                file("/tmp/report.pdf", "report.pdf", 1000, "com.adobe.pdf", bookmarkData: Data([1])),
                file(
                    "/tmp/summary.docx",
                    "summary.docx",
                    2000,
                    "org.openxmlformats.wordprocessingml.document",
                    bookmarkData: Data([2])
                ),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        // Find by primary filename
        let result1 = try await store.search(query: "report", presentation: .compactRow)
        XCTAssertFalse(result1.matches.isEmpty, "Should find by primary filename")

        // Find by additional filename
        let result2 = try await store.search(query: "summary", presentation: .compactRow)
        XCTAssertFalse(result2.matches.isEmpty, "Should find by additional filename")
    }

    // MARK: - textContent extension

    func testClipboardContentTextContentForFile() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            files: [
                file("/tmp/test.pdf", "test.pdf", 100, "com.adobe.pdf", bookmarkData: Data([1])),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        // textContent should return the filename with prefix
        XCTAssertEqual(items[0].content.textContent, "File: test.pdf")
    }

    // MARK: - Additional files JSON bookmark encoding

    func testAdditionalFilesJsonContainsBase64Bookmarks() throws {
        let store = try makeStore()
        let bookmark1 = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let bookmark2 = Data([0xCA, 0xFE, 0xBA, 0xBE])

        let id = try store.saveFiles(
            files: [
                file("/tmp/a.txt", "a.txt", 100, "public.plain-text", bookmarkData: bookmark1),
                file("/tmp/b.txt", "b.txt", 200, "public.plain-text", bookmarkData: bookmark2),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        guard case let .file(_, files) = items[0].content else {
            XCTFail("Expected File content")
            return
        }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].bookmarkData, bookmark1, "First file bookmark should match")
        XCTAssertEqual(files[1].bookmarkData, bookmark2, "Second file bookmark should match")
    }

    func testSaveFilesPreviewSnapshotsRoundtrip() throws {
        let store = try makeStore()
        let imagePreview = Data([0xFF, 0xD8, 0xFF])

        let id = try store.saveFiles(
            files: [
                file(
                    "/tmp/readme.md",
                    "readme.md",
                    64,
                    "net.daringfireball.markdown",
                    preview: .text(text: .truncated(sample: "hello"))
                ),
                file(
                    "/tmp/screenshot.jpg",
                    "screenshot.jpg",
                    1024,
                    "public.jpeg",
                    preview: .image(previewData: imagePreview)
                ),
                file(
                    "/tmp/archive.zip",
                    "archive.zip",
                    2048,
                    "public.zip-archive",
                    preview: .unavailable(reason: .unsupportedType)
                ),
            ],
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        guard case let .file(_, files) = items[0].content else {
            XCTFail("Expected File content")
            return
        }

        guard case let .text(text) = files[0].preview,
              case let .truncated(sample) = text
        else {
            XCTFail("Expected truncated text preview")
            return
        }
        XCTAssertEqual(sample, "hello")

        guard case let .image(previewData) = files[1].preview else {
            XCTFail("Expected image preview")
            return
        }
        XCTAssertEqual(previewData, imagePreview)

        guard case let .unavailable(reason) = files[2].preview else {
            XCTFail("Expected unavailable preview")
            return
        }
        XCTAssertEqual(reason, .unsupportedType)
    }
}
