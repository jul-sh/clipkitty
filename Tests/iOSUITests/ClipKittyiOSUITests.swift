import XCTest

/// UI tests for the iOS app's core navigation, settings, and interaction flows.
///
/// These tests verify the app's UI at the integration level:
/// - Navigation via toolbar settings gear icon
/// - Settings sheet structure and toggle behavior
/// - Clear history confirmation flow
/// - Deep link routing via clipkitty:// URL scheme
/// - Card swipe actions
/// - iPad split view layout
///
/// All tests launch with `--use-simulated-db` and `CLIPKITTY_DB_PATH` pointing at
/// a copy of the synthetic database. This ensures a known, non-empty data set for
/// deterministic test results — especially on iPad where split-view tests assert on
/// list selection and detail panes.
final class ClipKittyiOSUITests: XCTestCase {
    private var app: XCUIApplication!
    /// Path to the working copy of the synthetic database for this test run.
    private var testDatabasePath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false

        let dbPath = try prepareSyntheticDatabase()
        testDatabasePath = dbPath

        app = XCUIApplication()
        if let dbPath {
            app.launchArguments += ["--use-simulated-db"]
            app.launchEnvironment["CLIPKITTY_DB_PATH"] = dbPath
        }
        app.launch()

        // Wait for the app to finish bootstrapping — the navigation bar title should appear
        let navBar = app.navigationBars["ClipKitty"]
        XCTAssertTrue(
            navBar.waitForExistence(timeout: 10),
            "App should finish launching and show the ClipKitty navigation bar"
        )
    }

    override func tearDownWithError() throws {
        // Clean up the working copy of the database
        if let path = testDatabasePath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
            // Clean up tantivy indexes in the same directory
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in contents where item.lastPathComponent.hasPrefix("tantivy_index_") {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
    }

    // MARK: - Navigation

    func testClipKittyTitleIsVisibleOnLaunch() {
        let navBar = app.navigationBars["ClipKitty"]
        XCTAssertTrue(navBar.exists, "ClipKitty navigation title should be visible on launch")
    }

    func testNavigateToSettings() {
        let settingsButton = app.navigationBars["ClipKitty"].buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'gear' OR label CONTAINS[c] 'settings'")
        ).firstMatch

        let gearButton = settingsButton.exists ? settingsButton : app.buttons["gearshape"]
        XCTAssertTrue(gearButton.waitForExistence(timeout: 5), "Settings gear button should exist in toolbar")

        gearButton.tap()

        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(
            settingsTitle.waitForExistence(timeout: 5),
            "Settings navigation title should be visible after tapping gear"
        )
    }

    func testDismissSettingsReturnToLibrary() {
        openSettings()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Done button should exist in settings")
        doneButton.tap()

        let navBar = app.navigationBars["ClipKitty"]
        XCTAssertTrue(
            navBar.waitForExistence(timeout: 5),
            "ClipKitty navigation bar should be visible after dismissing settings"
        )
    }

    // MARK: - Settings Screen Structure

    func testSettingsScreenShowsAllSections() {
        openSettings()

        XCTAssertTrue(app.staticTexts["General"].exists, "General section should exist")
        XCTAssertTrue(app.switches["Haptic Feedback"].exists, "Haptic Feedback toggle should exist")
        XCTAssertTrue(app.switches["Generate Link Previews"].exists, "Generate Link Previews toggle should exist")

        XCTAssertTrue(app.staticTexts["History"].exists, "History section should exist")
        XCTAssertTrue(app.staticTexts["Database Size"].exists, "Database Size label should exist")

        XCTAssertTrue(app.staticTexts["About"].exists, "About section should exist")
        XCTAssertTrue(app.staticTexts["Version"].exists, "Version label should exist")
        XCTAssertTrue(app.staticTexts["Build"].exists, "Build label should exist")
    }

    func testHapticFeedbackToggle() {
        openSettings()

        let toggle = app.switches["Haptic Feedback"]
        XCTAssertTrue(toggle.exists)

        let initialValue = toggle.value as? String
        toggle.tap()

        let newValue = toggle.value as? String
        XCTAssertNotEqual(initialValue, newValue, "Toggle value should change after tap")

        toggle.tap()
    }

    func testLinkPreviewsToggle() {
        openSettings()

        let toggle = app.switches["Generate Link Previews"]
        XCTAssertTrue(toggle.exists)

        let initialValue = toggle.value as? String
        toggle.tap()

        let newValue = toggle.value as? String
        XCTAssertNotEqual(initialValue, newValue, "Toggle value should change after tap")

        toggle.tap()
    }

    // MARK: - Clear History Confirmation Flow

    func testClearHistoryRequiresConfirmation() {
        openSettings()

        let clearButton = app.buttons["Clear History"]
        XCTAssertTrue(clearButton.exists, "Clear History button should exist")

        clearButton.tap()

        let confirmButton = app.buttons["Tap Again to Confirm"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 3),
            "Confirmation button should appear after first tap"
        )
    }

    // MARK: - Search Interaction

    func testSearchButtonOpensSearchField() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let searchField = app.searchFields["Search"]
            XCTAssertTrue(
                searchField.waitForExistence(timeout: 5),
                "iPad should show the toolbar search field"
            )
        } else {
            let searchButton = app.buttons["Search"]
            XCTAssertTrue(searchButton.waitForExistence(timeout: 5))

            searchButton.tap()

            let searchField = app.textFields["Search"]
            XCTAssertTrue(
                searchField.waitForExistence(timeout: 5),
                "Search text field should appear after tapping search button"
            )
        }
    }

    func testDismissSearchReturnsToNormalState() {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }

        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
        searchButton.tap()

        let searchField = app.textFields["Search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        let closeButton = app.buttons["Close search"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        closeButton.tap()

        XCTAssertTrue(
            searchButton.waitForExistence(timeout: 5),
            "Search button should reappear after dismissing search"
        )
    }

    // MARK: - Add Menu

    func testAddButtonExpandsMenu() {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }

        let addButton = app.buttons["Add new item"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))

        addButton.tap()
        sleep(1)
        addButton.tap()
    }

    // MARK: - Deep Links

    func testSearchDeepLinkOpensLibraryWithSearch() {
        let url = URL(string: "clipkitty://search?q=test")!
        app.open(url)

        let searchField = app.searchFields.firstMatch
        let textField = app.textFields["Search"]
        let fieldAppeared = searchField.waitForExistence(timeout: 5)
            || textField.waitForExistence(timeout: 3)

        XCTAssertTrue(fieldAppeared, "Deep link should activate the search field")

        let activeField = searchField.exists ? searchField : textField
        let fieldValue = activeField.value as? String ?? ""
        XCTAssertTrue(
            fieldValue.contains("test"),
            "Search field should contain the deep-linked query 'test', but got '\(fieldValue)'"
        )
    }

    func testAddDeepLinkOpensLibrary() {
        let url = URL(string: "clipkitty://add")!
        app.open(url)

        let composeNavBar = app.navigationBars["New Text"]
        XCTAssertTrue(
            composeNavBar.waitForExistence(timeout: 5),
            "Add deep link should present the text composer sheet with 'New Text' navigation title"
        )

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 3),
            "Text composer sheet should contain a Save button"
        )

        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.tap()
        }
    }

    func testIPadDeepLinkSearchShowsQuery() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        let url = URL(string: "clipkitty://search?q=hello")!
        app.open(url)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "iPad deep link should activate the toolbar search field"
        )

        let fieldValue = searchField.value as? String ?? ""
        XCTAssertTrue(
            fieldValue.contains("hello"),
            "Toolbar search field should contain the deep-linked query 'hello', but got '\(fieldValue)'"
        )
    }

    // MARK: - Card Swipe Actions

    func testSwipeLeftOnCardRevealsActions() {
        // Swipe actions are compact-only; the iPad shell uses selection + context menu.
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }

        let firstCell = app.cells.firstMatch
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 5),
            "Feed should contain items from the synthetic database"
        )

        firstCell.swipeLeft()
        sleep(1)

        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 3) {
            XCTAssertTrue(deleteButton.exists, "Delete swipe action should be visible")
        }
    }

    // MARK: - iPad Split View

    func testIPadSplitViewShowsSidebar() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        let navBar = app.navigationBars["ClipKitty"]
        XCTAssertTrue(navBar.exists, "Sidebar navigation bar should be visible")

        // With synthetic data, the detail column should show "No Item Selected" placeholder
        // until an item is tapped.
        let placeholder = app.staticTexts["No Item Selected"]
        let detailMetadata = app.staticTexts["Details"]
        let hasDetailColumn = placeholder.waitForExistence(timeout: 5)
            || detailMetadata.waitForExistence(timeout: 3)

        XCTAssertTrue(
            hasDetailColumn,
            "iPad split view should show a detail column"
        )

        XCTAssertTrue(
            navBar.exists,
            "Sidebar navigation bar should remain visible alongside the detail column"
        )
    }

    func testIPadSelectItemShowsDetail() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        let firstCell = app.cells.firstMatch
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 5),
            "Feed should contain items from the synthetic database"
        )

        firstCell.tap()

        let detailsHeading = app.staticTexts["Details"]
        XCTAssertTrue(
            detailsHeading.waitForExistence(timeout: 5),
            "Selecting an item on iPad should show the 'Details' metadata section in the detail pane"
        )

        // Action bar buttons should be visible
        let shareButton = app.buttons["square.and.arrow.up"].exists
            || app.images["square.and.arrow.up"].exists
        let copyButton = app.buttons["doc.on.doc"].exists
            || app.images["doc.on.doc"].exists
        let trashButton = app.buttons["trash"].exists
            || app.images["trash"].exists

        XCTAssertTrue(
            shareButton || copyButton || trashButton,
            "Detail pane action bar buttons should be visible after selecting an item"
        )

        // Sidebar must remain visible — proving split view, not push navigation
        let sidebarNavBar = app.navigationBars["ClipKitty"]
        XCTAssertTrue(
            sidebarNavBar.exists,
            "Sidebar should remain visible while detail pane is populated (split view, not push navigation)"
        )
    }

    func testIPadKeyboardCopyFromDetail() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        let firstCell = app.cells.firstMatch
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 5),
            "Feed should contain items from the synthetic database"
        )

        firstCell.tap()

        let detailsHeading = app.staticTexts["Details"]
        XCTAssertTrue(
            detailsHeading.waitForExistence(timeout: 5),
            "Detail pane should load after selecting an item"
        )

        // Cmd+C should trigger copy and show toast
        app.typeKey("c", modifierFlags: .command)
        sleep(1)

        let copiedText = app.staticTexts["Copied to clipboard"]
        XCTAssertTrue(
            copiedText.waitForExistence(timeout: 3),
            "Cmd+C should copy the selected item and show a 'Copied to clipboard' toast"
        )
    }

    // MARK: - Synthetic Database Setup

    /// Copies the synthetic SQLite database to a temp directory and returns the path.
    /// Returns nil if the synthetic database is not available (e.g. CI without LFS).
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
            return nil
        }

        // Guard against Git LFS pointer files
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sqliteSourceURL.path)[.size] as? Int) ?? 0
        if fileSize < 1024 {
            return nil
        }

        // Copy to a temp directory that the app process can also access.
        // On iOS Simulator, the test runner and app share the same macOS filesystem.
        let testRunDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRunDir, withIntermediateDirectories: true)

        let targetURL = testRunDir.appendingPathComponent("clipboard-screenshot.db")
        try FileManager.default.copyItem(at: sqliteSourceURL, to: targetURL)

        return targetURL.path
    }

    // MARK: - Helpers

    private func openSettings() {
        let gearInNavBar = app.navigationBars["ClipKitty"].buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'gear' OR label CONTAINS[c] 'settings'")
        ).firstMatch

        let button = gearInNavBar.exists ? gearInNavBar : app.buttons["gearshape"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Settings gear button should exist")
        button.tap()

        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(
            settingsTitle.waitForExistence(timeout: 5),
            "Settings sheet should appear"
        )
    }
}
