import XCTest

final class ClipKittyUITests: XCTestCase {
    var app: XCUIApplication!

    /// Check if an app has the sandbox entitlement enabled
    private func isAppSandboxed(at appURL: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "--entitlements", "-", "--xml", appURL.path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Check if the entitlements contain app-sandbox = true
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let entitlements = plist["com.apple.security.app-sandbox"] as? Bool {
                return entitlements
            }
            // Also check for the string in raw output (fallback)
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("com.apple.security.app-sandbox") && output.contains("<true/>")
            }
        } catch {
            // If we can't determine, assume non-sandboxed
        }
        return false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        let appURL = try locateAppBundle()
        app = XCUIApplication(url: appURL)

        let appSupportDir = getAppSupportDirectory(for: appURL)
        try setupTestDatabase(in: appSupportDir)

        app.launchArguments = ["--use-simulated-db"]
        app.launch()

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
        if isAppSandboxed(at: appURL) {
            let userHome = URL(fileURLWithPath: "/Users/\(NSUserName())")
            return userHome.appendingPathComponent("Library/Containers/com.clipkitty.app/Data/Library/Application Support/ClipKitty")
        } else {
            let systemAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return systemAppSupport.appendingPathComponent("ClipKitty")
        }
    }

    private func setupTestDatabase(in appSupportDir: URL) throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sqliteSourceURL = projectRoot.appendingPathComponent("distribution/SyntheticData.sqlite")
        let targetURL = appSupportDir.appendingPathComponent("clipboard-screenshot.sqlite")
        let indexDirURL = appSupportDir.appendingPathComponent("tantivy_index_v3")

        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // Kill existing instances and clean up old data
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "ClipKitty"]
        try? killTask.run()
        killTask.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.2)

        try? FileManager.default.removeItem(at: targetURL)
        try? FileManager.default.removeItem(at: indexDirURL)
        try? FileManager.default.removeItem(at: targetURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: targetURL.appendingPathExtension("shm"))

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("SyntheticData.sqlite not found at: \(sqliteSourceURL.path)")
            return
        }
        try FileManager.default.copyItem(at: sqliteSourceURL, to: targetURL)
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

    // MARK: - Tests

    /// Tests that first item is selected on initial open.
    /// There should always be an item selected when items exist.
    func testFirstItemSelectedOnOpen() throws {
        // First item should be selected immediately after open
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected on open")

        // Verify we actually have items
        let buttons = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        XCTAssertGreaterThan(buttons.count, 0, "Should have items in the list")
    }

    /// Tests that selection resets to first when the selected item's position changes in the list.
    /// Selection should only reset when items are reordered, not on every search text change.
    func testSelectionResetsWhenItemPositionChanges() throws {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Initial state: first item should be selected
        XCTAssertTrue(waitForSelectedIndex(0), "Initial selection should be index 0")

        // Move selection down to item 3
        searchField.click()
        for _ in 0..<3 {
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



    /// Tests that the panel hides when focus moves to another application.
    /// This is Spotlight-like behavior - the panel should auto-dismiss on focus loss.
    func testPanelHidesOnFocusLoss() throws {
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
    func testPanelDoesNotAutoShowOnAppFocus() throws {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.exists, "Panel should be visible initially")

        // First, hide the panel by activating another app
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Panel should hide when focus lost")

        // Re-activate the app - panel should NOT auto-show
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)

        // Panel should still be hidden - it should only show via hotkey/menu
        XCTAssertFalse(panel.exists, "Panel should NOT auto-show when app is activated")

        // Now open settings - it should work without panel overlay
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["ClipKitty Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings window should appear")
        XCTAssertTrue(settingsWindow.isHittable, "Settings window should be interactable")

        // Panel should still not be visible
        XCTAssertFalse(panel.exists, "Panel should NOT appear when settings is opened")
    }

    /// Tests that clicking on the preview text area allows text selection
    /// instead of dragging the window.
    func testPreviewTextIsSelectable() throws {
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
    func testFilterDropdownVisible() throws {
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
        let linksOption = app.buttons["Links Only"]
        XCTAssertTrue(linksOption.waitForExistence(timeout: 3), "Popover should show 'Links Only' option")

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

    func testTakeScreenshot() throws {
        // Wait for animations and loading - use fixed delay to avoid hanging if items never appear
        Thread.sleep(forTimeInterval: 2.0)

        // Capture the entire screen
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Full Screen Screenshot"
        attachment.lifetime = .keepAlways
        add(attachment)

        let image = screenshot.image
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: "/tmp/clipkitty_screenshot.png")
            try? png.write(to: url)
        }
    }

    // MARK: - Marketing Assets

    /// Helper to save a screenshot of just the app window to a specific path
    private func saveScreenshot(name: String) {
        // Get the app's window and capture only that
        let window = app.dialogs.firstMatch
        if !window.exists {
            return
        }

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let image = screenshot.image
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: "/tmp/clipkitty_\(name).png")
            try? png.write(to: url)
        }
    }

    /// Records a demo of the search functionality for App Store preview video.
    /// Run with: make preview-video
    /// This test types slowly to create a visually appealing demo.
    ///
    /// NOTE: Relies entirely on demo items in SyntheticData.sqlite (generated with --demo flag)
    ///
    /// Script timing (20 seconds total):
    /// Scene 1 (0:00-0:08): Meta pitch - fuzzy search refinement "hello" -> "hello clip"
    ///   - Matches: Hello ClipKitty, hello_world.py, sayHello, Hello and welcome...
    /// Scene 2 (0:08-0:14): Color swatches "#" -> "#f", then image "cat"
    ///   - Matches: #7C3AED, #FF5733, #2DD4BF, #F472B6, Orange tabby cat...
    /// Scene 3 (0:14-0:20): Typo forgiveness "rivresid" finds "Riverside", loop back to empty
    ///   - Matches: Apartment walkthrough...437 Riverside Dr...
    func testRecordSearchDemo() throws {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Save window bounds to temp file for video cropping
        let window = app.dialogs.firstMatch
        if window.exists {
            let frame = window.frame
            // XCUIElement.frame is in points, but screen recording is in pixels
            // Get the scale factor by comparing screenshot pixel size to screen bounds
            let screenshot = XCUIScreen.main.screenshot()
            let screenPixelHeight = screenshot.image.size.height
            let screenPixelWidth = screenshot.image.size.width

            // Get the actual scale factor from NSScreen (works for any display)
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

            // Convert frame from points to pixels
            let pixelX = frame.origin.x * scaleFactor
            let pixelY = frame.origin.y * scaleFactor
            let pixelWidth = frame.width * scaleFactor
            let pixelHeight = frame.height * scaleFactor

            // Convert from bottom-left origin (AppKit) to top-left origin (video/ffmpeg)
            // NOTE: XCTest actually uses top-left origin already, so no flip needed
            let topLeftY = pixelY  // Use directly, no conversion

            // Format: x,y,width,height (with some padding for shadow/border)
            let padding: CGFloat = 80  // N points * 2 for scaling
            let boundsString = String(format: "%.0f,%.0f,%.0f,%.0f",
                                       max(0, pixelX - padding),
                                       max(0, topLeftY - padding),
                                       pixelWidth + padding * 2,
                                       pixelHeight + padding * 2)
            try? boundsString.write(toFile: "/tmp/clipkitty_window_bounds.txt",
                                    atomically: true, encoding: .utf8)
        }

        // Signal that the demo is ready to start (shell script will start recording)
        try? "start".write(toFile: "/tmp/clipkitty_demo_start.txt", atomically: true, encoding: .utf8)

        // Wait for recording to start (shell script signals when screencapture is running)
        let recordingStartedPath = "/tmp/clipkitty_recording_started.txt"
        var waitCount = 0
        while !FileManager.default.fileExists(atPath: recordingStartedPath) && waitCount < 20 {
            Thread.sleep(forTimeInterval: 0.5)
            waitCount += 1
        }
        try? FileManager.default.removeItem(atPath: recordingStartedPath)

        // Helper to type with natural delays
        func typeSlowly(_ text: String, delay: TimeInterval = 0.08) {
            for char in text {
                searchField.typeText(String(char))
                Thread.sleep(forTimeInterval: delay)
            }
        }

        // Helper to clear search field
        func clearSearch() {
            searchField.typeKey("a", modifierFlags: .command)  // Select all
            searchField.typeKey(.delete, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }

        // ============================================================
        // SCENE 1: Meta Pitch - Fuzzy search refinement (0:00 - 0:08)
        // ============================================================

        // 0:00 - Initial pause (ensure recording has captured initial state)
        Thread.sleep(forTimeInterval: 1.0)

        // Type "h"
        typeSlowly("h")
        Thread.sleep(forTimeInterval: 0.8)

        // Continue to "hello"
        typeSlowly("ello")
        Thread.sleep(forTimeInterval: 0.8)

        // Continue to "hello clip"
        typeSlowly(" clip")
        Thread.sleep(forTimeInterval: 1.5)

        // ============================================================
        // SCENE 2: Color and Image Preview (0:08 - 0:14)
        // ============================================================

        // Scene 2
        clearSearch()
        Thread.sleep(forTimeInterval: 0.3)

        typeSlowly("#")
        Thread.sleep(forTimeInterval: 0.5)

        typeSlowly("f")
        Thread.sleep(forTimeInterval: 0.8)

        clearSearch()
        typeSlowly("cat")
        Thread.sleep(forTimeInterval: 2.0)

        // ============================================================
        // SCENE 3: Typo Forgiveness, Six Months Deep (0:14 - 0:20)
        // ============================================================

        // Scene 3
        clearSearch()
        Thread.sleep(forTimeInterval: 0.3)

        typeSlowly("r")
        Thread.sleep(forTimeInterval: 0.3)

        typeSlowly("iv")
        Thread.sleep(forTimeInterval: 0.5)

        typeSlowly("resid")
        Thread.sleep(forTimeInterval: 1.5)

        clearSearch()
        Thread.sleep(forTimeInterval: 0.5)

        // Signal that the demo is finished
        try? "stop".write(toFile: "/tmp/clipkitty_demo_stop.txt", atomically: true, encoding: .utf8)
    }

    /// Captures multiple screenshot states for marketing materials.
    /// Run with: make marketing-screenshots
    /// NOTE: Relies entirely on demo items in SyntheticData.sqlite (generated with --demo flag)
    func testTakeMarketingScreenshots() throws {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Screenshot 1: Initial state showing clipboard history
        Thread.sleep(forTimeInterval: 1.0)
        saveScreenshot(name: "marketing_1_history")

        // Screenshot 2: Fuzzy search in action (matches demo items: Hello ClipKitty, hello_world.py, sayHello, etc.)
        searchField.click()
        searchField.typeText("hello")
        Thread.sleep(forTimeInterval: 0.5)
        saveScreenshot(name: "marketing_2_search")

        // Screenshot 3: Color swatch search showing preview (matches demo items: #7C3AED, #FF5733, etc.)
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("#")
        Thread.sleep(forTimeInterval: 0.5)
        // Navigate to show selection
        searchField.typeText(XCUIKeyboardKey.downArrow.rawValue)
        Thread.sleep(forTimeInterval: 0.3)
        saveScreenshot(name: "marketing_3_preview")
    }
}
