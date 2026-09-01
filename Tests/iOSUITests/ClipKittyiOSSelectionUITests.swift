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

        let selectButton = app.buttons["home.selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 15))
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: selectButton
        )
        waitForExpectations(timeout: 15)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let databaseDirectory {
            try? FileManager.default.removeItem(at: databaseDirectory)
        }
        databaseDirectory = nil
    }

    func testSelectionControlsActionsAndSearchHandoff() {
        app.buttons["home.selectButton"].tap()

        XCTAssertTrue(app.buttons["selection.selectAllButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["selection.doneButton"].exists)
        XCTAssertTrue(app.buttons["selection.searchButton"].exists)
        XCTAssertTrue(app.navigationBars["0 Selected"].exists)

        let firstCard = app.scrollViews.firstMatch.buttons.firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))
        XCTAssertTrue(firstCard.isHittable)
        firstCard.tap()

        XCTAssertTrue(app.navigationBars["1 Selected"].waitForExistence(timeout: 5))
        XCTAssertTrue(firstCard.isSelected)
        XCTAssertTrue(app.buttons["selection.copyButton"].isHittable)
        XCTAssertTrue(app.buttons["selection.deleteButton"].isHittable)

        app.buttons["selection.searchButton"].tap()

        let searchField = app.textFields["bottomBar.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["selection.doneButton"].exists)
        XCTAssertTrue(app.navigationBars["ClipKitty"].exists)
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
