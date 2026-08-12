import AppKit
@testable import ClipKitty
@testable import ClipKittyMacPlatform
import Foundation
import XCTest

private final class FloatingPanelTestFileManager: FileManagerProtocol {
    private let base = FileManager.default
    let applicationSupportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FloatingPanelControllerTests-\(UUID().uuidString)", isDirectory: true)

    func createDirectory(
        at url: URL,
        withIntermediateDirectories: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        try base.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories,
            attributes: attributes
        )
    }

    func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return base.urls(for: directory, in: domainMask)
        }
        return [applicationSupportURL]
    }
}

@MainActor
final class FloatingPanelControllerTests: XCTestCase {
    func testSelectionWaitsUntilProductionPanelIsOrderedOut() async throws {
        let fileManager = FloatingPanelTestFileManager()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileManager.applicationSupportURL)
        }

        let targetApp = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        let workspace = MockWorkspace()
        workspace.frontmostApplication = targetApp
        let pasteboard = MockPasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            workspace: workspace,
            fileManager: fileManager
        )
        await store.awaitReady()

        let controller = FloatingPanelController(
            store: store,
            mode: .production,
            activationService: AppActivationService(workspace: workspace),
            pasteModeProvider: { .copyOnly }
        )
        controller.show()

        let panel = controller.panelForTesting
        defer { panel.orderOut(nil) }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(workspace.frontmostApplication?.processIdentifier, targetApp.processIdentifier)

        let pasteStarted = expectation(description: "Paste preparation started")
        var focusAtPasteStart: (isKey: Bool, isVisible: Bool)?
        var wasVisibleAfterToggle = true
        var pasteStartCount = 0
        controller.pastePreparationDidStartForTesting = {
            pasteStartCount += 1
            focusAtPasteStart = (panel.isKeyWindow, panel.isVisible)
            controller.toggle()
            wasVisibleAfterToggle = panel.isVisible
            pasteStarted.fulfill()
        }

        controller.selectItemForTesting(itemId: "first", content: .text(value: "first"))
        controller.selectItemForTesting(itemId: "second", content: .text(value: "second"))

        await fulfillment(of: [pasteStarted], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(pasteStartCount, 1, "Repeated selection must not launch duplicate paste operations")
        XCTAssertEqual(focusAtPasteStart?.isKey, false, "Paste must not start while ClipKitty owns key focus")
        XCTAssertEqual(focusAtPasteStart?.isVisible, false, "Paste must start after the panel is ordered out")
        XCTAssertFalse(wasVisibleAfterToggle, "The panel must not reopen while paste preparation is active")
        XCTAssertEqual(pasteboard.string(forType: .string), "first")
    }

    func testAppWindowTakesPriorityOverInFlightPasteDismissal() async throws {
        let fileManager = FloatingPanelTestFileManager()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileManager.applicationSupportURL)
        }

        let targetApp = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        let workspace = MockWorkspace()
        workspace.frontmostApplication = targetApp
        let pasteboard = MockPasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            workspace: workspace,
            fileManager: fileManager
        )
        await store.awaitReady()

        let controller = FloatingPanelController(
            store: store,
            mode: .production,
            activationService: AppActivationService(workspace: workspace),
            pasteModeProvider: { .copyOnly }
        )
        controller.show()
        defer { controller.panelForTesting.orderOut(nil) }

        let clipboardWritten = expectation(description: "Selection was copied")
        var pastePreparationStartCount = 0
        controller.pastePreparationDidStartForTesting = {
            pastePreparationStartCount += 1
        }

        controller.selectItemForTesting(itemId: "selection", content: .text(value: "copied"))
        controller.hideForAppWindow()
        Task { @MainActor in
            for _ in 0 ..< 200 where pasteboard.string(forType: .string) != "copied" {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if pasteboard.string(forType: .string) == "copied" {
                clipboardWritten.fulfill()
            }
        }

        await fulfillment(of: [clipboardWritten], timeout: 2)

        XCTAssertEqual(pastePreparationStartCount, 0, "An app window must cancel external-app paste dispatch")
        XCTAssertFalse(controller.panelForTesting.isVisible)
    }

    func testAppWindowDuringPastePreparationKeepsPanelLockedUntilCopyFinishes() async throws {
        let fileManager = FloatingPanelTestFileManager()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileManager.applicationSupportURL)
        }

        let targetApp = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        let workspace = MockWorkspace()
        workspace.frontmostApplication = targetApp
        let pasteboard = MockPasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            workspace: workspace,
            fileManager: fileManager
        )
        await store.awaitReady()

        let controller = FloatingPanelController(
            store: store,
            mode: .production,
            activationService: AppActivationService(workspace: workspace),
            pasteModeProvider: { .copyOnly }
        )
        controller.show()
        defer { controller.panelForTesting.orderOut(nil) }

        let preparationStarted = expectation(description: "Paste preparation started")
        var wasVisibleAfterToggle = true
        controller.pastePreparationDidStartForTesting = {
            controller.hideForAppWindow()
            controller.toggle()
            wasVisibleAfterToggle = controller.panelForTesting.isVisible
            preparationStarted.fulfill()
        }

        controller.selectItemForTesting(itemId: "selection", content: .text(value: "copied"))
        await fulfillment(of: [preparationStarted], timeout: 2)

        XCTAssertFalse(wasVisibleAfterToggle, "The panel must stay locked while the canceled paste becomes a copy")
        XCTAssertEqual(pasteboard.string(forType: .string), "copied")

        try await Task.sleep(for: .milliseconds(200))
        controller.toggle()
        XCTAssertTrue(controller.panelForTesting.isVisible, "The panel lock must clear after the copy finishes")
    }
}
