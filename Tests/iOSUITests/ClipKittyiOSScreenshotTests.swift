import XCTest

/// Marketing screenshot generator for the iOS App Store listing.
///
/// Captures three screenshots on either iPhone 17 (6.1-inch, 1206x2622;
/// uploaded to ASC's IPHONE_61 slot) or iPad Pro 13-inch M5 (2064x2752;
/// uploaded to ASC's IPAD_PRO_3GEN_129 slot). The scenes are identical
/// across devices; only the simulator chosen by the xcodebuild
/// destination differs.
///   1. History feed; the main clipboard history view
///   2. Search; search bar active with a query
///   3. Filter; filtered by a content type
///
/// Locale is read from `/tmp/clipkitty_ios_screenshot_locale.txt`.
/// Database filename is read from `/tmp/clipkitty_ios_screenshot_db.txt`.
/// Device kind (`iphone` or `ipad`) is read from
/// `/tmp/clipkitty_ios_screenshot_device.txt` and picks the output
/// filename prefix so back-to-back iPhone and iPad runs don't overwrite
/// each other's PNGs.
/// Screenshots are written to
/// `/tmp/clipkitty_{ios|ipad}_[{locale}_]marketing_{n}_{name}.png`
/// (the locale segment is omitted for English, matching the existing
/// iPhone behaviour).
final class ClipKittyiOSScreenshotTests: XCTestCase {
    private enum DeviceKind {
        case iPhone
        case iPad

        var filenameStem: String {
            switch self {
            case .iPhone: return "ios"
            case .iPad: return "ipad"
            }
        }
    }

    private var app: XCUIApplication!
    private var locale: String!
    private var deviceKind: DeviceKind = .iPhone

    private static let localeConfigFile = "clipkitty_ios_screenshot_locale.txt"
    private static let dbConfigFile = "clipkitty_ios_screenshot_db.txt"
    private static let deviceConfigFile = "clipkitty_ios_screenshot_device.txt"

    override func setUpWithError() throws {
        continueAfterFailure = false

        locale = readTempConfig(Self.localeConfigFile, defaultValue: "en") ?? "en"
        deviceKind = (readTempConfig(Self.deviceConfigFile, defaultValue: "iphone") ?? "iphone")
            == "ipad" ? .iPad : .iPhone

        let screenshotDBPath = try setupTestDatabase()

        app = XCUIApplication()
        app.launchEnvironment["CLIPKITTY_SCREENSHOT_DB"] = screenshotDBPath

        // Set the UI language for this locale
        app.launchArguments += ["-AppleLanguages", "(\(locale!))"]
        app.launchArguments += ["-AppleLocale", locale]
        app.launch()

        // Let the feed mount and the visible cards kick off their image
        // fetch/decode tasks (the settled signal below can only be trusted
        // once loading has actually started), then wait for the app to report
        // every in-flight image load finished. The signal-based wait replaced
        // fixed sleeps because no guessed duration survived a loaded CI
        // runner: 8s and 15s settles both shipped placeholder cards to the
        // App Store (runs 28795788433 and the iPhone follow-up).
        sleep(3)
        waitForFeedSettled(context: "initial feed")
    }

    func testTakeMarketingScreenshots() {
        // All UI lookups use stable accessibilityIdentifier values so this
        // test works under every locale. If an element can't be found, fail
        // loudly — silent fallthrough produces duplicate screenshots that
        // ship to the App Store unnoticed.

        // Screenshot 1: History feed (default state)
        let feedScreenshot = captureScreen()
        saveScreenshot(feedScreenshot, index: 1, name: "history")

        // Screenshot 2: Fuzzy search in action. "dockr push" has a
        // deliberate typo ("dockr"→docker) to showcase the typo-tolerant
        // fuzzy matcher. Both "docker" and "push" appear verbatim in every
        // locale's synthetic DB (technical tokens in untranslated shell
        // commands), so the same query works across all locales.
        let searchButton = app.buttons["bottomBar.searchButton"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5),
                      "bottomBar.searchButton not found for locale \(locale!)")
        searchButton.tap()
        sleep(1)

        // Dismiss the iOS keyboard "slide to type" tutorial if it appears
        dismissKeyboardTutorial()

