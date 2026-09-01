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
        XCTAssertTrue(store.generateLinkPreviews)
        XCTAssertFalse(store.autoAddFromClipboard)
        XCTAssertTrue(store.allowShortcutsReadAccess)
        XCTAssertFalse(store.captureSensitiveClips)
        XCTAssertEqual(store.maxDatabaseSizeGB, 7.0, accuracy: 1e-9)
        XCTAssertEqual(store.lastIngestedPasteboardChangeCount, 0)
    }

    func testMaxDatabaseSizeGBPersists() {
        let store = iOSSettingsStore(defaults: defaults)
        store.maxDatabaseSizeGB = 16.0

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.maxDatabaseSizeGB, 16.0, accuracy: 1e-9)
    }

    func testLastIngestedPasteboardChangeCountPersists() {
        let store = iOSSettingsStore(defaults: defaults)
        store.lastIngestedPasteboardChangeCount = 42

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.lastIngestedPasteboardChangeCount, 42)
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
        store.generateLinkPreviews = false
        store.autoAddFromClipboard = true
        store.allowShortcutsReadAccess = false
        store.captureSensitiveClips = true

        let reloaded = iOSSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.generateLinkPreviews)
        XCTAssertTrue(reloaded.autoAddFromClipboard)
        XCTAssertFalse(reloaded.allowShortcutsReadAccess)
        XCTAssertTrue(reloaded.captureSensitiveClips)
    }

    func testChangingOneSettingDoesNotOverwriteAnotherKey() {
        let store = iOSSettingsStore(defaults: defaults)
        defaults.set(false, forKey: "iOSGenerateLinkPreviews")

        store.autoAddFromClipboard = true

        XCTAssertFalse(defaults.bool(forKey: "iOSGenerateLinkPreviews"))
    }

    func testCaptureSensitiveClipsTogglesBackAndForth() {
        let store = iOSSettingsStore(defaults: defaults)

        store.captureSensitiveClips = true
        XCTAssertTrue(iOSSettingsStore(defaults: defaults).captureSensitiveClips)

        store.captureSensitiveClips = false
        XCTAssertFalse(iOSSettingsStore(defaults: defaults).captureSensitiveClips)
    }
}
