import XCTest
import ClipKittyRust

/// Performance benchmarks for ClipKitty operations.
/// Run with: xcodebuild test -scheme ClipKitty -only-testing:UnitTests/PerformanceTests
final class PerformanceTests: XCTestCase {

    // MARK: - Test Setup

    private var store: ClipKittyRust.ClipboardStore!
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let dbPath = tempDirectory.appendingPathComponent("test.sqlite").path
        store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
    }

    override func tearDown() async throws {
        store = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    // MARK: - Database Operations

    /// Benchmark: Save text items to database
    func testSaveTextPerformance() throws {
        measure {
            for i in 0..<100 {
                _ = try? store.saveText(
                    text: "Test clipboard content \(i) with some additional text to make it realistic",
                    sourceApp: "TestApp",
                    sourceAppBundleId: "com.test.app"
                )
            }
        }
    }

    /// Benchmark: Search performance with various query sizes
    func testSearchPerformance() async throws {
        // Seed database with items
        for i in 0..<500 {
            _ = try store.saveText(
                text: "Item \(i): Lorem ipsum dolor sit amet, consectetur adipiscing elit. \(UUID().uuidString)",
                sourceApp: "TestApp",
                sourceAppBundleId: "com.test.app"
            )
        }

        measure {
            let expectation = self.expectation(description: "Search")
            Task {
                _ = try? await self.store.search(query: "lorem")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10.0)
        }
    }

    /// Benchmark: Empty query (browse all items)
    func testBrowseAllPerformance() async throws {
        // Seed database with items
        for i in 0..<500 {
            _ = try store.saveText(
                text: "Item \(i): Quick clipboard content",
                sourceApp: "TestApp",
                sourceAppBundleId: "com.test.app"
            )
        }

        measure {
            let expectation = self.expectation(description: "Browse")
            Task {
                _ = try? await self.store.search(query: "")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10.0)
        }
    }

    // MARK: - Highlight Computation

    /// Benchmark: Highlight computation for search results
    func testHighlightComputationPerformance() async throws {
        // Seed database with items containing searchable text
        var itemIds: [Int64] = []
        for i in 0..<100 {
            let id = try store.saveText(
                text: "Document \(i): The quick brown fox jumps over the lazy dog. Files are everywhere.",
                sourceApp: "TestApp",
                sourceAppBundleId: "com.test.app"
            )
            itemIds.append(id)
        }

        measure {
            _ = try? store.computeHighlights(itemIds: itemIds, query: "files")
        }
    }

    // MARK: - Unicode Performance

    /// Benchmark: nsRange conversion with emoji-heavy text
    func testNsRangeUnicodePerformance() {
        // Create text with many emojis (each causing UTF-16/scalar drift)
        var emojiText = ""
        for i in 0..<100 {
            emojiText += "🔥 Item \(i) "
        }
        emojiText += "FindThisWord"

        let range = HighlightRange(start: UInt64(emojiText.unicodeScalars.count - 12), end: UInt64(emojiText.unicodeScalars.count), kind: .exact)

        measure {
            for _ in 0..<1000 {
                _ = range.nsRange(in: emojiText)
            }
        }
    }

    /// Benchmark: nsRange conversion with ASCII text (baseline)
    func testNsRangeAsciiPerformance() {
        let asciiText = String(repeating: "a", count: 1000) + "FindThisWord"
        let range = HighlightRange(start: 1000, end: 1012, kind: .exact)

        measure {
            for _ in 0..<1000 {
                _ = range.nsRange(in: asciiText)
            }
        }
    }

    // MARK: - Large Content

    /// Benchmark: Handling very large text content
    func testLargeTextPerformance() throws {
        // Generate 1MB of text
        let largeText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40000)

        measure {
            _ = try? store.saveText(
                text: largeText,
                sourceApp: "TestApp",
                sourceAppBundleId: "com.test.app"
            )
        }
    }

    // MARK: - Delete Operations

    /// Benchmark: Delete item performance
    func testDeleteItemPerformance() throws {
        // Pre-create items
        var itemIds: [Int64] = []
        for i in 0..<100 {
            let id = try store.saveText(
                text: "Item to delete \(i)",
                sourceApp: "TestApp",
                sourceAppBundleId: "com.test.app"
            )
            itemIds.append(id)
        }

        measure {
            for id in itemIds.prefix(10) {
                try? store.deleteItem(itemId: id)
            }
        }
    }

    // MARK: - Concurrent Operations

    /// Benchmark: Concurrent reads during write
    func testConcurrentReadWritePerformance() async throws {
        // Seed with initial data
        for i in 0..<100 {
            _ = try store.saveText(
                text: "Initial item \(i)",
                sourceApp: "TestApp",
                sourceAppBundleId: "com.test.app"
            )
        }

        measure {
            let expectation = self.expectation(description: "Concurrent")
            expectation.expectedFulfillmentCount = 3

            Task {
                // Writer
                for i in 0..<10 {
                    _ = try? self.store.saveText(
                        text: "Concurrent write \(i)",
                        sourceApp: "TestApp",
                        sourceAppBundleId: "com.test.app"
                    )
                }
                expectation.fulfill()
            }

            Task {
                // Reader 1
                for _ in 0..<10 {
                    _ = try? await self.store.search(query: "")
                }
                expectation.fulfill()
            }

            Task {
                // Reader 2
                for _ in 0..<10 {
                    _ = try? await self.store.search(query: "initial")
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 30.0)
        }
    }
}
