import XCTest

/// Focused integration coverage for the explicit history-selection surface.
final class ClipKittyiOSSelectionUITests: XCTestCase {
    private var app: XCUIApplication!
    private var databaseDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        databaseDirectory = try makeTestDatabaseDirectory()

        app = XCUIApplication()
        app.launchEnvironment["CLIPKITTY_SCREENSHOT_DB"] = databaseDirectory
            .appendingPathComponent("history.sqlite").path
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-iOSAutoAddFromClipboard", "NO",
            "-iOSSyncEnabled", "NO",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["home.overflowMenuButton"].waitForExistence(timeout: 15))

        // The overflow button itself is never disabled — only its Select
        // menu item is, while the feed still has no rows. Wait for a card to
        // land before opening the menu, or Select can be tapped while still
        // disabled and the tap silently does nothing.
        let firstCard = app.scrollViews.firstMatch.buttons.firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 15))
    }

    /// Opens the overflow menu and taps its Select item. The menu closes
    /// itself after the tap, matching how the rest of the suite treats
    /// selection entry as a single interaction.
    private func beginSelection() {
        app.buttons["home.overflowMenuButton"].tap()
        let selectItem = app.buttons["home.selectMenuItem"]
        XCTAssertTrue(selectItem.waitForExistence(timeout: 5))
        selectItem.tap()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let databaseDirectory {
            try? FileManager.default.removeItem(at: databaseDirectory)
        }
        databaseDirectory = nil
    }

    func testSelectionControlsActions() {
        beginSelection()

        XCTAssertTrue(app.buttons["selection.selectAllButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["selection.doneButton"].exists)
        XCTAssertTrue(app.navigationBars["0 Selected"].exists)

        let firstCard = app.scrollViews.firstMatch.buttons.firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))
        XCTAssertTrue(firstCard.isHittable)
        firstCard.tap()

        XCTAssertTrue(app.navigationBars["1 Selected"].waitForExistence(timeout: 5))
        XCTAssertTrue(firstCard.isSelected)
        XCTAssertTrue(app.buttons["selection.copyButton"].isHittable)
        XCTAssertTrue(app.buttons["selection.deleteButton"].isHittable)

        app.buttons["selection.doneButton"].tap()

        XCTAssertTrue(app.navigationBars["ClipKitty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["selection.doneButton"].exists)
    }

    private func makeTestDatabaseDirectory() throws -> URL {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = projectRoot.appendingPathComponent("distribution/SyntheticData.sqlite")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-selection-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent("history.sqlite")
        )
        return directory
    }
}
