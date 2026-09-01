import XCTest

/// Integration coverage for the clipboard-permission feed card and the
/// allow-access flow it opens.
final class ClipKittyiOSPermissionFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var databaseDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        databaseDirectory = try makeTestDatabaseDirectory()

        app = XCUIApplication()
        // The card renders inside the feed, so the feed needs content.
        app.launchEnvironment["CLIPKITTY_SCREENSHOT_DB"] = databaseDirectory
            .appendingPathComponent("history.sqlite").path
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-iOSAutoAddFromClipboard", "NO",
            "-iOSSyncEnabled", "NO",
            // Plist literal, not "NO": the argument domain keeps bare YES/NO
            // as strings, which the settings store's `as? Bool` read ignores.
            // A prior run's dismissal persists in standard defaults, so the
            // card only reliably shows with the override in place.
            "-iOSPermissionHintDismissed", "<false/>",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let databaseDirectory {
            try? FileManager.default.removeItem(at: databaseDirectory)
        }
        databaseDirectory = nil
    }

    func testCardOpensFlowAndHowToSheet() {
        let card = app.buttons["home.permissionCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Permission card should top the feed")
        attachScreenshot(named: "feed-permission-card")
        card.tap()

        let allowButton = app.buttons["permissionFlow.allowButton"]
        XCTAssertTrue(allowButton.waitForExistence(timeout: 5), "Save Automatically sheet should open")
        XCTAssertTrue(app.buttons["permissionFlow.laterButton"].exists)
        attachScreenshot(named: "save-automatically-sheet")
        allowButton.tap()

        let openSettingsButton = app.buttons["permissionFlow.openSettingsButton"]
        XCTAssertTrue(openSettingsButton.waitForExistence(timeout: 5), "How-to sheet should stack on top")
        XCTAssertFalse(
            app.buttons["permissionFlow.doneButton"].exists,
            "Done should only appear after the user heads to Settings"
        )
        attachScreenshot(named: "how-to-sheet")

        // ✕ closes only the how-to sheet; the first sheet is still up.
        app.buttons["permissionFlow.closeButton"].tap()
        XCTAssertTrue(allowButton.waitForExistence(timeout: 5))

        // "Enable Later in Settings" closes the flow but keeps the card
        // around for another attempt.
        app.buttons["permissionFlow.laterButton"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testOpenSettingsSwitchesPrimaryActionToDone() {
        let card = app.buttons["home.permissionCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()

        let allowButton = app.buttons["permissionFlow.allowButton"]
        XCTAssertTrue(allowButton.waitForExistence(timeout: 5))
        allowButton.tap()

        let openSettingsButton = app.buttons["permissionFlow.openSettingsButton"]
        XCTAssertTrue(openSettingsButton.waitForExistence(timeout: 5))
        openSettingsButton.tap()

        // The Settings app takes over; come back to finish the flow.
        app.activate()

        let doneButton = app.buttons["permissionFlow.doneButton"]
        XCTAssertTrue(
            doneButton.waitForExistence(timeout: 10),
            "Done should be the primary action after visiting Settings"
        )
        XCTAssertTrue(openSettingsButton.exists, "Open Settings should remain available")
        attachScreenshot(named: "how-to-sheet-done")
        doneButton.tap()

        XCTAssertTrue(
            card.waitForNonExistence(timeout: 5),
            "Finishing the flow should retire the feed card"
        )
    }

    func testDismissHidesCard() {
        let card = app.buttons["home.permissionCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))

        app.buttons["home.permissionCardDismiss"].tap()

        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "✕ should hide the card")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeTestDatabaseDirectory() throws -> URL {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = projectRoot.appendingPathComponent("distribution/SyntheticData.sqlite")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-permission-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent("history.sqlite")
        )
        return directory
    }
}
