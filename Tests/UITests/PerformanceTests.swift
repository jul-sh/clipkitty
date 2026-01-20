import XCTest

final class ClipKittyPerformanceTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        
        let appPath: String
        if let envPath = ProcessInfo.processInfo.environment["CLIPKITTY_APP_PATH"] {
            appPath = envPath
        } else {
            let sourceFileURL = URL(fileURLWithPath: #filePath)
            let projectRoot = sourceFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let appURL = projectRoot.appendingPathComponent("ClipKitty.app")
            
            if FileManager.default.fileExists(atPath: appURL.path) {
                appPath = appURL.path
            } else {
                let testBundle = Bundle(for: type(of: self))
                var url = testBundle.bundleURL
                while !FileManager.default.fileExists(atPath: url.appendingPathComponent("ClipKitty.app").path) && url.path != "/" {
                    url = url.deletingLastPathComponent()
                }
                appPath = url.appendingPathComponent("ClipKitty.app").path
            }
        }
        
        app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        app.launchArguments = ["--use-simulated-db"]
    }

    /// Measures performance from app launch until the first item is displayed.
    /// This includes app startup, database initialization, and initial data load.
    func testLaunchToFirstItemPerformance() {
        let metrics: [XCTMetric] = [
            XCTClockMetric(),
            XCTOSSignpostMetric(subsystem: "com.clipkitty.app", category: "Performance", name: "loadItems")
        ]
        
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: metrics, options: options) {
            app.launch()
            
            let firstItem = app.buttons["ItemRow_0"]
            XCTAssertTrue(firstItem.waitForExistence(timeout: 10), "First item did not appear")
            
            // Terminate after each iteration to ensure a fresh launch
            app.terminate()
        }
    }

    /// Measures performance from starting a search until the match is found.
    /// This focuses on search execution and UI update performance.
    func testSearchPerformance() {
        app.launch()
        
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field did not appear")
        
        let metrics: [XCTMetric] = [
            XCTClockMetric(),
            XCTOSSignpostMetric(subsystem: "com.clipkitty.app", category: "Performance", name: "search")
        ]
        
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: metrics, options: options) {
            // Focus and clear search field
            searchField.click()
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(.delete, modifierFlags: [])
            
            // Small wait to ensure state is cleared before starting search
            // In a real perf test, we want to measure the transition from "no search" to "match"
            Thread.sleep(forTimeInterval: 0.2)
            
            // Type the query
            searchField.typeText("fibonacci")
            
            // Wait for the specific result to appear.
            // "fibonacci" matches the first item in simulated DB.
            let firstItem = app.buttons["ItemRow_0"]
            XCTAssertTrue(firstItem.waitForExistence(timeout: 5), "Search result did not appear")
            
            // Stop measuring here if we could, but XCTest measure block timing is for the whole block.
            // The clock metric will include the sleep and setup, but the Signpost metric 
            // will accurately capture the Rust-level search time.
        }
    }
}
