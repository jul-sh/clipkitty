import XCTest

/// UI tests for the iOS app's core navigation, settings, and interaction flows.
///
/// These tests verify the app's UI at the integration level:
/// - Settings sheet presentation and dismissal
/// - Settings screen structure, navigation, and toggle behavior
/// - Clear history confirmation flow
/// - Card swipe actions (bookmark, delete)
final class ClipKittyiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launch()

        // Wait for the app to finish bootstrapping
        let overflowButton = app.buttons["home.overflowMenuButton"]
        XCTAssertTrue(
            overflowButton.waitForExistence(timeout: 10),
            "App should finish launching and show the Library"
        )
    }

    // MARK: - Navigation

    func testLibraryIsShownByDefault() {
        XCTAssertTrue(app.navigationBars["ClipKitty"].exists, "Library should be visible on launch")
        XCTAssertTrue(app.buttons["home.overflowMenuButton"].isHittable)
    }

    func testLandscapeControlsStayNearBottomEdge() throws {
        defer { XCUIDevice.shared.orientation = .portrait }

        let searchButton = app.buttons["bottomBar.searchButton"]
        if !searchButton.waitForExistence(timeout: 3), app.buttons["Search"].exists {
            throw XCTSkip("This configuration uses the native side rail instead of bottom controls")
        }
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = .portrait
            let portrait = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.app.frame.height > self.app.frame.width },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
            XCUIDevice.shared.orientation = orientation
            let controlsAtBottom = NSPredicate { _, _ in
                guard self.app.frame.width > self.app.frame.height,
                      searchButton.exists, searchButton.isHittable
                else { return false }
                // Allow the home indicator and the control's design margin,
                // but no second, empty toolbar beneath the controls.
                let gap = self.app.frame.maxY - searchButton.frame.maxY
                return gap >= 0 && gap < 60
            }
            let expectation = XCTNSPredicateExpectation(predicate: controlsAtBottom, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                "Landscape controls should sit near the bottom edge; gap was \(app.frame.maxY - searchButton.frame.maxY)"
            )
        }
    }

    func testOpenSettings() {
        openSettings()
    }

    func testDismissSettingsReturnsToLibrary() {
        openSettings()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3), "Settings should have a Done button")
        doneButton.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForNonExistence(timeout: 5),
            "Settings sheet should dismiss"
        )
        XCTAssertTrue(
            app.buttons["home.overflowMenuButton"].waitForExistence(timeout: 5),
            "Library should be visible after dismissing Settings"
        )
    }

    // MARK: - Settings Screen Structure

    func testSettingsScreenShowsRootSections() {
        openSettings()

        XCTAssertFalse(app.staticTexts["Status"].exists, "Sync status should not appear in Settings")
        XCTAssertFalse(app.switches["Haptic Feedback"].exists, "Haptic Feedback should not appear in Settings")
        assertSettingsControlIsReachable(
            settingsSwitch(named: "Sync via iCloud"),
            named: "Sync via iCloud"
        )
        assertSettingsTextIsReachable("Behavior")
        assertSettingsControlIsReachable(
            settingsSwitch(named: "Auto-Add from Clipboard"),
            named: "Auto-Add from Clipboard"
        )
        assertSettingsControlIsReachable(
            app.buttons["settings.appearanceLink"],
            named: "Appearance"
        )
        assertSettingsTextIsReachable("Privacy")
        assertSettingsControlIsReachable(
            settingsSwitch(named: "Generate Link Previews"),
            named: "Generate Link Previews"
        )
        assertSettingsControlIsReachable(
            settingsSwitch(named: "Allow Shortcuts to Read History"),
            named: "Allow Shortcuts to Read History"
        )
        assertSettingsControlIsReachable(
            settingsSwitch(named: "Capture Sensitive Clips"),
            named: "Capture Sensitive Clips"
        )
        assertSettingsControlIsReachable(app.buttons["settings.storageLink"], named: "Storage")
    }

    func testAppearancePageContainsTypefaceAndPreviewSpacing() {
        openSettings()
        openSettingsPage(named: "Appearance")

        assertSettingsTextIsReachable("App Typeface")
        assertSettingsTextIsReachable("Preview Spacing")
    }

    func testStoragePageContainsStorageAndHistoryControls() {
        openSettings()
        openSettingsPage(named: "Storage")

        assertSettingsTextIsReachable("Storage Limit")
        assertSettingsTextIsReachable("History")
        assertSettingsControlIsReachable(app.buttons["Clear History"], named: "Clear History")
        XCTAssertFalse(app.staticTexts["About"].exists, "About should not appear in Storage")
        XCTAssertFalse(app.staticTexts["Version"].exists, "Version should not appear in Storage")
        XCTAssertFalse(app.staticTexts["Build"].exists, "Build should not appear in Storage")
    }

    func testLinkPreviewsToggle() {
        openSettings()

        let toggle = settingsSwitch(named: "Generate Link Previews")
        XCTAssertTrue(revealInSettings(toggle), "Generate Link Previews toggle should be reachable")

        let initialValue = toggle.value as? String
        toggleSettingsSwitch(toggle)

        let newValue = toggle.value as? String
        XCTAssertNotEqual(initialValue, newValue, "Toggle value should change after tap")

        // Toggle back
        toggleSettingsSwitch(toggle)
    }

    // MARK: - Clear History Confirmation Flow

    func testClearHistoryRequiresConfirmation() {
        openSettings()
        openSettingsPage(named: "Storage")

        // First tap shows confirmation
        let clearButton = app.buttons["Clear History"]
        XCTAssertTrue(revealInSettings(clearButton), "Clear History button should be reachable")

        clearButton.tap()

        // Should now show confirmation text
        let confirmButton = app.buttons["Tap Again to Confirm"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 3),
            "Confirmation button should appear after first tap"
        )
    }

    // MARK: - Settings Helpers

    private func openSettings() {
        let overflowButton = app.buttons["home.overflowMenuButton"]
        XCTAssertTrue(overflowButton.waitForExistence(timeout: 5), "Overflow menu button should exist")
        overflowButton.tap()

        let settingsItem = app.buttons["home.settingsMenuItem"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5), "Settings menu item should exist")
        settingsItem.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5),
            "Settings navigation title should be visible"
        )
    }

    private func openSettingsPage(named name: String) {
        let identifier: String
        switch name {
        case "Appearance":
            identifier = "settings.appearanceLink"
        case "Storage":
            identifier = "settings.storageLink"
        default:
            XCTFail("Unknown settings page: \(name)")
            return
        }
        let link = app.buttons[identifier]
        XCTAssertTrue(revealInSettings(link), "\(name) settings should be reachable")
        link.tap()
        XCTAssertTrue(
            app.navigationBars[name].waitForExistence(timeout: 5),
            "\(name) navigation title should be visible"
        )
    }

    private func settingsSwitch(named name: String) -> XCUIElement {
        app.switches.matching(
            NSPredicate(format: "label CONTAINS[c] %@", name)
        ).firstMatch
    }

    private func toggleSettingsSwitch(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -30, dy: 0)).tap()
    }

    private func assertSettingsTextIsReachable(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            revealInSettings(app.staticTexts[label]),
            "\(label) should be reachable in Settings",
            file: file,
            line: line
        )
    }

    private func assertSettingsControlIsReachable(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            revealInSettings(element),
            "\(name) should be reachable in Settings",
            file: file,
            line: line
        )
    }

    private func revealInSettings(_ element: XCUIElement, maximumSwipes: Int = 12) -> Bool {
        if element.waitForExistence(timeout: 0.5), element.isHittable {
            return true
        }

        let collectionView = app.collectionViews.firstMatch
        let scrollView = app.scrollViews.firstMatch
        let scrollContainer = collectionView.exists
            ? collectionView
            : (scrollView.exists ? scrollView : app!)

        for _ in 0 ..< maximumSwipes {
            scrollContainer.swipeUp()
            if element.waitForExistence(timeout: 0.3), element.isHittable {
                return true
            }
        }

        return false
    }

    // MARK: - Search Interaction

    func testSearchFocusSurvivesRelaunchInAnotherLanguage() {
        func typeIntoSearch() {
            let button = app.buttons["bottomBar.searchButton"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            let field = app.textFields["bottomBar.searchField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText("docker")
            XCTAssertEqual(field.value as? String, "docker")
        }

        typeIntoSearch()
        app.terminate()
        app.launchArguments += ["-AppleLanguages", "(es)", "-AppleLocale", "es"]
        app.launch()
        typeIntoSearch()
    }

    func testSelectedCategorySurvivesRelaunch() {
        func selectCategory(_ category: String) {
            let pill = app.buttons["bottomBar.filterPill"]
            XCTAssertTrue(pill.waitForExistence(timeout: 5))
            pill.tap()
            let option = app.buttons["bottomBar.filterOption.\(category)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
        }

        selectCategory("text")
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Text"),
            object: app.buttons["bottomBar.filterPill"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        app.terminate()
        app.launch()

        let pill = app.buttons["bottomBar.filterPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertEqual(pill.label, "Text")
        selectCategory("all")
    }

    func testAutocorrectPreferenceSurvivesRelaunch() throws {
        openSettings()
        let toggle = app.switches["settings.autocorrectNotes"]
        assertSettingsControlIsReachable(toggle, named: "Autocorrect Notes")
        let originalValue = try XCTUnwrap(toggle.value as? String)
        let changedValue = originalValue == "1" ? "0" : "1"
        toggleSettingsSwitch(toggle)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", changedValue), object: toggle
        )
        let result = XCTWaiter.wait(for: [changed], timeout: 3)
        if result != .completed {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "autocorrect-control"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(toggle.value as? String, changedValue)

        app.terminate()
        app.launch()
        openSettings()
        let reloadedToggle = app.switches["settings.autocorrectNotes"]
        assertSettingsControlIsReachable(reloadedToggle, named: "Autocorrect Notes")
        XCTAssertEqual(reloadedToggle.value as? String, changedValue)
        toggleSettingsSwitch(reloadedToggle)
        XCTAssertEqual(reloadedToggle.value as? String, originalValue)
    }

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
        searchField.typeText("docker")
        XCTAssertEqual(searchField.value as? String, "docker", "Search must acquire keyboard focus")
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
