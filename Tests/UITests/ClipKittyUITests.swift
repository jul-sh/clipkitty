import XCTest

final class ClipKittyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTakeScreenshot() throws {
        let app = XCUIApplication(bundleIdentifier: "com.clipkitty.app")
        app.launchArguments = ["--screenshot-mode"]
        app.launch()
        
        let window = app.dialogs.firstMatch
        let exists = window.waitForExistence(timeout: 10)
        
        if !exists {
            print("Window did not appear. Dumping hierarchy:")
            print(app.debugDescription)
        }
        
        XCTAssertTrue(exists, "Window did not appear")
        
        // Wait for animations or loading
        sleep(2)
        
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
