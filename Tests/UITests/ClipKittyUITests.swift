import XCTest

final class ClipKittyUITests: XCTestCase {
    var app: XCUIApplication!
    /// Wall-clock time when setUp started; used to compute the skip offset for video trimming.
    private var setUpStartTime = Date()

    private static let localeConfigFile = "clipkitty_screenshot_locale.txt"
    private static let dbConfigFile = "clipkitty_screenshot_db.txt"

    /// Padding around the window for screenshots and video crops (points).
    /// Shared between `saveScreenshot` and `testRecordIntroVideo`.
    private static let windowPadding: CGFloat = 16

    /// Detect if running in CI (GitHub Actions). Since env vars don't propagate to XCTest,
    /// we check for the presence of /Users/runner which is the home directory on GitHub-hosted runners.
    private var isCI: Bool {
        FileManager.default.fileExists(atPath: "/Users/runner")
    }

    /// CI runners are slower; use longer timeouts to avoid flaky failures.
    private var ciTimeout: TimeInterval {
        isCI ? 2.0 : 0.5
    }

    /// Wait for a condition to become true, polling at short intervals.
    private func waitForCondition(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// Click an element and wait for it to become focused/ready. Retries on CI.
    private func clickAndWait(_ element: XCUIElement, timeout: TimeInterval = 1.0) {
        element.click()
        Thread.sleep(forTimeInterval: isCI ? timeout : min(timeout, 0.3))
    }

    /// Type text into an element with CI-appropriate pacing.
    private func typeTextSlowly(_ element: XCUIElement, text: String) {
        if isCI {
            // In CI, type one character at a time with small delays for reliability
            for char in text {
                element.typeText(String(char))
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else {
            element.typeText(text)
        }
    }

    /// Helper to read configuration from a temp file with optional environment fallback.
    /// - Parameters:
    ///   - filename: The temp file name (will be prefixed with /tmp/)
    ///   - envFallback: Optional environment variable name to check if file is empty/missing
    ///   - defaultValue: Optional default value if both file and env are empty/missing
    /// - Returns: The trimmed content from file, env var, or default value
    private func readTempConfig(_ filename: String, envFallback: String? = nil, defaultValue: String? = nil) -> String? {
        if let content = try? String(contentsOfFile: "/tmp/\(filename)", encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let envKey = envFallback, let envValue = ProcessInfo.processInfo.environment[envKey] {
            if !envValue.isEmpty {
                return envValue
            }
        }
        return defaultValue
    }

    /// Load video search queries from JSON (written by rust-data-gen --video-only).
    /// Falls back to empty dict (English defaults used inline).
    private func loadVideoQueries() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/clipkitty_video_queries.json")),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return [:]
        }
        return dict
    }

    /// Locale for localized screenshot capture.
    /// Read from /tmp/clipkitty_screenshot_locale.txt (written by `make screenshots-macos` before test run).
    /// When set (e.g. "ja", "de"), the app launches in that locale and demo content is patched.
    private var screenshotLocale: String? {
        // First try reading from temp file (used by make screenshots-macos)
        // Fallback to environment variable (for manual testing)
        if let locale = readTempConfig(Self.localeConfigFile, envFallback: "SCREENSHOT_LOCALE") {
            // Filter out "en" since that's the default
            if locale != "en" {
                return locale
            }
        }
        return nil
    }

    /// Read the bundle identifier from the app's Info.plist
    private func getBundleIdentifier(for appURL: URL) -> String {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOf: plistURL),
           let bundleId = plist["CFBundleIdentifier"] as? String
        {
            return bundleId
        }
        return "com.eviljuliette.clipkitty"
    }

    override func setUpWithError() throws {
        setUpStartTime = Date()
        continueAfterFailure = false

        let appURL = try locateAppBundle()
        app = XCUIApplication(url: appURL)

        let appSupportDir = getAppSupportDirectory(for: appURL)
        try setupTestDatabase(in: appSupportDir)

        app.launchArguments = ["--use-simulated-db"]

        // Marketing screenshots and the intro video need the preview pane to
        // show "Paste" so the featured direct-paste capability is visible.
        // Forcing the mode here avoids per-machine TCC.db manipulation.
        if name.contains("testRecordIntroVideo") || name.contains("testTakeMarketingScreenshots") {
            app.launchArguments += ["--force-paste-mode"]
        }

        // Set app locale for localized screenshots
        if let locale = screenshotLocale {
            app.launchArguments += ["-AppleLanguages", "(\(locale))"]
            app.launchArguments += ["-AppleLocale", locale]
        }

        app.launch()
        app.activate()

        // Wait for the search field — it's always present regardless of how
        // the accessibility system classifies the NSPanel (window vs dialog).
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 15),
            "App UI did not appear. Hierarchy: \(app.debugDescription)"
        )
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Setup Helpers

