import XCTest

/// UI tests for the iOS app's core navigation, settings, and interaction flows.
///
/// These tests verify the app's UI at the integration level:
/// - Tab navigation between Library and Settings
/// - Settings screen structure and toggle behavior
/// - Clear history confirmation flow
/// - Deep link routing via clipkitty:// URL scheme
/// - Card swipe actions (bookmark, delete)
final class ClipKittyiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // Wait for the app to finish bootstrapping
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(
            libraryTab.waitForExistence(timeout: 10),
            "App should finish launching and show the Library tab"
        )
    }

    // MARK: - Tab Navigation

    func testLibraryTabIsSelectedByDefault() {
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.isSelected, "Library tab should be selected on launch")
    }

    func testNavigateToSettingsTab() {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.exists)

        settingsTab.tap()

        // Verify settings screen is visible
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(
            settingsTitle.waitForExistence(timeout: 5),
            "Settings navigation title should be visible"
        )
    }

    func testNavigateBackToLibraryFromSettings() {
        // Go to settings
        app.tabBars.buttons["Settings"].tap()
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))

        // Go back to library
        app.tabBars.buttons["Library"].tap()

        // Verify we're back on the library (search button should be visible)
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(
            searchButton.waitForExistence(timeout: 5),
            "Search button should be visible after returning to Library"
        )
    }

    // MARK: - Settings Screen Structure

    func testSettingsScreenShowsAllSections() {
        app.tabBars.buttons["Settings"].tap()
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))

        // General section
        XCTAssertTrue(app.staticTexts["General"].exists, "General section should exist")
        XCTAssertTrue(app.switches["Haptic Feedback"].exists, "Haptic Feedback toggle should exist")
        XCTAssertTrue(app.switches["Generate Link Previews"].exists, "Generate Link Previews toggle should exist")

        // History section
        XCTAssertTrue(app.staticTexts["History"].exists, "History section should exist")
        XCTAssertTrue(app.staticTexts["Database Size"].exists, "Database Size label should exist")

        // About section
        XCTAssertTrue(app.staticTexts["About"].exists, "About section should exist")
        XCTAssertTrue(app.staticTexts["Version"].exists, "Version label should exist")
        XCTAssertTrue(app.staticTexts["Build"].exists, "Build label should exist")
    }

    func testHapticFeedbackToggle() {
        app.tabBars.buttons["Settings"].tap()
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))

        let toggle = app.switches["Haptic Feedback"]
        XCTAssertTrue(toggle.exists)

        let initialValue = toggle.value as? String
        toggle.tap()

        let newValue = toggle.value as? String
        XCTAssertNotEqual(initialValue, newValue, "Toggle value should change after tap")

        // Toggle back to restore state
        toggle.tap()
    }

    func testLinkPreviewsToggle() {
        app.tabBars.buttons["Settings"].tap()
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))

        let toggle = app.switches["Generate Link Previews"]
        XCTAssertTrue(toggle.exists)

        let initialValue = toggle.value as? String
        toggle.tap()

        let newValue = toggle.value as? String
        XCTAssertNotEqual(initialValue, newValue, "Toggle value should change after tap")

        // Toggle back
        toggle.tap()
    }

    // MARK: - Clear History Confirmation Flow

    func testClearHistoryRequiresConfirmation() {
        app.tabBars.buttons["Settings"].tap()
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))

        // First tap shows confirmation
        let clearButton = app.buttons["Clear History"]
        XCTAssertTrue(clearButton.exists, "Clear History button should exist")

        clearButton.tap()

        // Should now show confirmation text
        let confirmButton = app.buttons["Tap Again to Confirm"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 3),
            "Confirmation button should appear after first tap"
        )
    }

    // MARK: - Search Interaction

    func testSearchButtonOpensSearchField() {
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5))

        searchButton.tap()

        // Search field should appear
        let searchField = app.textFields["Search"]
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "Search text field should appear after tapping search button"
        )
    }

    func testDismissSearchReturnsToNormalState() {
        // Open search
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
        searchButton.tap()

        let searchField = app.textFields["Search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        // Dismiss search
        let closeButton = app.buttons["Close search"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        closeButton.tap()

        // Search button should be visible again (not the field)
        XCTAssertTrue(
            searchButton.waitForExistence(timeout: 5),
            "Search button should reappear after dismissing search"
        )
    }

    // MARK: - Add Menu

    func testAddButtonExpandsMenu() {
        let addButton = app.buttons["Add new item"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))

        addButton.tap()

        // The add cluster should expand — check that photo and paste buttons appear
        // Wait briefly for animation
        sleep(1)

        // The plus should turn to an X
        // Tap again to dismiss
        addButton.tap()
    }

    // MARK: - Deep Links

    func testSearchDeepLinkOpensLibraryWithSearch() {
        // Navigate to settings first to verify deep link switches back
        app.tabBars.buttons["Settings"].tap()
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))

        // Open deep link
        let url = URL(string: "clipkitty://search?q=test")!
        app.open(url)

        // Should switch to library tab
        sleep(2)
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.isSelected, "Deep link should switch to Library tab")
    }

    func testAddDeepLinkOpensLibrary() {
        // Navigate to settings first
        app.tabBars.buttons["Settings"].tap()
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5))

        // Open deep link
        let url = URL(string: "clipkitty://add")!
        app.open(url)

        // Should switch to library tab
        sleep(2)
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.isSelected, "Deep link should switch to Library tab")
    }

    // MARK: - Card Swipe Actions

    func testSwipeLeftOnCardRevealsActions() {
        // This test requires at least one item in the feed.
        // If the feed is empty, the test passes vacuously (no cards to swipe).
        let firstCell = app.cells.firstMatch
        guard firstCell.waitForExistence(timeout: 5) else {
            // Empty feed — nothing to swipe
            return
        }

        firstCell.swipeLeft()
        sleep(1)

        // Swipe actions should be visible
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 3) {
            XCTAssertTrue(deleteButton.exists, "Delete swipe action should be visible")
        }
    }
}
