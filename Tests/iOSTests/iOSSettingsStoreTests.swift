@testable import ClipKittyiOS
import XCTest

@MainActor
final class iOSSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "iOSSettingsStoreTests")!
        defaults.removePersistentDomain(forName: "iOSSettingsStoreTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "iOSSettingsStoreTests")
        defaults = nil
        super.tearDown()
    }

    func testDefaultValues() {
        let store = iOSSettingsStore(defaults: defaults)
        XCTAssertTrue(store.hapticsEnabled)
        XCTAssertTrue(store.generateLinkPreviews)
        XCTAssertFalse(store.autoAddFromClipboard)
        XCTAssertEqual(store.lastIngestedPasteboardChangeCount, 0)
    }

    func testLastIngestedPasteboardChangeCountPersists() {
        let store = iOSSettingsStore(defaults: defaults)
        store.lastIngestedPasteboardChangeCount = 42

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.lastIngestedPasteboardChangeCount, 42)
    }

    func testHapticsEnabledPersists() {
        let store = iOSSettingsStore(defaults: defaults)
        store.hapticsEnabled = false

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.hapticsEnabled)
    }

    func testGenerateLinkPreviewsPersists() {
        let store = iOSSettingsStore(defaults: defaults)
        store.generateLinkPreviews = false

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.generateLinkPreviews)
    }

    func testAutoAddFromClipboardPersists() {
        let store = iOSSettingsStore(defaults: defaults)
        store.autoAddFromClipboard = true

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.autoAddFromClipboard)
    }

    func testMultipleSettingsPersistIndependently() {
        let store = iOSSettingsStore(defaults: defaults)
        store.hapticsEnabled = false
        store.generateLinkPreviews = true
        store.autoAddFromClipboard = true

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.hapticsEnabled)
        XCTAssertTrue(reloaded.generateLinkPreviews)
        XCTAssertTrue(reloaded.autoAddFromClipboard)
    }

    func testToggleBackAndForth() {
        let store = iOSSettingsStore(defaults: defaults)

        store.hapticsEnabled = false
        XCTAssertFalse(iOSSettingsStore(defaults: defaults).hapticsEnabled)

        store.hapticsEnabled = true
        XCTAssertTrue(iOSSettingsStore(defaults: defaults).hapticsEnabled)
    }
}