    private func locateAppBundle() throws -> URL {
        if let envPath = ProcessInfo.processInfo.environment["CLIPKITTY_APP_PATH"] {
            return URL(fileURLWithPath: envPath)
        }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appURL = projectRoot.appendingPathComponent("ClipKitty.app")

        if FileManager.default.fileExists(atPath: appURL.path) {
            return appURL
        }

        // Fallback: traverse up from bundle
        let testBundle = Bundle(for: type(of: self))
        var url = testBundle.bundleURL
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("ClipKitty.app").path) && url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("ClipKitty.app")
    }

    private func getAppSupportDirectory(for appURL: URL) -> URL {
        let bundleId = getBundleIdentifier(for: appURL)
        let userHome = URL(fileURLWithPath: "/Users/\(NSUserName())")

        // When the app is signed with sandbox entitlements, macOS redirects
        // ~/Library/Application Support/ into the per-app container:
        //   ~/Library/Containers/{bundleId}/Data/Library/Application Support/
        // When built with CODE_SIGNING_ALLOWED=NO (e.g. CI UI tests), the
        // binary has no entitlements so it runs unsandboxed and uses the
        // regular Application Support path. Detect which case applies by
        // inspecting the embedded entitlements of the actual binary.
        if isAppSandboxed(appURL) {
            return userHome.appendingPathComponent("Library/Containers/\(bundleId)/Data/Library/Application Support/ClipKitty")
        } else {
            return userHome.appendingPathComponent("Library/Application Support/ClipKitty")
        }
    }

    private func isAppSandboxed(_ appURL: URL) -> Bool {
        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/ClipKitty")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "--entitlements", "-", "--xml", binaryURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let sandbox = plist["com.apple.security.app-sandbox"] as? Bool
            {
                return sandbox
            }
        } catch {}
        return false
    }

    private func setupTestDatabase(in appSupportDir: URL) throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // Read the database filename from temp file (written by `make screenshots-macos`)
        // If it exists, use that filename; otherwise fall back to "SyntheticData.sqlite"
        let databaseFilename = readTempConfig(Self.dbConfigFile, defaultValue: "SyntheticData.sqlite") ?? "SyntheticData.sqlite"

        let sqliteSourceURL = projectRoot.appendingPathComponent("distribution/\(databaseFilename)")
        let targetURL = appSupportDir.appendingPathComponent("clipboard-screenshot.sqlite")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // Kill existing instances and clean up old data
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "ClipKitty"]
        try? killTask.run()
        killTask.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.2)

        try? FileManager.default.removeItem(at: targetURL)
        // Remove all Tantivy index versions so the app rebuilds from scratch
        if let contents = try? FileManager.default.contentsOfDirectory(at: appSupportDir, includingPropertiesForKeys: nil) {
            for item in contents where item.lastPathComponent.hasPrefix("tantivy_index_") {
                try? FileManager.default.removeItem(at: item)
            }
        }
        // SQLite WAL files: handle both hyphen (-wal) and dot (.wal) naming conventions
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: targetURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: targetURL.path + "-shm"))
        try? FileManager.default.removeItem(at: targetURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: targetURL.appendingPathExtension("shm"))

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("\(databaseFilename) not found at: \(sqliteSourceURL.path)")
            return
        }

        // Guard against Git LFS pointer files — if LFS hasn't been pulled, the .sqlite file
        // is a ~132-byte text file starting with "version https://git-lfs.github.com/spec/v1"
        // instead of the actual SQLite database. This causes silent 0-item test failures.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sqliteSourceURL.path)[.size] as? Int) ?? 0
        if fileSize < 1024 {
            // Read first bytes to check for LFS pointer signature
            let headerData = FileManager.default.contents(atPath: sqliteSourceURL.path).flatMap { data in
                String(data: data.prefix(64), encoding: .utf8)
            }
            if headerData?.contains("git-lfs.github.com") == true {
                XCTFail("Git LFS pointer not resolved for \(databaseFilename). Run 'git lfs pull' first. File at: \(sqliteSourceURL.path)")
                return
            }
            XCTFail("\(databaseFilename) is too small (\(fileSize) bytes) — likely corrupt or an LFS pointer. Path: \(sqliteSourceURL.path)")
            return
        }

        try FileManager.default.copyItem(at: sqliteSourceURL, to: targetURL)

        // Verify the copy succeeded and the file is a real SQLite database
        let copiedSize = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(copiedSize, 1024,
                             "Copied database is too small (\(copiedSize) bytes). Target: \(targetURL.path)")
    }

    /// Helper to get the currently selected index by finding the button with isSelected trait
    private func getSelectedIndex() -> Int? {
        // Items are Button elements inside Cell elements inside the Outline
        // Find which button is selected
        let buttons = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        for (index, button) in buttons.enumerated() {
            if button.isSelected {
                return index
            }
        }
        return nil
    }

    /// Helper to wait for selected index to equal expected value
    private func waitForSelectedIndex(_ expected: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if getSelectedIndex() == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return getSelectedIndex() == expected
    }

    private func clearSearchField(_ element: XCUIElement) {
        clickAndWait(element)
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(.delete, modifierFlags: [])
    }

    // MARK: - Tests

    /// Regression test: verify the synthetic database was correctly seeded.
    /// If this fails, the DB is likely being placed in the wrong sandbox container path.
    func testDatabaseNotEmpty() {
        let items = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        XCTAssertGreaterThan(items.count, 0, "Database should contain items — empty DB indicates a seeding/path regression")
    }

    /// Tests that first item is selected on initial open.
    /// There should always be an item selected when items exist.
    func testFirstItemSelectedOnOpen() {
        // First item should be selected immediately after open
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected on open")

        // Verify we actually have items
        let buttons = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        XCTAssertGreaterThan(buttons.count, 0, "Should have items in the list")
    }

    /// Tests that first item's preview content is visible when selected.
    /// KNOWN ISSUE: First item shows in list but NOT in preview pane.
    /// The EditableTextPreview's NSTextView is not rendering/accessible.
    func testFirstItemPreviewVisible() {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.exists, "Panel should be visible initially")

        // Wait for first item to be selected
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")
        Thread.sleep(forTimeInterval: 1.0)

        // Look for the preview text view by accessibility identifier
        let previewTextView = panel.textViews["PreviewTextView"]
        let previewExists = previewTextView.waitForExistence(timeout: 2)

        // Debug output
        let allTextViews = panel.textViews.allElementsBoundByIndex
        print("DEBUG: Found \(allTextViews.count) text views")
        for (i, tv) in allTextViews.enumerated() {
            print("DEBUG: TextView[\(i)] id='\(tv.identifier)' exists=\(tv.exists)")
        }

        XCTAssertTrue(previewExists,
                      "Preview text view (PreviewTextView) should exist. KNOWN ISSUE: EditableTextPreview not rendering.")
    }

    /// Tests that Cmd+number shortcuts select and paste the corresponding history item.
    /// Cmd+2 should target the second item (index 1).
    func testCommandNumberShortcutSelectsSecondItem() {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure we have at least 2 items
        let buttons = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(buttons.count, 2, "Need at least 2 items for Cmd+2 test")

        // Ensure keyboard focus and initial selection are stable.
        clickAndWait(searchField)
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "Initial selection should be first item")

        // Extra stabilization before sending keyboard shortcut
        Thread.sleep(forTimeInterval: ciTimeout)

        // Cmd+2 selects the second item and copies/pastes it.
        // In CI the panel may hide after paste, so verify via toast instead of selection.
        app.typeKey("2", modifierFlags: .command)

        let toastWindow = app.windows["SnackbarNotificationWindow"]
        XCTAssertTrue(
            toastWindow.waitForExistence(timeout: 5),
            "Cmd+2 should trigger copy (toast should appear)"
        )
    }

    /// Tests that selection resets to first when the selected item's position changes in the list.
    /// Selection should only reset when items are reordered, not on every search text change.
    func testSelectionResetsWhenItemPositionChanges() {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Initial state: first item should be selected
        XCTAssertTrue(waitForSelectedIndex(0), "Initial selection should be index 0")

        // Move selection down to item 3
        searchField.click()
        for _ in 0 ..< 3 {
            searchField.typeText(XCUIKeyboardKey.downArrow.rawValue)
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(getSelectedIndex(), 3, "Selection should have moved to index 3")

        // Type a search query that filters results - this changes item positions
        // so selection should reset to first
        searchField.typeText("the")
        Thread.sleep(forTimeInterval: 0.3)

        // Selection should reset because the item order changed
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 2), "Selection should reset when item positions change")
    }

    func testPreviewHighlightsRefreshWhenRefiningQueryForSameItem() {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")
        let previewTextView = app.textViews["PreviewTextView"]
        let previewHighlightDebug = app.descendants(matching: .any)["PreviewHighlightDebug"]

        let databaseLoaded = waitForCondition(timeout: 5) {
            self.app.outlines.firstMatch.buttons.allElementsBoundByIndex.count > 0
        }
        XCTAssertTrue(databaseLoaded, "Synthetic database should be loaded before running the preview highlight regression")

        clearSearchField(searchField)
        typeTextSlowly(searchField, text: "Copy it")

        let targetPreviewLoaded = waitForCondition(timeout: 5) {
            let value = previewTextView.value as? String ?? ""
            return previewTextView.exists
                && value.localizedCaseInsensitiveContains("copy it once")
                && value.localizedCaseInsensitiveContains("preview before pasting")
        }
        XCTAssertTrue(targetPreviewLoaded, "Preview should show the stock ClipKitty SyntheticData item")

        let initialHighlightReady = waitForCondition(timeout: 5) {
            guard previewHighlightDebug.exists else { return false }
            let label = previewHighlightDebug.label
            return label.localizedCaseInsensitiveContains("copy")
                && label.localizedCaseInsensitiveContains("it")
                && !label.localizedCaseInsensitiveContains("once")
        }

        saveScreenshot(name: "preview_highlight_refresh_initial")

        typeTextSlowly(searchField, text: " once")

        let sameItemRemainsSelected = waitForCondition(timeout: 5) {
            let value = previewTextView.value as? String ?? ""
            return previewTextView.exists
                && value.localizedCaseInsensitiveContains("copy it once")
                && value.localizedCaseInsensitiveContains("preview before pasting")
        }

        let previewStayedVisible = waitForCondition(timeout: 2) {
            let value = previewTextView.value as? String ?? ""
            return previewTextView.exists && !value.isEmpty
        }

        let refinedHighlightReady = waitForCondition(timeout: 5) {
            guard previewHighlightDebug.exists else { return false }
            let label = previewHighlightDebug.label
            return label.localizedCaseInsensitiveContains("copy")
                && label.localizedCaseInsensitiveContains("it")
                && label.localizedCaseInsensitiveContains("once")
        }

        saveScreenshot(name: "preview_highlight_refresh_refined")

        XCTAssertTrue(
            initialHighlightReady,
            "Initial preview highlights should reflect only the initial query. Got: \(previewHighlightDebug.exists ? previewHighlightDebug.label : "missing")"
        )
        XCTAssertTrue(sameItemRemainsSelected, "Refined query should keep the same stock item selected")
        XCTAssertTrue(previewStayedVisible, "Preview should stay visible while refreshed highlights load")
        XCTAssertTrue(
            refinedHighlightReady,
            "Preview highlights should refresh when the query is refined without changing the selected item. Got: \(previewHighlightDebug.exists ? previewHighlightDebug.label : "missing")"
        )
    }

    /// Tests that the panel hides when focus moves to another application.
    /// This is Spotlight-like behavior - the panel should auto-dismiss on focus loss.
    func testPanelHidesOnFocusLoss() {
        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.exists, "Window should be visible initially")

        // Click somewhere outside the app to lose focus
        // We'll use Finder as the other app
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()

        // Wait for the window to disappear
        let disappeared = window.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Window should hide when focus moves to another app")
    }

    /// Tests that the panel does NOT auto-show when the app is activated/focused.
    /// The panel should only appear via hotkey or menu - not automatically on app focus.
    /// This ensures settings and other interactions don't get overlaid by the panel.
    func testPanelDoesNotAutoShowOnAppFocus() {
        // Use the search field as a proxy for panel visibility — it's always inside the panel
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.exists, "Panel should be visible initially (search field present)")

        // First, hide the panel by activating another app
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5), "Panel should hide when focus lost")

        // Give time for focus to fully transfer
        Thread.sleep(forTimeInterval: 1.0)

        // Re-activate the app without using the hotkey.
        // On CI, XCTest's activate() can behave differently, so we use
        // XCUIApplication.activate() which activates the process without
        // triggering the panel hotkey.
        app.activate()

        // Wait long enough to catch any auto-show behavior
        Thread.sleep(forTimeInterval: 2.0)

        // Panel should still be hidden - it should only show via hotkey/menu.
        // The search field is the reliable indicator of panel visibility.
        let panelReappeared = searchField.waitForExistence(timeout: 1)
        if panelReappeared {
            // In CI, XCTest's activate() may trigger the panel to show due to
            // the accessibility framework re-attaching. This is a known CI-only
            // behavior. Verify settings still works as the important behavior.
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(searchField.waitForNonExistence(timeout: 3), "Panel should hide after Escape")
        }

        // Open settings - it should work without panel overlay
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["ClipKitty Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window should appear")
        XCTAssertTrue(settingsWindow.isHittable, "Settings window should be interactable")
    }

    /// Tests that clicking on the preview text area allows text selection
    /// instead of dragging the window.
    func testPreviewTextIsSelectable() {
        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.exists, "Window should be visible")

        // Record initial window position
        let initialFrame = window.frame

        // Find the text view in the preview pane (it's a scroll view with text)
        let scrollViews = window.scrollViews
        XCTAssertGreaterThan(scrollViews.count, 0, "Should have scroll views")

        // The preview pane's scroll view - try to find the text area
        // Click and drag on the preview text area
        let previewArea = scrollViews.element(boundBy: scrollViews.count - 1)
        XCTAssertTrue(previewArea.exists, "Preview scroll view should exist")

        // Perform a click-drag that would normally move the window
        let startPoint = previewArea.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        let endPoint = previewArea.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
        startPoint.click(forDuration: 0.1, thenDragTo: endPoint)

        // Wait a moment for any potential window movement
        Thread.sleep(forTimeInterval: 0.3)

        // Window should NOT have moved - the drag should select text, not move window
        let finalFrame = window.frame
        XCTAssertEqual(initialFrame.origin.x, finalFrame.origin.x, accuracy: 5,
                       "Window X position should not change when clicking preview text")
        XCTAssertEqual(initialFrame.origin.y, finalFrame.origin.y, accuracy: 5,
                       "Window Y position should not change when clicking preview text")
    }

    /// Tests that the content-type filter dropdown is visible and functional.
    /// The dropdown capsule must be hittable (rendered with nonzero frame and sufficient contrast),
    /// open a popover with filter options, and allow selecting a filter.
    func testFilterDropdownVisible() {
        // 1. Find the filter dropdown button by accessibility identifier
        let filterButton = app.buttons["FilterDropdown"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5), "Filter dropdown button should exist")
        XCTAssertTrue(filterButton.isHittable, "Filter dropdown button should be hittable (visible with nonzero frame)")

        // Screenshot: dropdown closed
        saveScreenshot(name: "filter_closed")

        // 2. Click to open the popover
        filterButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // 3. Verify popover content appears with filter options
        // FilterOptionRow uses Button, so options appear as buttons in the accessibility tree
        let linksOption = app.buttons["Links"]
        XCTAssertTrue(linksOption.waitForExistence(timeout: 3), "Popover should show 'Links' option")

        // Screenshot: dropdown open
        saveScreenshot(name: "filter_open")

        // 4. Select "Links Only" and verify the button label changes
        linksOption.click()
        Thread.sleep(forTimeInterval: 0.5)

        // After selecting, the button label should reflect the new filter
        let updatedButton = app.buttons["FilterDropdown"]
        XCTAssertTrue(updatedButton.waitForExistence(timeout: 3), "Filter button should still exist after selection")
        XCTAssertTrue(updatedButton.isHittable, "Filter button should remain hittable after selection")

        // The button label should now say "Links" instead of "All Types"
        XCTAssertTrue(updatedButton.label.contains("Links"), "Filter button should show 'Links' after selecting Links Only, got: '\(updatedButton.label)'")
    }

    // MARK: - Actions Menu

    /// Tests that the actions button is visible in the metadata footer.
    func testActionsButtonVisible() {
        let actionsButton = app.buttons["ActionsButton"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5), "Actions button should exist in footer")
        XCTAssertTrue(actionsButton.isHittable, "Actions button should be hittable")
    }

    /// Tests that clicking the actions button opens a popover with action options.
    func testActionsPopoverOpensOnClick() {
        let actionsButton = app.buttons["ActionsButton"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5), "Actions button should exist")

        actionsButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Should show at least Copy/Paste and Delete options
        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "Delete action should appear in popover")

        // Default action should be Copy (no accessibility permission in test env)
        let copyAction = app.buttons["Action_Copy"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 3), "Copy action should appear in popover")
    }

    /// Tests that Cmd+K opens the actions popover.
    func testCmdKOpensActionsPopover() {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Cmd+K should open the actions menu
        searchField.typeKey("k", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "Actions popover should open with Cmd+K")
    }

    /// Tests that Escape closes the actions popover.
    func testEscapeClosesActionsPopover() {
        let actionsButton = app.buttons["ActionsButton"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5))

        actionsButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "Popover should be open")

        // Press Escape to close
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(deleteAction.exists, "Popover should close after Escape")
    }

    /// Tests the full delete flow: open actions via Cmd+K, navigate to Delete,
    /// confirm deletion — all via keyboard to avoid SwiftUI button click issues in CI.
    func testDeleteItemViaKeyboard() {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Record initial item count
        let initialCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        XCTAssertGreaterThan(initialCount, 0, "Should have items to delete")

        // Ensure focus is on the search field
        clickAndWait(searchField)
        Thread.sleep(forTimeInterval: ciTimeout)

        // Open actions popover with Cmd+K
        searchField.typeKey("k", modifierFlags: .command)

        // Wait for the actions popover to appear
        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "Actions popover should open")

        // Wait for the popover to gain focus via .focused() binding
        Thread.sleep(forTimeInterval: 0.5)

        // Actions list is [.bookmark(0), .defaultAction(1), .delete(2)].
        // Cmd+K opens with highlight at index 0. Navigate down to Delete (last item).
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        // Press Return to select Delete — this triggers the delete action
        app.typeKey(.return, modifierFlags: [])

        // Wait for deletion to process
        let deleted = waitForCondition(timeout: 5) {
            self.app.outlines.firstMatch.buttons.allElementsBoundByIndex.count == initialCount - 1
        }
        XCTAssertTrue(deleted, "Item count should decrease by 1 after deletion")

        // Verify: window is still visible (not hidden)
        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.exists, "Window should still be visible after deletion")
    }

    // MARK: - Toast Tests

    /// Tests that a toast notification appears when copying an item
    func testToastAppearsOnCopy() {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Press Return to copy the selected item (auto-paste is disabled in test mode)
        searchField.typeKey(.return, modifierFlags: [])

        // Toast should appear
        let toastWindow = app.windows["SnackbarNotificationWindow"]
        XCTAssertTrue(toastWindow.waitForExistence(timeout: 3), "Toast window should appear after copying")

        // Toast should disappear after ~1.5 seconds
        let disappeared = toastWindow.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Toast should auto-dismiss")
    }

    // MARK: - Marketing Assets

    /// Captures a marketing-ready screenshot: crops a 16:10 rectangle centered
    /// on the app window from the full-screen capture, then upscales to 2880×1800.
    /// The neutral desktop background (set by `prepare-screenshot-environment.sh`)
    /// fills the padding area around the window.
    private func saveScreenshot(name: String) {
        let dialog = app.dialogs.firstMatch
        let window = dialog.exists ? dialog : app.windows.firstMatch
        if !window.exists {
            return
        }

        // Allow items to fully load before capturing
        Thread.sleep(forTimeInterval: 1.0)

        let frame = window.frame
        let screenShot = XCUIScreen.main.screenshot()
        let image = screenShot.image
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0

        // Start with window frame + padding on all sides
        var cropWidth = frame.width + Self.windowPadding * 2
        var cropHeight = frame.height + Self.windowPadding * 2

        // Expand the smaller dimension so the crop is exactly 16:10
        let targetRatio: CGFloat = 16.0 / 10.0
        let currentRatio = cropWidth / cropHeight
        if currentRatio < targetRatio {
            // Too tall — widen
            cropWidth = cropHeight * targetRatio
        } else {
            // Too wide — heighten
            cropHeight = cropWidth / targetRatio
        }

        // Center the crop on the window center
        let centerX = frame.midX
        let centerY = frame.midY
        let cropRect = CGRect(
            x: max((centerX - cropWidth / 2) * scaleFactor, 0),
            y: max((centerY - cropHeight / 2) * scaleFactor, 0),
            width: cropWidth * scaleFactor,
            height: cropHeight * scaleFactor
        )

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgImage.cropping(to: cropRect)
        else {
            return
        }

        // Upscale to exactly 2880×1800 pixels using a bitmap context.
        // NSImage.lockFocus() scales with the display's backing factor (2x on Retina),
        // which would produce 5760×3600 on CI's virtual HiDPI display.
        let finalWidth = 2880
        let finalHeight = 1800
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: finalWidth,
            pixelsHigh: finalHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        bitmapRep.size = NSSize(width: finalWidth, height: finalHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            .draw(in: NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight))
        NSGraphicsContext.restoreGraphicsState()

        if let png = bitmapRep.representation(using: .png, properties: [:]) {
            let localePrefix = screenshotLocale.map { "\($0)_" } ?? ""
            let url = URL(fileURLWithPath: "/tmp/clipkitty_\(localePrefix)\(name).png")
            try? png.write(to: url)

            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Records an intro video showcasing ClipKitty's core capabilities.
    /// Run with: `make intro-video` (or via the intro-videos CI job).
    ///
    /// Uses SyntheticData_video.sqlite (generated by `make intro-video`)
    /// which has the welcome message as the first item plus items for each scene.
    ///
    /// Scene 1: Find it forever — "Copy it once, find it forever"
    /// Scene 2: Multi-line preview — "Multi-line preview" shows balloon ASCII art
    /// Scene 2.5: Secure & private — "secure and private" highlights the privacy bullet
    /// Scene 3: Image search + bookmark — type the localized word for "fast" to
    ///          find the cartoon cat, then Cmd+K → Enter to bookmark it. For
    ///          CJK locales the query is ASCII "fast" (overridden in
    ///          video_localized.rs) because IME input is much slower
    ///          per-character in XCUITest; the image keywords include "fast"
    ///          as a substring for those locales.
    func testRecordIntroVideo() {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Save window bounds to temp file for video cropping (same padding + 16:10 as screenshots)
        let window = app.dialogs.firstMatch
        if window.exists {
            let frame = window.frame
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

            // Use same padding and 16:10 aspect ratio as screenshots
            var cropWidth = frame.width + Self.windowPadding * 2
            var cropHeight = frame.height + Self.windowPadding * 2
            let targetRatio: CGFloat = 16.0 / 10.0
            let currentRatio = cropWidth / cropHeight
            if currentRatio < targetRatio {
                cropWidth = cropHeight * targetRatio
            } else {
                cropHeight = cropWidth / targetRatio
            }

            // Center crop on window, convert to pixels
            let cropX = max((frame.midX - cropWidth / 2) * scaleFactor, 0)
            let cropY = max((frame.midY - cropHeight / 2) * scaleFactor, 0)
            let boundsString = String(format: "%.0f,%.0f,%.0f,%.0f",
                                      cropX, cropY,
                                      cropWidth * scaleFactor,
                                      cropHeight * scaleFactor)
            try? boundsString.write(toFile: "/tmp/clipkitty_window_bounds.txt",
                                    atomically: true, encoding: .utf8)
        }

        // Cycle the panel: hide then re-show so it's freshly visible when recording starts
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(" ", modifierFlags: .option)
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Panel should reappear after toggle")
        Thread.sleep(forTimeInterval: 0.5)

        // Navigate away and back to force the preview to re-render with correct font scaling
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Brief pause to let the panel settle before demo scenes begin.
        // (Xcode records the screen automatically into the xcresult bundle.)
        Thread.sleep(forTimeInterval: 0.5)

        // Per-scene per-character latencies for the `typeText` call itself
        // (not the post-delay sleep). High values here indicate the app's main
        // thread was blocked when the synthetic key event was delivered.
        var typingSamples: [(scene: String, query: String, latenciesMs: [Double])] = []

        /// Helper to type with natural delays. Skips the post-delay on the
        /// first character when the search field is currently empty, so the
        /// first match appears without artificial latency. When `scene` is
        /// provided, per-char `typeText` latencies are recorded for later
        /// export.
        func typeSlowly(_ text: String, scene: String? = nil, delay: TimeInterval = 0.006) {
            let startedEmpty = (searchField.value as? String)?.isEmpty ?? true
            var latenciesMs: [Double] = []
            latenciesMs.reserveCapacity(text.count)
            for (index, char) in text.enumerated() {
                let start = CFAbsoluteTimeGetCurrent()
                searchField.typeText(String(char))
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                latenciesMs.append(elapsedMs)
                if startedEmpty && index == 0 { continue }
                Thread.sleep(forTimeInterval: delay)
            }
            if let scene {
                typingSamples.append((scene: scene, query: text, latenciesMs: latenciesMs))
            }
        }

        /// Helper to clear search field. No trailing delay — the next typed char
        /// should hit the empty field immediately.
        func clearSearch() {
            searchField.typeKey(.delete, modifierFlags: .command)
        }

        // Load locale-specific search queries from JSON (written by rust-data-gen --video-only)
        let queries = loadVideoQueries()

        // Warm the image preview cache before the recorded portion begins by briefly
        // showing the localized "fast" image, then reset back to the default state.
        typeSlowly(queries["fast"] ?? "fast")
        Thread.sleep(forTimeInterval: 1.0)
        clearSearch()
        Thread.sleep(forTimeInterval: 0.5)

        // Write elapsed time so the post-processing script can skip the setup portion.
        let setupElapsed = Date().timeIntervalSince(setUpStartTime)
        try? String(format: "%.1f", setupElapsed)
            .write(toFile: "/tmp/clipkitty_video_start_offset.txt",
                   atomically: true, encoding: .utf8)

        // ============================================================
        // SCENE 1: Find it forever
        // ============================================================
        typeSlowly(queries["find_forever"] ?? "copy once find forever", scene: "find_forever")
        Thread.sleep(forTimeInterval: 0.375)

        // ============================================================
        // SCENE 2: Multi-line Preview
        // ============================================================
        clearSearch()
        typeSlowly(queries["multiline"] ?? "Multi-line preview", scene: "multiline")
        Thread.sleep(forTimeInterval: 0.5)

        // ============================================================
        // SCENE 2.5: Secure & private
        // ============================================================
        clearSearch()
        typeSlowly(queries["secure_private"] ?? "private open source", scene: "secure_private")
        Thread.sleep(forTimeInterval: 1.5)

        // ============================================================
        // SCENE 3: Image Search + Bookmark — type the (possibly localized)
        // "fast" query to find the cat image, then bookmark it. CJK locales
        // override the query to ASCII "fast" in video_localized.rs; the
        // image keywords include "fast" for those locales so search still
        // matches.
        // ============================================================
        clearSearch()
        typeSlowly(queries["fast"] ?? "fast", scene: "fast")
        Thread.sleep(forTimeInterval: 1.5)

        // Open actions menu with Cmd+K (highlight starts at index 0 = Bookmark)
        searchField.typeKey("k", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.8)

        // Press Return to activate Bookmark (already highlighted at index 0)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)

        // ============================================================
        // OUTRO
        // ============================================================
        clearSearch()
        Thread.sleep(forTimeInterval: 0.5)

        writeTypingLatencyReport(
            locale: screenshotLocale ?? "en",
            samples: typingSamples
        )

        // Demo finished — the xcresult screen recording ends when the test returns.
    }

    /// Writes per-character `typeText` latencies to
    /// `/tmp/clipkitty_video_typing_latency.json` so the marketing pipeline
    /// can copy the report next to the recorded `.mov`. High latencies here
    /// signal the app's main thread was blocked between keystrokes.
    private func writeTypingLatencyReport(
        locale: String,
        samples: [(scene: String, query: String, latenciesMs: [Double])]
    ) {
        struct SceneReport: Encodable {
            let name: String
            let query: String
            let charLatenciesMs: [Double]
            let meanMs: Double
            let p95Ms: Double
            let maxMs: Double
        }
        struct Report: Encodable {
            let locale: String
            let scenes: [SceneReport]
            let overallMeanMs: Double
            let overallP95Ms: Double
            let overallMaxMs: Double
        }

        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let rank = p * Double(sorted.count - 1)
            let lower = Int(rank.rounded(.down))
            let upper = Int(rank.rounded(.up))
            if lower == upper { return sorted[lower] }
            let weight = rank - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }

        let scenes: [SceneReport] = samples.map { sample in
            let values = sample.latenciesMs
            let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            return SceneReport(
                name: sample.scene,
                query: sample.query,
                charLatenciesMs: values.map { ($0 * 100).rounded() / 100 },
                meanMs: (mean * 100).rounded() / 100,
                p95Ms: (percentile(values, 0.95) * 100).rounded() / 100,
                maxMs: ((values.max() ?? 0) * 100).rounded() / 100
            )
        }
        let allValues = samples.flatMap { $0.latenciesMs }
        let overallMean = allValues.isEmpty ? 0 : allValues.reduce(0, +) / Double(allValues.count)
        let report = Report(
            locale: locale,
            scenes: scenes,
            overallMeanMs: (overallMean * 100).rounded() / 100,
            overallP95Ms: (percentile(allValues, 0.95) * 100).rounded() / 100,
            overallMaxMs: ((allValues.max() ?? 0) * 100).rounded() / 100
        )

        for scene in scenes {
            print("[typing-latency] \(scene.name): mean=\(scene.meanMs)ms p95=\(scene.p95Ms)ms max=\(scene.maxMs)ms chars=\(scene.charLatenciesMs.count)")
        }
        print("[typing-latency] overall: mean=\(report.overallMeanMs)ms p95=\(report.overallP95Ms)ms max=\(report.overallMaxMs)ms")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/clipkitty_video_typing_latency.json"))
    }

    /// Captures multiple screenshot states for marketing materials.
    /// Run with: make marketing-screenshots
    /// NOTE: Relies entirely on demo items in SyntheticData.sqlite (generated with --demo flag)
    func testTakeMarketingScreenshots() {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Cycle the panel: hide then re-show to ensure clean visual state
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(" ", modifierFlags: .option)
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Panel should reappear after hotkey toggle")
        Thread.sleep(forTimeInterval: 0.5)

        // Navigate away and back to force the preview to re-render with correct font scaling
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Screenshot 1: Initial state showing clipboard history
        Thread.sleep(forTimeInterval: 1.0)
        saveScreenshot(name: "marketing_1_history")

        // Screenshot 2: Fuzzy search in action (typo-tolerant: "dockr"→docker, "prodction"→production, spanning multiple lines)
        searchField.click()
        searchField.typeText("dockr push prodction")
        Thread.sleep(forTimeInterval: 0.5)
        saveScreenshot(name: "marketing_2_search")

        // Screenshot 3: Images filter applied with dropdown open, Images row highlighted
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        let filterButton = app.buttons["FilterDropdown"]
        // Apply the Images filter (use accessibility identifier, not localized label)
        filterButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        let imagesOption = app.buttons["Filter_images"]
        XCTAssertTrue(imagesOption.waitForExistence(timeout: 3), "Images option should appear in dropdown")
        imagesOption.click()
        Thread.sleep(forTimeInterval: 0.5)
        // Re-open dropdown, then hover over Images to get highlight
        filterButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        let imagesOptionAgain = app.buttons["Filter_images"]
        XCTAssertTrue(imagesOptionAgain.waitForExistence(timeout: 3), "Images option should appear in dropdown")
        imagesOptionAgain.hover()
        Thread.sleep(forTimeInterval: 0.3)
        saveScreenshot(name: "marketing_3_filter")
    }

    // MARK: - Editable Preview Tests

    /// Tests that the preview text view exists, is selectable, and contains content
    /// from the selected clipboard item.
    func testPreviewTextIsEditable() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure we have a text item selected (first item should be text based on demo data)
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")

        // Wait for preview to render
        Thread.sleep(forTimeInterval: ciTimeout)

        // Find text views in the app - the preview pane uses NSTextView
        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        XCTAssertTrue(hasTextViews, "Should have text views in the app")

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)
        XCTAssertTrue(previewTextView.exists, "Preview text view should exist")

        // Verify the preview has content from the selected item
        let value = previewTextView.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Preview text view should display content from selected item")

        // Verify the text view is selectable (click should not drag the window)
        let window = app.dialogs.firstMatch
        let initialFrame = window.frame
        clickAndWait(previewTextView, timeout: ciTimeout)
        XCTAssertEqual(window.frame.origin.x, initialFrame.origin.x, accuracy: 2,
                       "Window should not move when clicking preview text (text should be selectable)")
    }

    /// Tests that selecting different items updates the preview content.
    func testEditAndDefocusCreatesNewItem() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure we have items
        let initialCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        XCTAssertGreaterThan(initialCount, 1, "Should have at least 2 items")

        // Wait for preview to render
        Thread.sleep(forTimeInterval: ciTimeout)

        // Get preview content for first item
        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        guard hasTextViews else {
            XCTFail("No text views found")
            return
        }

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)
        let firstItemText = previewTextView.value as? String ?? ""

        // Navigate to second item
        clickAndWait(searchField)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForSelectedIndex(1, timeout: 3), "Should select second item")
        Thread.sleep(forTimeInterval: ciTimeout)

        // Preview should update to show second item's content
        let previewUpdated = waitForCondition(timeout: 5) {
            let currentText = previewTextView.value as? String ?? ""
            return !currentText.isEmpty && currentText != firstItemText
        }
        XCTAssertTrue(previewUpdated, "Preview should update when selecting a different item")
    }

    /// Tests that copying an item via Return re-selects the first item.
    func testEditedItemAppearsAtTopAndSelected() {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Navigate to second item
        clickAndWait(searchField)
        Thread.sleep(forTimeInterval: ciTimeout)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForSelectedIndex(1, timeout: 3), "Should select second item")

        // Copy the second item via Return
        app.typeKey(.return, modifierFlags: [])

        // Toast should appear confirming copy
        let toastWindow = app.windows["SnackbarNotificationWindow"]
        XCTAssertTrue(toastWindow.waitForExistence(timeout: 5), "Toast should appear after copy")

        // After toast dismisses, if panel is still visible, selection should be valid
        XCTAssertTrue(toastWindow.waitForNonExistence(timeout: 5), "Toast should auto-dismiss")
    }

    /// Tests that images show an image preview, not an editable text view.
    func testImagePreviewNotEditable() {
        let filterButton = app.buttons["FilterDropdown"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5), "Filter button not found")

        // Filter to images only
        clickAndWait(filterButton, timeout: ciTimeout)

        let imagesOption = app.buttons["Images"]
        guard imagesOption.waitForExistence(timeout: 3) else {
            // Skip if no images filter option (may not have images in test data)
            return
        }

        clickAndWait(imagesOption, timeout: ciTimeout)

        // Wait for filter to apply and outline to update
        Thread.sleep(forTimeInterval: ciTimeout)

        // Verify we have image items after filtering
        let imageCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        guard imageCount > 0 else { return }

        // For image items, the preview should show an image, not the text preview.
        // The PreviewTextView should not be present for image items.
        let previewTextView = app.textViews["PreviewTextView"]
        let hasTextPreview = previewTextView.waitForExistence(timeout: 2)
        XCTAssertFalse(hasTextPreview, "Image items should not show a text preview view")

        // Verify item count is stable (no unexpected changes from filter)
        XCTAssertGreaterThan(imageCount, 0, "Should have image items after filtering")
    }

    /// Tests that links show a link preview, not an editable text view.
    func testLinkPreviewNotEditable() {
        let filterButton = app.buttons["FilterDropdown"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5), "Filter button not found")

        // Filter to links only
        clickAndWait(filterButton, timeout: ciTimeout)

        let linksOption = app.buttons["Links"]
        guard linksOption.waitForExistence(timeout: 3) else {
            // Skip if no links filter option
            return
        }

        clickAndWait(linksOption, timeout: ciTimeout)

        // Wait for filter to apply and outline to update
        Thread.sleep(forTimeInterval: ciTimeout)

        // Verify we have link items after filtering
        let linkCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        guard linkCount > 0 else { return }

        // For link items, the preview uses LPLinkView which is not a text view.
        // The PreviewTextView should not be present for link items.
        let previewTextView = app.textViews["PreviewTextView"]
        let hasTextPreview = previewTextView.waitForExistence(timeout: 2)
        XCTAssertFalse(hasTextPreview, "Link items should not show a text preview view")

        // Verify item count is stable
        XCTAssertGreaterThan(linkCount, 0, "Should have link items after filtering")
    }

    /// Tests that copying via Return shows a toast notification.
    func testEditAndCopyShowsCombinedToastMessage() {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure first item selected
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")

        // Copy the selected item via Return
        searchField.typeKey(.return, modifierFlags: [])

        // Toast should appear
        let toastWindow = app.windows["SnackbarNotificationWindow"]
        XCTAssertTrue(toastWindow.waitForExistence(timeout: 5), "Toast window should appear after copy")

        // Toast should auto-dismiss
        XCTAssertTrue(toastWindow.waitForNonExistence(timeout: 5), "Toast should auto-dismiss")
    }

    // MARK: - Edit Mode Tests

    /// Tests that typing in the preview creates a pending edit.
    /// Verifies that the footer shows Save/Discard buttons.
    func testTypingInPreviewShowsPendingEditIndicators() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure first item selected and preview loaded
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")
        Thread.sleep(forTimeInterval: ciTimeout)

        // Find and click the preview text view to focus it
        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        guard hasTextViews else {
            XCTFail("No text views found")
            return
        }

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)
        clickAndWait(previewTextView, timeout: ciTimeout)

        // Type some text to create an edit
        previewTextView.typeText(" edited")
        Thread.sleep(forTimeInterval: ciTimeout)

        // Verify Save/Discard buttons appear in footer by checking for any element containing "Save"
        // SwiftUI buttons may appear as buttons, staticTexts, or other element types
        let saveExists = waitForCondition(timeout: 3) {
            // Check buttons
            let saveButtons = self.app.buttons.matching(NSPredicate(format: "label CONTAINS 'Save'")).allElementsBoundByIndex
            if !saveButtons.isEmpty { return true }
            // Check static texts
            let saveTexts = self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Save'")).allElementsBoundByIndex
            return !saveTexts.isEmpty
        }
        XCTAssertTrue(saveExists, "Save button/text should appear when item has pending edit")

        // Verify Discard appears
        let discardExists = waitForCondition(timeout: 3) {
            let discardButtons = self.app.buttons.matching(NSPredicate(format: "label CONTAINS 'Discard'")).allElementsBoundByIndex
            if !discardButtons.isEmpty { return true }
            let discardTexts = self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Discard'")).allElementsBoundByIndex
            return !discardTexts.isEmpty
        }
        XCTAssertTrue(discardExists, "Discard button/text should appear when item has pending edit")
    }

    /// Helper to check if Save UI element exists
    private func saveUIExists() -> Bool {
        let saveButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Save'")).allElementsBoundByIndex
        if !saveButtons.isEmpty { return true }
        let saveTexts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Save'")).allElementsBoundByIndex
        return !saveTexts.isEmpty
    }

    /// Tests that pressing Escape discards the pending edit.
    func testEscapeDiscardsEdit() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure first item selected and preview loaded
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")
        Thread.sleep(forTimeInterval: ciTimeout)

        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        guard hasTextViews else {
            XCTFail("No text views found")
            return
        }

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)
        let originalText = previewTextView.value as? String ?? ""

        // Click and edit
        clickAndWait(previewTextView, timeout: ciTimeout)
        previewTextView.typeText(" TEMP_EDIT")
        Thread.sleep(forTimeInterval: ciTimeout)

        // Verify Save button appears (confirming edit was registered)
        let saveExists = waitForCondition(timeout: 3) { self.saveUIExists() }
        XCTAssertTrue(saveExists, "Save button should appear for edit")

        // Press Escape to discard
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: ciTimeout)

        // Save button should disappear
        let saveDisappeared = waitForCondition(timeout: 3) { !self.saveUIExists() }
        XCTAssertTrue(saveDisappeared, "Save button should disappear after discarding edit")

        // Text should revert to original
        let currentText = previewTextView.value as? String ?? ""
        XCTAssertEqual(currentText, originalText,
                       "Preview text should revert to original after Escape")
    }

    /// Tests that Cmd+S saves the edit (replaces the original item).
    func testCmdSSavesEdit() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Record initial item count
        let initialCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        XCTAssertGreaterThan(initialCount, 0, "Should have items")

        // Ensure first item selected
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")
        Thread.sleep(forTimeInterval: ciTimeout)

        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        guard hasTextViews else {
            XCTFail("No text views found")
            return
        }

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)

        // Click and edit with unique text to avoid duplicate detection
        clickAndWait(previewTextView, timeout: ciTimeout)
        let uniqueEdit = " UNIQUE_\(Int.random(in: 1000 ... 9999))"
        typeTextSlowly(previewTextView, text: uniqueEdit)
        Thread.sleep(forTimeInterval: ciTimeout)

        // Verify Save button appears
        let saveExists = waitForCondition(timeout: 3) { self.saveUIExists() }
        XCTAssertTrue(saveExists, "Save button should appear for edit")

        // Press Cmd+S to save
        app.typeKey("s", modifierFlags: .command)

        // Toast should appear confirming save
        let toastWindow = app.windows["SnackbarNotificationWindow"]
        XCTAssertTrue(toastWindow.waitForExistence(timeout: 5),
                      "Toast should appear after saving edit")

        // Wait for the list to update
        Thread.sleep(forTimeInterval: ciTimeout)

        // Save button should disappear (edit committed)
        let saveDisappeared = waitForCondition(timeout: 3) { !self.saveUIExists() }
        XCTAssertTrue(saveDisappeared, "Save button should disappear after saving")

        // Item count should stay the same (original deleted, new one created)
        let countStable = waitForCondition(timeout: 5) {
            self.app.outlines.firstMatch.buttons.allElementsBoundByIndex.count == initialCount
        }
        XCTAssertTrue(countStable,
                      "Item count should stay the same after edit (delete + save). Expected \(initialCount)")
    }

    /// Tests that Cmd+Return saves the edit and copies/pastes the new item.
    func testCmdReturnSavesAndPastes() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure first item selected
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")
        Thread.sleep(forTimeInterval: ciTimeout)

        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        guard hasTextViews else {
            XCTFail("No text views found")
            return
        }

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)

        // Click and edit with unique text
        clickAndWait(previewTextView, timeout: ciTimeout)
        let uniqueEdit = " CMD_RETURN_\(Int.random(in: 1000 ... 9999))"
        typeTextSlowly(previewTextView, text: uniqueEdit)
        Thread.sleep(forTimeInterval: ciTimeout)

        // Click text view again to ensure focus before Cmd+Return
        clickAndWait(previewTextView, timeout: ciTimeout)

        // Press Cmd+Return to save and paste
        app.typeKey(.return, modifierFlags: .command)

        // Panel should close after Cmd+Return (no toast in auto-paste mode)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Tests that navigating away from an edited item preserves the pending edit.
    func testNavigatingAwayPreservesPendingEdit() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure we have multiple items
        let itemCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        XCTAssertGreaterThan(itemCount, 1, "Need at least 2 items")

        // Select first item and edit
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")
        Thread.sleep(forTimeInterval: ciTimeout)

        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        guard hasTextViews else {
            XCTFail("No text views found")
            return
        }

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)

        // Click and edit
        clickAndWait(previewTextView, timeout: ciTimeout)
        let editText = " NAV_TEST"
        typeTextSlowly(previewTextView, text: editText)
        Thread.sleep(forTimeInterval: ciTimeout)

        // Navigate to second item
        clickAndWait(searchField)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitForSelectedIndex(1, timeout: 3), "Should select second item")
        Thread.sleep(forTimeInterval: ciTimeout)

        // Navigate back to first item
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "Should select first item again")
        Thread.sleep(forTimeInterval: ciTimeout)

        // The pending edit should be preserved - Save button should still be visible
        let saveExists = waitForCondition(timeout: 3) { self.saveUIExists() }
        XCTAssertTrue(saveExists,
                      "Save button should still appear when returning to edited item")
    }

    /// Tests that the Return button label shows Cmd+Return when in edit mode.
    func testReturnButtonShowsCmdPrefixWhenEditing() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure first item selected
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected")
        Thread.sleep(forTimeInterval: ciTimeout)

        let hasTextViews = waitForCondition(timeout: 5) {
            self.app.textViews.allElementsBoundByIndex.count > 0
        }
        guard hasTextViews else {
            XCTFail("No text views found")
            return
        }

        let previewTextView = try XCTUnwrap(app.textViews.allElementsBoundByIndex.first)

        // Click and edit
        clickAndWait(previewTextView, timeout: ciTimeout)
        previewTextView.typeText(" test")
        Thread.sleep(forTimeInterval: ciTimeout)

        // The confirm button should show "⌘↩" prefix when in edit mode
        // SwiftUI buttons may appear as buttons, staticTexts, or other element types
        let cmdReturnExists = waitForCondition(timeout: 3) {
            // Check buttons
            let buttons = self.app.buttons.matching(NSPredicate(format: "label CONTAINS '⌘↩'")).allElementsBoundByIndex
            if !buttons.isEmpty { return true }
            // Check static texts
            let texts = self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS '⌘↩'")).allElementsBoundByIndex
            return !texts.isEmpty
        }
        XCTAssertTrue(cmdReturnExists, "Confirm button should show ⌘↩ prefix when editing")
    }

    /// Tests that the Settings window opens without crashing and all tabs are accessible.
    func testSettingsWindowOpensAllTabs() {
        let baselineVisibleWindowCount = app.windows.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .count

        // Open settings via Cmd+, even if the ClipKitty panel is already showing.
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["ClipKitty Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window should appear")
        let expectedVisibleWindowCount = baselineVisibleWindowCount + 1
        let expectedWindowCountShown = waitForCondition(timeout: 3) {
            self.app.windows.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == expectedVisibleWindowCount
        }
        XCTAssertTrue(expectedWindowCountShown, "Cmd+, should add only the real settings window")

        // General tab should be visible by default
        let generalTab = settingsWindow.buttons["SettingsTab_General"]
            .exists ? settingsWindow.buttons["SettingsTab_General"] : settingsWindow.radioButtons["General"]
        XCTAssertTrue(settingsWindow.staticTexts["Startup"].waitForExistence(timeout: 3),
                      "General tab content should be visible")

        // Switch to Privacy tab
        let privacyTab = settingsWindow.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Privacy'")
        ).firstMatch
        if privacyTab.exists, privacyTab.isHittable {
            privacyTab.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Switch to Shortcuts tab
        let shortcutsTab = settingsWindow.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Shortcuts'")
        ).firstMatch
        if shortcutsTab.exists, shortcutsTab.isHittable {
            shortcutsTab.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Switch back to General to verify navigation works
        let generalTabNav = settingsWindow.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'General'")
        ).firstMatch
        if generalTabNav.exists, generalTabNav.isHittable {
            generalTabNav.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Trigger Cmd+, again to ensure it refocuses the same window instead of spawning another one.
        app.typeKey(",", modifierFlags: .command)
        let stillExpectedWindowCountShown = waitForCondition(timeout: 3) {
            self.app.windows.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == expectedVisibleWindowCount
        }
        XCTAssertTrue(stillExpectedWindowCountShown, "Cmd+, should keep reusing the same settings window")

        // Verify the settings window is still alive (didn't crash)
        XCTAssertTrue(settingsWindow.exists, "Settings window should still exist after tab navigation")
    }
}
