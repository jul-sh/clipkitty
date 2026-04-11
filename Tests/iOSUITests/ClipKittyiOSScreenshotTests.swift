import XCTest

/// Marketing screenshot generator for the iOS App Store listing.
///
/// Captures three screenshots on iPhone 17 Pro Max (6.7-inch, 1290×2796):
///   1. History feed — the main clipboard history view
///   2. Search — search bar active with a query
///   3. Filter — filtered by a content type
///
/// Locale is read from `/tmp/clipkitty_ios_screenshot_locale.txt`.
/// Database filename is read from `/tmp/clipkitty_ios_screenshot_db.txt`.
/// Screenshots are written to `/tmp/clipkitty_ios_{locale}_marketing_{n}_{name}.png`.
final class ClipKittyiOSScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var locale: String!

    private static let localeConfigFile = "clipkitty_ios_screenshot_locale.txt"
    private static let dbConfigFile = "clipkitty_ios_screenshot_db.txt"

    override func setUpWithError() throws {
        continueAfterFailure = false

        locale = readTempConfig(Self.localeConfigFile, defaultValue: "en") ?? "en"

        let screenshotDBPath = try setupTestDatabase()

        app = XCUIApplication()
        app.launchEnvironment["CLIPKITTY_SCREENSHOT_DB"] = screenshotDBPath

        // Set the UI language for this locale
        app.launchArguments += ["-AppleLanguages", "(\(locale!))"]
        app.launchArguments += ["-AppleLocale", locale]
        app.launch()

        // Allow the feed to settle
        sleep(3)
    }

    func testTakeMarketingScreenshots() {
        // Screenshot 1: History feed (default state)
        let feedScreenshot = app.screenshot()
        saveScreenshot(feedScreenshot, index: 1, name: "history")

        // Screenshot 2: Fuzzy search in action (typo-tolerant: "dockr"→docker, "prodction"→production)
        let searchButton = app.buttons["Search"]
        if searchButton.waitForExistence(timeout: 5) {
            searchButton.tap()
            sleep(1)

            // Dismiss the iOS keyboard "slide to type" tutorial if it appears
            dismissKeyboardTutorial()

            let searchField = app.textFields["Search"]
            if searchField.waitForExistence(timeout: 3) {
                searchField.typeText("dockr push prodction")
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
        // Find and tap the filter pill to expand it
        let filterPill = app.buttons.matching(NSPredicate(format: "label CONTAINS 'All' OR label CONTAINS 'chevron'")).firstMatch
        if filterPill.waitForExistence(timeout: 5) {
            filterPill.tap()
            sleep(1)

            // Tap "Images" filter if available
            let imagesFilter = app.buttons["Images"]
            if imagesFilter.waitForExistence(timeout: 3) {
                imagesFilter.tap()
                sleep(2)
            }
        }

        let filterScreenshot = app.screenshot()
        saveScreenshot(filterScreenshot, index: 3, name: "filter")
    }

    // MARK: - Database Setup

    /// Copies the locale-appropriate SyntheticData.sqlite to a temp path and returns
    /// the path for the app to use via `CLIPKITTY_SCREENSHOT_DB` environment variable.
    /// Resolve the project root directory. Checks, in order:
    /// 1. Bazel runfiles via TEST_SRCDIR (set by Bazel test runner)
    /// 2. #filePath (works when the source path is absolute)
    private func resolveProjectRoot() -> URL {
        if let srcdir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let candidate = URL(fileURLWithPath: srcdir).appendingPathComponent("__main__")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("distribution").path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func setupTestDatabase() throws -> String {
        let projectRoot = resolveProjectRoot()

        let databaseFilename = readTempConfig(Self.dbConfigFile, defaultValue: "SyntheticData.sqlite") ?? "SyntheticData.sqlite"
        let sqliteSourceURL = projectRoot.appendingPathComponent("distribution/\(databaseFilename)")

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("\(databaseFilename) not found at: \(sqliteSourceURL.path). Run 'git lfs pull' and 'make -C distribution synthetic-data'.")
            return ""
        }

        // Guard against Git LFS pointer files
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sqliteSourceURL.path)[.size] as? Int) ?? 0
        if fileSize < 1024 {
            let headerData = FileManager.default.contents(atPath: sqliteSourceURL.path).flatMap { data in
                String(data: data.prefix(64), encoding: .utf8)
            }
            if headerData?.contains("git-lfs.github.com") == true {
                XCTFail("Git LFS pointer not resolved for \(databaseFilename). Run 'git lfs pull' first.")
                return ""
            }
            XCTFail("\(databaseFilename) is too small (\(fileSize) bytes) — likely corrupt or an LFS pointer.")
            return ""
        }

        // Copy to a temp location the app can read
        let targetPath = "/tmp/clipkitty_ios_screenshot.sqlite"
        try? FileManager.default.removeItem(atPath: targetPath)
        // Also remove WAL/SHM companions
        try? FileManager.default.removeItem(atPath: targetPath + "-wal")
        try? FileManager.default.removeItem(atPath: targetPath + "-shm")
        try FileManager.default.copyItem(atPath: sqliteSourceURL.path, toPath: targetPath)

        let copiedSize = (try? FileManager.default.attributesOfItem(atPath: targetPath)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(copiedSize, 1024,
                             "Copied database is too small (\(copiedSize) bytes). Target: \(targetPath)")

        return targetPath
    }

    // MARK: - Keyboard Tutorial

    /// Dismiss the iOS keyboard's "slide to type" onboarding overlay if it appears.
    /// The overlay has a "Continue" button that must be tapped to reveal the normal keyboard.
    private func dismissKeyboardTutorial() {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 2) {
            continueButton.tap()
            sleep(1)
        }
    }

    // MARK: - Helpers

    private func readTempConfig(_ filename: String, defaultValue: String? = nil) -> String? {
        if let content = try? String(contentsOfFile: "/tmp/\(filename)", encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return defaultValue
    }

    private func saveScreenshot(_ screenshot: XCUIScreenshot, index: Int, name: String) {
        let prefix = locale == "en" ? "" : "\(locale!)_"
        let filename = "clipkitty_ios_\(prefix)marketing_\(index)_\(name).png"
        let path = "/tmp/\(filename)"

        let data = screenshot.pngRepresentation
        FileManager.default.createFile(atPath: path, contents: data)
        print("Saved screenshot: \(path)")

        // Also add as XCTest attachment for artifact collection
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "marketing_\(index)_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
