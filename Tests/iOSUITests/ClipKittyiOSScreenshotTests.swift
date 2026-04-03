import XCTest

/// Marketing screenshot generator for the iOS App Store listing.
///
/// Captures three screenshots each for iPhone and iPad:
///   - iPhone: History feed, Search, Filter (via BottomControlBar)
///   - iPad: Split view with detail, Search (via toolbar), Filter (via toolbar menu)
///
/// Requires synthetic data: the test copies `distribution/SyntheticData.sqlite`
/// to a temp directory and passes the path via `CLIPKITTY_DB_PATH` environment
/// variable. The app detects `--use-simulated-db` and uses this path.
///
/// Locale is read from `/tmp/clipkitty_ios_screenshot_locale.txt`.
/// Database variant from `/tmp/clipkitty_ios_screenshot_db.txt`.
/// Screenshots are written to `/tmp/clipkitty_{ios|ipad}_{locale}_marketing_{n}_{name}.png`.
final class ClipKittyiOSScreenshotTests: XCTestCase {

    private var app: XCUIApplication!
    private var locale: String!
    private var testDatabasePath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false

        locale = (try? String(contentsOfFile: "/tmp/clipkitty_ios_screenshot_locale.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "en"

        let dbPath = try prepareSyntheticDatabase()
        testDatabasePath = dbPath

        app = XCUIApplication()
        if let dbPath {
            app.launchArguments += ["--use-simulated-db"]
            app.launchEnvironment["CLIPKITTY_DB_PATH"] = dbPath
        }
        app.launchArguments += ["-AppleLanguages", "(\(locale!))"]
        app.launchArguments += ["-AppleLocale", locale]
        app.launch()

        // Allow the feed to settle
        sleep(3)
    }

    override func tearDownWithError() throws {
        if let path = testDatabasePath {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - iPhone Marketing Screenshots

    func testTakeMarketingScreenshots() throws {
        // Screenshot 1: History feed (default state)
        let feedScreenshot = app.screenshot()
        saveScreenshot(feedScreenshot, index: 1, name: "history")

        // Screenshot 2: Search active
        let searchButton = app.buttons["Search"]
        if searchButton.waitForExistence(timeout: 5) {
            searchButton.tap()
            sleep(1)

            let searchField = app.textFields["Search"]
            if searchField.waitForExistence(timeout: 3) {
                searchField.typeText("clipboard")
                sleep(2)
            }
        }

        let searchScreenshot = app.screenshot()
        saveScreenshot(searchScreenshot, index: 2, name: "search")

        // Dismiss search
        let closeButton = app.buttons["Close search"]
        if closeButton.waitForExistence(timeout: 3) {
            closeButton.tap()
            sleep(1)
        }

        // Screenshot 3: Filtered view (e.g., by Images)
        let filterPill = app.buttons.matching(NSPredicate(format: "label CONTAINS 'All' OR label CONTAINS 'chevron'")).firstMatch
        if filterPill.waitForExistence(timeout: 5) {
            filterPill.tap()
            sleep(1)

            let imagesFilter = app.buttons["Images"]
            if imagesFilter.waitForExistence(timeout: 3) {
                imagesFilter.tap()
                sleep(2)
            }
        }

        let filterScreenshot = app.screenshot()
        saveScreenshot(filterScreenshot, index: 3, name: "filter")
    }

    // MARK: - iPad Marketing Screenshots

    func testTakeIPadMarketingScreenshots() throws {
        // Screenshot 1: Split-view layout with detail populated
        let firstCell = app.cells.firstMatch
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 10),
            "Feed should contain items from the synthetic database"
        )
        firstCell.tap()
        sleep(2)

        let splitScreenshot = app.screenshot()
        saveScreenshot(splitScreenshot, index: 1, name: "split_view", device: "ipad")

        // Screenshot 2: Search active via toolbar .searchable
        let searchField = app.searchFields["Search"]
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            sleep(1)
            searchField.typeText("clipboard")
            sleep(2)
        }

        let searchScreenshot = app.screenshot()
        saveScreenshot(searchScreenshot, index: 2, name: "search", device: "ipad")

        // Dismiss search
        let cancelButton = app.buttons["Cancel"]
        if cancelButton.waitForExistence(timeout: 3) {
            cancelButton.tap()
            sleep(1)
        }

        // Screenshot 3: Filtered view via toolbar menu
        let filterButton = app.buttons["All"]
        if filterButton.waitForExistence(timeout: 5) {
            filterButton.tap()
            sleep(1)

            let imagesOption = app.buttons["Images"]
            if imagesOption.waitForExistence(timeout: 3) {
                imagesOption.tap()
                sleep(2)
            }
        }

        let filterScreenshot = app.screenshot()
        saveScreenshot(filterScreenshot, index: 3, name: "filter", device: "ipad")
    }

    // MARK: - Synthetic Database Setup

    /// Copies the synthetic SQLite database to a temp directory and returns the path.
    private func prepareSyntheticDatabase() throws -> String? {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let databaseFilename: String
        if let configured = try? String(contentsOfFile: "/tmp/clipkitty_ios_screenshot_db.txt", encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            databaseFilename = configured
        } else {
            databaseFilename = "SyntheticData.sqlite"
        }

        let sqliteSourceURL = projectRoot.appendingPathComponent("distribution/\(databaseFilename)")

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("\(databaseFilename) not found at: \(sqliteSourceURL.path)")
            return nil
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sqliteSourceURL.path)[.size] as? Int) ?? 0
        if fileSize < 1024 {
            let headerData = FileManager.default.contents(atPath: sqliteSourceURL.path).flatMap { data in
                String(data: data.prefix(64), encoding: .utf8)
            }
            if headerData?.contains("git-lfs.github.com") == true {
                XCTFail("Git LFS pointer not resolved for \(databaseFilename). Run 'git lfs pull' first.")
                return nil
            }
            XCTFail("\(databaseFilename) is too small (\(fileSize) bytes).")
            return nil
        }

        let testRunDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty_screenshot_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRunDir, withIntermediateDirectories: true)

        let targetURL = testRunDir.appendingPathComponent("clipboard-screenshot.db")
        try FileManager.default.copyItem(at: sqliteSourceURL, to: targetURL)

        let copiedSize = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(copiedSize, 1024,
                             "Copied database is too small (\(copiedSize) bytes)")

        return targetURL.path
    }

    // MARK: - Screenshot Helpers

    private func saveScreenshot(_ screenshot: XCUIScreenshot, index: Int, name: String, device: String = "ios") {
        let prefix = locale == "en" ? "" : "\(locale!)_"
        let filename = "clipkitty_\(device)_\(prefix)marketing_\(index)_\(name).png"
        let path = "/tmp/\(filename)"

        let data = screenshot.pngRepresentation
        FileManager.default.createFile(atPath: path, contents: data)
        print("Saved screenshot: \(path)")

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "marketing_\(index)_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
