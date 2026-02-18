import XCTest
import ClipKittyRust

final class MultiFileTests: XCTestCase {

    // MARK: - Rust Store Integration

    private func makeStore() throws -> ClipKittyRust.ClipboardStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        return try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    // MARK: - saveFiles roundtrip

    func testSaveFilesRoundtripThreeFiles() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            paths: ["/tmp/a.pdf", "/tmp/b.txt", "/tmp/c.png"],
            filenames: ["a.pdf", "b.txt", "c.png"],
            fileSizes: [1000, 2000, 3000],
            utis: ["com.adobe.pdf", "public.plain-text", "public.png"],
            bookmarkDataList: [Data([1, 2]), Data([3, 4]), Data([5, 6])],
            thumbnail: nil,
            sourceApp: "Finder",
            sourceAppBundleId: "com.apple.finder"
        )
        XCTAssertGreaterThan(id, 0, "New multi-file entry should return positive ID")

        let items = try store.fetchByIds(itemIds: [id])
        XCTAssertEqual(items.count, 1)

        guard case .file(let displayName, let files) = items[0].content else {
            XCTFail("Expected File content, got \(items[0].content)")
            return
        }

        XCTAssertEqual(displayName, "a.pdf and 2 more", "Display name for 3 files")
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
            paths: ["/tmp/solo.txt"],
            filenames: ["solo.txt"],
            fileSizes: [42],
            utis: ["public.plain-text"],
            bookmarkDataList: [Data([1, 2, 3])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertGreaterThan(id, 0)

        let items = try store.fetchByIds(itemIds: [id])
        guard case .file(let displayName, let files) = items[0].content else {
            XCTFail("Expected File content")
            return
        }

        XCTAssertEqual(displayName, "solo.txt")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].filename, "solo.txt")
    }

    // MARK: - Deduplication

    func testSaveFilesDedup() throws {
        let store = try makeStore()

        let id1 = try store.saveFiles(
            paths: ["/tmp/a.txt", "/tmp/b.txt"],
            filenames: ["a.txt", "b.txt"],
            fileSizes: [100, 200],
            utis: ["public.plain-text", "public.plain-text"],
            bookmarkDataList: [Data([1]), Data([2])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertGreaterThan(id1, 0)

        let id2 = try store.saveFiles(
            paths: ["/tmp/a.txt", "/tmp/b.txt"],
            filenames: ["a.txt", "b.txt"],
            fileSizes: [100, 200],
            utis: ["public.plain-text", "public.plain-text"],
            bookmarkDataList: [Data([1]), Data([2])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertEqual(id2, 0, "Duplicate multi-file should return 0")
    }

    func testSaveFilesDedupOrderIndependent() throws {
        let store = try makeStore()

        let id1 = try store.saveFiles(
            paths: ["/tmp/a.txt", "/tmp/b.txt"],
            filenames: ["a.txt", "b.txt"],
            fileSizes: [100, 200],
            utis: ["public.plain-text", "public.plain-text"],
            bookmarkDataList: [Data([1]), Data([2])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertGreaterThan(id1, 0)

        // Same files, reversed order
        let id2 = try store.saveFiles(
            paths: ["/tmp/b.txt", "/tmp/a.txt"],
            filenames: ["b.txt", "a.txt"],
            fileSizes: [200, 100],
            utis: ["public.plain-text", "public.plain-text"],
            bookmarkDataList: [Data([2]), Data([1])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )
        XCTAssertEqual(id2, 0, "Same files in different order should deduplicate")
    }

    // MARK: - Display name generation

    func testTwoFilesDisplayName() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            paths: ["/tmp/a.txt", "/tmp/b.txt"],
            filenames: ["a.txt", "b.txt"],
            fileSizes: [100, 200],
            utis: ["public.plain-text", "public.plain-text"],
            bookmarkDataList: [Data([1]), Data([2])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        XCTAssertEqual(items[0].textContent, "a.txt, b.txt")
    }

    func testThreeFilesDisplayName() throws {
        let store = try makeStore()

        let id = try store.saveFiles(
            paths: ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"],
            filenames: ["a.txt", "b.txt", "c.txt"],
            fileSizes: [100, 200, 300],
            utis: ["public.plain-text", "public.plain-text", "public.plain-text"],
            bookmarkDataList: [Data([1]), Data([2]), Data([3])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        XCTAssertEqual(items[0].textContent, "a.txt and 2 more")
    }

    // MARK: - Search

    func testSearchFindsAdditionalFilenames() async throws {
        let store = try makeStore()

        try store.saveFiles(
            paths: ["/tmp/report.pdf", "/tmp/summary.docx"],
            filenames: ["report.pdf", "summary.docx"],
            fileSizes: [1000, 2000],
            utis: ["com.adobe.pdf", "org.openxmlformats.wordprocessingml.document"],
            bookmarkDataList: [Data([1]), Data([2])],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        // Find by primary filename
        let result1 = try await store.search(query: "report")
        XCTAssertFalse(result1.matches.isEmpty, "Should find by primary filename")

        // Find by additional filename
        let result2 = try await store.search(query: "summary")
        XCTAssertFalse(result2.matches.isEmpty, "Should find by additional filename")
    }

    // MARK: - textContent extension

    func testClipboardContentTextContentForFile() throws {
        let store = try makeStore()

        let id = try store.saveFile(
            path: "/tmp/test.pdf",
            filename: "test.pdf",
            fileSize: 100,
            uti: "com.adobe.pdf",
            bookmarkData: Data([1]),
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        // textContent should return the filename
        XCTAssertEqual(items[0].content.textContent, "test.pdf")
    }

    // MARK: - Additional files JSON bookmark encoding

    func testAdditionalFilesJsonContainsBase64Bookmarks() throws {
        let store = try makeStore()
        let bookmark1 = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let bookmark2 = Data([0xCA, 0xFE, 0xBA, 0xBE])

        let id = try store.saveFiles(
            paths: ["/tmp/a.txt", "/tmp/b.txt"],
            filenames: ["a.txt", "b.txt"],
            fileSizes: [100, 200],
            utis: ["public.plain-text", "public.plain-text"],
            bookmarkDataList: [bookmark1, bookmark2],
            thumbnail: nil,
            sourceApp: nil,
            sourceAppBundleId: nil
        )

        let items = try store.fetchByIds(itemIds: [id])
        guard case .file(_, let files) = items[0].content else {
            XCTFail("Expected File content")
            return
        }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].bookmarkData, bookmark1, "First file bookmark should match")
        XCTAssertEqual(files[1].bookmarkData, bookmark2, "Second file bookmark should match")
    }
}
