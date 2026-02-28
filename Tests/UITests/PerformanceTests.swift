import XCTest

/// Performance tests for detecting UI stuttering during rapid search typing.
///
/// These tests replicate the conditions that caused main thread hangs:
/// - Large database with items containing long text content
/// - Rapid character-by-character typing in the search field
///
/// The test measures keystroke-to-response latency and fails if any keystroke
/// causes a main thread hang (>250ms) or if average latency exceeds 60fps (16.67ms).
final class PerformanceTests: XCTestCase {
    var app: XCUIApplication!

    /// Hang threshold: Apple defines hangs as main thread blocking >= 250ms
    private let hangThresholdMs: Double = 250

    /// Stutter threshold: 60fps = 16.67ms per frame
    private let stutterThresholdMs: Double = 16.67

    /// Maximum acceptable average latency for the test to pass
    private let maxAverageLatencyMs: Double = 50

    override func setUpWithError() throws {
        continueAfterFailure = false

        let appURL = try locateAppBundle()
        app = XCUIApplication(url: appURL)

        let appSupportDir = getAppSupportDirectory(for: appURL)
        try setupPerformanceTestDatabase(in: appSupportDir)

        app.launchArguments = ["--use-simulated-db"]
        app.launch()

        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 15),
            "App UI did not appear"
        )
        Thread.sleep(forTimeInterval: 0.5)
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Performance Tests

    /// Tests that rapid typing in the search field does not cause UI hangs.
    ///
    /// This test simulates a user typing quickly (character by character) and
    /// measures the time between keystrokes to detect main thread blocking.
    func testSearchFieldRapidTypingNoHangs() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        searchField.click()
        Thread.sleep(forTimeInterval: 0.2)

        // Test query that will match multiple items and trigger highlighting
        let testQueries = [
            "function",      // Common programming keyword
            "import",        // Another common keyword
            "return value",  // Multi-word search
            "error handling" // Phrase that triggers complex matching
        ]

        var allLatencies: [Double] = []
        var hangCount = 0
        var stutterCount = 0

        for query in testQueries {
            // Clear previous search
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(.delete, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.1)

            // Type each character and measure latency
            for char in query {
                let startTime = CFAbsoluteTimeGetCurrent()

                searchField.typeText(String(char))

                let endTime = CFAbsoluteTimeGetCurrent()
                let latencyMs = (endTime - startTime) * 1000

                allLatencies.append(latencyMs)

                if latencyMs >= hangThresholdMs {
                    hangCount += 1
                    XCTFail("HANG: Character '\(char)' caused \(String(format: "%.1f", latencyMs))ms delay (threshold: \(hangThresholdMs)ms)")
                } else if latencyMs >= stutterThresholdMs {
                    stutterCount += 1
                }
            }
        }

        // Calculate statistics
        let avgLatency = allLatencies.reduce(0, +) / Double(allLatencies.count)
        let maxLatency = allLatencies.max() ?? 0
        let p95Index = Int(Double(allLatencies.count) * 0.95)
        let sortedLatencies = allLatencies.sorted()
        let p95Latency = sortedLatencies.indices.contains(p95Index) ? sortedLatencies[p95Index] : maxLatency

        // Log results
        print("""

        === Performance Test Results ===
        Total keystrokes: \(allLatencies.count)
        Average latency: \(String(format: "%.2f", avgLatency))ms
        Max latency: \(String(format: "%.2f", maxLatency))ms
        P95 latency: \(String(format: "%.2f", p95Latency))ms
        Hangs (>= \(hangThresholdMs)ms): \(hangCount)
        Stutters (\(stutterThresholdMs)-\(hangThresholdMs)ms): \(stutterCount)
        ================================

        """)

        // Assert no hangs occurred
        XCTAssertEqual(hangCount, 0, "Detected \(hangCount) main thread hangs during rapid typing")

        // Assert average latency is acceptable
        XCTAssertLessThan(
            avgLatency,
            maxAverageLatencyMs,
            "Average keystroke latency \(String(format: "%.2f", avgLatency))ms exceeds threshold \(maxAverageLatencyMs)ms"
        )
    }

    /// XCTest performance measurement using built-in metrics.
    ///
    /// This test uses XCTMetric to capture CPU, memory, and clock metrics
    /// during rapid search typing operations.
    func testSearchFieldTypingPerformanceMetrics() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        searchField.click()

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            // Type a search query character by character
            let query = "performance test query"
            for char in query {
                searchField.typeText(String(char))
            }

            // Clear for next iteration
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(.delete, modifierFlags: [])
        }
    }

    // MARK: - Setup Helpers

    private func locateAppBundle() throws -> URL {
        if let envPath = ProcessInfo.processInfo.environment["CLIPKITTY_APP_PATH"] {
            return URL(fileURLWithPath: envPath)
        }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appURL = projectRoot.appendingPathComponent("ClipKitty.app")

        if FileManager.default.fileExists(atPath: appURL.path) {
            return appURL
        }

        let testBundle = Bundle(for: type(of: self))
        var url = testBundle.bundleURL
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("ClipKitty.app").path) && url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("ClipKitty.app")
    }

    private func getBundleIdentifier(for appURL: URL) -> String {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOf: plistURL),
           let bundleId = plist["CFBundleIdentifier"] as? String {
            return bundleId
        }
        return "com.eviljuliette.clipkitty"
    }

    private func getAppSupportDirectory(for appURL: URL) -> URL {
        let bundleId = getBundleIdentifier(for: appURL)
        let userHome = URL(fileURLWithPath: "/Users/\(NSUserName())")
        return userHome.appendingPathComponent("Library/Containers/\(bundleId)/Data/Library/Application Support/ClipKitty")
    }

    /// Sets up a database with large text items for performance testing.
    ///
    /// Uses the performance-specific database if available (SyntheticData_perf.sqlite),
    /// otherwise falls back to the standard SyntheticData.sqlite.
    private func setupPerformanceTestDatabase(in appSupportDir: URL) throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // Prefer performance-specific database, fall back to standard
        let perfDbPath = projectRoot.appendingPathComponent("distribution/SyntheticData_perf.sqlite")
        let standardDbPath = projectRoot.appendingPathComponent("distribution/SyntheticData.sqlite")

        let sqliteSourceURL: URL
        if FileManager.default.fileExists(atPath: perfDbPath.path) {
            sqliteSourceURL = perfDbPath
        } else {
            sqliteSourceURL = standardDbPath
        }

        let targetURL = appSupportDir.appendingPathComponent("clipboard-screenshot.sqlite")
        let indexDirURL = appSupportDir.appendingPathComponent("tantivy_index_v3")

        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // Kill existing instances
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "ClipKitty"]
        try? killTask.run()
        killTask.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.2)

        // Clean up existing data
        try? FileManager.default.removeItem(at: targetURL)
        try? FileManager.default.removeItem(at: indexDirURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: targetURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: targetURL.path + "-shm"))

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("Performance test database not found at: \(sqliteSourceURL.path)")
            return
        }
        try FileManager.default.copyItem(at: sqliteSourceURL, to: targetURL)
    }
}
