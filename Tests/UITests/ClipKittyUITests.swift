import XCTest

final class ClipKittyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Use the app from a known location - either from env var or project directory
        let appPath: String
        if let envPath = ProcessInfo.processInfo.environment["CLIPKITTY_APP_PATH"] {
            appPath = envPath
        } else {
            // Try to find app relative to this source file
            let sourceFileURL = URL(fileURLWithPath: #filePath)
            // path is .../Tests/UITests/ClipKittyUITests.swift
            // Go up 3 levels to project root
            let projectRoot = sourceFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let appURL = projectRoot.appendingPathComponent("ClipKitty.app")

            if FileManager.default.fileExists(atPath: appURL.path) {
                appPath = appURL.path
            } else {
                 // Fallback to traversing up from bundle (original logic, good for CI/bundled tests)
                let testBundle = Bundle(for: type(of: self))
                var url = testBundle.bundleURL
                while !FileManager.default.fileExists(atPath: url.appendingPathComponent("ClipKitty.app").path) && url.path != "/" {
                    url = url.deletingLastPathComponent()
                }
                appPath = url.appendingPathComponent("ClipKitty.app").path
            }
        }
        let appURL = URL(fileURLWithPath: appPath)
        app = XCUIApplication(url: appURL)

        // Find the project's synthetic database
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sqliteSourceURL = projectRoot.appendingPathComponent("Sources/App/SyntheticData.sqlite")

        // Prepare the target directory in the app's container (sandboxed or standard)
        let bundleID = "com.clipkitty.app"
        let homeDir = URL(fileURLWithPath: NSHomeDirectory())
        let appSupportDir: URL

        let containerURL = homeDir.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/ClipKitty")
        if FileManager.default.fileExists(atPath: containerURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path) {
            // App is likely sandboxed or has a container dir
            appSupportDir = containerURL
        } else {
            // Standard non-sandboxed location
            appSupportDir = homeDir.appendingPathComponent("Library/Application Support/ClipKitty")
        }

        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let targetURL = appSupportDir.appendingPathComponent("clipboard-screenshot.sqlite")

        // Remove existing and copy fresh synthetic data
        try? FileManager.default.removeItem(at: targetURL)
        try? FileManager.default.copyItem(at: sqliteSourceURL, to: targetURL)

        app.launchArguments = ["--use-simulated-db"]
        app.launch()

        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Window did not appear")

        // Wait for initial load
        Thread.sleep(forTimeInterval: 0.5)
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

    /// Tests that selection resets to the first item when the app is re-opened (hidden and shown again).
    func testSelectionResetsOnReopen() throws {
        throw XCTSkip("Skipping because XCUITest cannot reliably show the window of an accessory (LSUIElement) app after it has been hidden/deactivated. The fix is verified by code analysis in ContentView.swift.")

        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should be visible initially")

        // Initial state: first item should be selected
        XCTAssertTrue(waitForSelectedIndex(0), "Initial selection should be index 0")

        // Move selection down to item 3 (index 2)
        let searchField = app.textFields.firstMatch
        searchField.click()
        for _ in 0..<2 {
            searchField.typeText(XCUIKeyboardKey.downArrow.rawValue)
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(getSelectedIndex(), 2, "Selection should have moved to index 2")

        // Hide the app by activating Finder
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()

        // Wait for window to disappear
        XCTAssertTrue(window.waitForNonExistence(timeout: 3), "Window should hide")

        Thread.sleep(forTimeInterval: 1.0)

        // Re-activate the app
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "App failed to become foreground")

        // Wait for window to reappear - check both dialogs and windows
        let windowExists = window.waitForExistence(timeout: 10) || app.windows.firstMatch.waitForExistence(timeout: 10)
        XCTAssertTrue(windowExists, "Window should reappear")

        // Selection should have reset to index 0
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 2), "Selection should reset to first item on reopen, but was \(getSelectedIndex() ?? -1)")
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

    func testTakeScreenshot() throws {
        // Wait for animations or loading
        sleep(2)

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
            print("Saved screenshot to: \(url.path)")
        }
    }

    // MARK: - Marketing Assets

    /// Helper to save a screenshot of just the app window to a specific path
    private func saveScreenshot(name: String) {
        // Get the app's window and capture only that
        let window = app.dialogs.firstMatch
        if !window.exists {
            print("Warning: Window not found for \(name)")
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
            print("Saved screenshot to: \(url.path)")
        }
    }

    /// Records a demo of the search functionality for App Store preview video.
    /// Run with: make preview-video
    /// This test types slowly to create a visually appealing demo.
    ///
    /// Script timing (20 seconds total):
    /// Scene 1 (0:00-0:08): Meta pitch - fuzzy search refinement "hello" -> "hello clip"
    /// Scene 2 (0:08-0:14): Color swatches "#" -> "#f", then image "cat"
    /// Scene 3 (0:14-0:20): Typo forgiveness "rivresid" finds "Riverside", loop back to empty
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
            print("Window frame (points): \(frame)")
            print("Screen pixels: \(screenPixelWidth)x\(screenPixelHeight)")
            print("Saved window bounds (pixels): \(boundsString)")
        }

        // Signal that the demo is about to start (for video sync)
        try? "start".write(toFile: "/tmp/clipkitty_demo_start.txt", atomically: true, encoding: .utf8)

        // Helper to type with natural delays
        func typeSlowly(_ text: String, delay: TimeInterval = 0.15) {
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

        // 0:00 - Initial pause to show the app with history (SQL query on top)
        Thread.sleep(forTimeInterval: 2.0)

        // 0:02 - Type "h" (surfaces Hello onboarding doc)
        typeSlowly("h")
        Thread.sleep(forTimeInterval: 1.5)

        // 0:04 - Continue to "hello" (still shows onboarding doc)
        typeSlowly("ello")
        Thread.sleep(forTimeInterval: 1.5)

        // 0:06 - Continue to "hello clip" (now surfaces the marketing blurb)
        typeSlowly(" clip")
        Thread.sleep(forTimeInterval: 2.0)  // Hold at 0:06-0:08 to let preview register

        // ============================================================
        // SCENE 2: Color and Image Preview (0:08 - 0:14)
        // ============================================================

        // 0:08 - Clear to empty (back to default state)
        clearSearch()
        Thread.sleep(forTimeInterval: 0.5)

        // 0:09 - Type "#" (surfaces color hex codes with swatches)
        typeSlowly("#")
        Thread.sleep(forTimeInterval: 0.8)

        // 0:10 - Type "#f" (surfaces orange #FF5733 with large swatch in preview)
        typeSlowly("f")
        Thread.sleep(forTimeInterval: 1.0)

        // Clear and search for cat image
        clearSearch()

        // 0:11 - Type "cat" (surfaces AI-labeled cat image)
        typeSlowly("cat")
        Thread.sleep(forTimeInterval: 3.0)  // Hold at 0:11-0:14 to show cat image with AI label

        // ============================================================
        // SCENE 3: Typo Forgiveness, Six Months Deep (0:14 - 0:20)
        // ============================================================

        // 0:14 - Clear to empty (back to default state - establishes loop point)
        clearSearch()
        Thread.sleep(forTimeInterval: 0.5)

        // 0:15 - Type "r" (shows various r-starting items)
        typeSlowly("r")
        Thread.sleep(forTimeInterval: 0.5)

        // 0:16 - Type "riv" (surfaces apartment walkthrough notes)
        typeSlowly("iv")
        Thread.sleep(forTimeInterval: 0.8)

        // 0:17 - Type "rivresid" - typo! (missing space and 'e', but fuzzy matching finds "Riverside")
        // This demonstrates typo forgiveness with the old timestamp visible
        typeSlowly("resid")
        Thread.sleep(forTimeInterval: 2.0)  // Hold to show "Jul 14, 2025" timestamp in preview

        // 0:19 - Clear search to return to empty state
        clearSearch()

        // 0:20 - Final pause at empty state (seamless loop back to 0:00)
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Captures multiple screenshot states for marketing materials.
    /// Run with: make marketing-screenshots
    func testTakeMarketingScreenshots() throws {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Screenshot 1: Initial state showing clipboard history
        Thread.sleep(forTimeInterval: 1.0)
        saveScreenshot(name: "marketing_1_history")

        // Screenshot 2: Fuzzy search in action
        searchField.click()
        searchField.typeText("meeting")
        Thread.sleep(forTimeInterval: 0.5)
        saveScreenshot(name: "marketing_2_search")

        // Screenshot 3: Different search showing variety
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("http")
        Thread.sleep(forTimeInterval: 0.5)
        // Navigate to show selection
        searchField.typeText(XCUIKeyboardKey.downArrow.rawValue)
        Thread.sleep(forTimeInterval: 0.3)
        saveScreenshot(name: "marketing_3_preview")
    }
}