        let searchField = app.textFields["bottomBar.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "bottomBar.searchField not found for locale \(locale!)")
        searchField.typeText("dockr push")
        sleep(2)
        waitForFeedSettled(context: "search results")

        let searchScreenshot = captureScreen()
        saveScreenshot(searchScreenshot, index: 2, name: "search")

        // Dismiss search
        let closeButton = app.buttons["bottomBar.closeSearchButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3),
                      "bottomBar.closeSearchButton not found for locale \(locale!)")
        closeButton.tap()
        sleep(1)

        // Screenshot 3: Filtered view (by Images)
        let filterPill = app.buttons["bottomBar.filterPill"]
        XCTAssertTrue(filterPill.waitForExistence(timeout: 5),
                      "bottomBar.filterPill not found for locale \(locale!)")
        filterPill.tap()
        sleep(1)

        let imagesFilter = app.buttons["bottomBar.filterOption.images"]
        XCTAssertTrue(imagesFilter.waitForExistence(timeout: 3),
                      "bottomBar.filterOption.images not found for locale \(locale!)")
        imagesFilter.tap()
        // Filtering down to images surfaces a screenful of image cards
        // simultaneously; each one async-loads and decodes its
        // full-resolution data, and on a loaded few-core CI runner that
        // burst takes well over 15s end to end. The settled signal is keyed
        // to the images filter, so it can't fire off the still-displayed
        // pre-filter rows; it flips only once the filtered content is loaded
        // and its image burst has finished — this capture is the one that
        // ships to the App Store, and it must never ship a placeholder card.
        sleep(2)
        waitForFeedSettled(filterKind: "images", context: "images filter")

        let filterScreenshot = captureScreen()
        saveScreenshot(filterScreenshot, index: 3, name: "filter")
    }

    // MARK: - Image-load settling

    /// Blocks until the app reports the feed fully settled for the given
    /// filter, via the feed's load-state accessibility identifier
    /// (`feed.<filterKind>.settled`, the iOS counterpart of the Mac's
    /// `ResultsState_<kind>_loaded` signal): the filter's query has loaded
    /// and every in-flight card image fetch/decode has finished. Deterministic
    /// on purpose — fixed sleeps kept shipping mid-decode captures on loaded
    /// CI runners.
    ///
    /// The timeout is a failure backstop, not pacing — the wait returns as
    /// soon as the app settles. 240s accommodates a cold CI runner decoding a
    /// screenful of full-resolution marketing images behind a utility-QoS
    /// queue (each wedge-netted at 60s in `DecodedImageView.decodeOffPool`).
    private func waitForFeedSettled(
        filterKind: String = "all",
        timeout: TimeInterval = 240,
        context: String
    ) {
        let settled = app.descendants(matching: .any)["feed.\(filterKind).settled"]
        XCTAssertTrue(
            settled.waitForExistence(timeout: timeout),
            "Feed did not settle within \(Int(timeout))s (\(context), locale \(locale!)) — capturing would ship placeholder cards"
        )
        // One extra beat so the final decoded frame reaches the display
        // buffer that `XCUIScreen.main.screenshot()` grabs.
        sleep(1)
    }

    // MARK: - Screen capture

    /// Captures the whole display via `XCUIScreen`, deliberately *not*
    /// `XCUIApplication.screenshot()`.
    ///
    /// `app.screenshot()` resolves the app through a UI query that first waits
    /// for the app to report idle. The packed iPad feed does a burst of layout
    /// and async image-decode work as cards appear, and on a loaded CI runner
    /// that burst can outlast the automation idle timeout — the query then
    /// fails with "Timed out while evaluating UI query" and no screenshot is
    /// produced at all. `XCUIScreen.main.screenshot()` grabs the display buffer
    /// directly with no idle query, so once we have given the feed our own
    /// settle time the capture always succeeds. Callers still drive the UI
    /// through `app`'s element queries (with their own short waits); only the
    /// final pixel grab bypasses the app-idle wait.
    private func captureScreen() -> XCUIScreenshot {
        XCUIScreen.main.screenshot()
    }

    // MARK: - Database Setup

    /// Copies the locale-appropriate SyntheticData.sqlite to a temp path and returns
    /// the path for the app to use via `CLIPKITTY_SCREENSHOT_DB` environment variable.
    private func setupTestDatabase() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // iOSUITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // project root

        let databaseFilename = readTempConfig(Self.dbConfigFile, defaultValue: "SyntheticData.sqlite") ?? "SyntheticData.sqlite"
        let sqliteSourceURL = projectRoot.appendingPathComponent("distribution/\(databaseFilename)")

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("\(databaseFilename) not found at: \(sqliteSourceURL.path). Run 'git lfs pull' and ensure distribution/SyntheticData*.sqlite is checked out.")
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
        // Blow away any Tantivy index dirs next to the target — otherwise
        // a prior locale's index persists across runs and we end up
        // searching stale content (the bootstrap check returns Ready
        // when the index is populated, even if its docs don't match the
        // sqlite file we just copied in).
        let tmpDir = URL(fileURLWithPath: "/tmp")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path) {
            for name in contents where name.hasPrefix("tantivy_index_") {
                try? FileManager.default.removeItem(atPath: tmpDir.appendingPathComponent(name).path)
            }
        }
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
        let localePrefix = locale == "en" ? "" : "\(locale!)_"
        let filename = "clipkitty_\(deviceKind.filenameStem)_\(localePrefix)marketing_\(index)_\(name).png"
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
