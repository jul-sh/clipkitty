import XCTest

/// Marketing screenshot generator for the iOS App Store listing.
///
/// Captures three screenshots on iPhone 16 Pro Max (6.7-inch, 1290×2796):
///   1. History feed — the main clipboard history view
///   2. Search — search bar active with a query
///   3. Filter — filtered by a content type
///
/// Locale is read from `/tmp/clipkitty_ios_screenshot_locale.txt`.
/// Screenshots are written to `/tmp/clipkitty_ios_{locale}_marketing_{n}_{name}.png`.
final class ClipKittyiOSScreenshotTests: XCTestCase {

    private var app: XCUIApplication!
    private var locale: String!

    override func setUpWithError() throws {
        continueAfterFailure = false

        locale = (try? String(contentsOfFile: "/tmp/clipkitty_ios_screenshot_locale.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "en"

        app = XCUIApplication()

        // Set the UI language for this locale
        app.launchArguments += ["-AppleLanguages", "(\(locale))"]
        app.launchArguments += ["-AppleLocale", locale]
        app.launch()

        // Allow the feed to settle
        sleep(3)
    }

    func testTakeMarketingScreenshots() throws {
        // Screenshot 1: History feed (default state)
        let feedScreenshot = app.screenshot()
        saveScreenshot(feedScreenshot, index: 1, name: "history")

        // Screenshot 2: Search active
        // Tap the search button (magnifying glass)
        let searchButton = app.buttons["Search"]
        if searchButton.waitForExistence(timeout: 5) {
            searchButton.tap()
            sleep(1)

            // Type a search query
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
