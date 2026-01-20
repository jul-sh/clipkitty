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
            // Derive from test bundle location: .../DerivedData/.../ClipKittyUITests.xctest
            // Go up to find the project root where ClipKitty.app should be
            let testBundle = Bundle(for: type(of: self))
            var url = testBundle.bundleURL
            // Navigate up from DerivedData/Build/Products/Debug/...xctest to project root
            while !FileManager.default.fileExists(atPath: url.appendingPathComponent("ClipKitty.app").path) && url.path != "/" {
                url = url.deletingLastPathComponent()
            }
            appPath = url.appendingPathComponent("ClipKitty.app").path
        }
        let appURL = URL(fileURLWithPath: appPath)
        app = XCUIApplication(url: appURL)
        app.launchArguments = ["--screenshot-mode"]
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

    func testTakeScreenshot() throws {
        // Wait for animations or loading
        sleep(2)

        let window = app.dialogs.firstMatch
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Application Screenshot"
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
}
