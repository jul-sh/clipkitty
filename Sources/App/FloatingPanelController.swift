import AppKit
import SwiftUI
import ClipKittyRust

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    enum Visibility {
        case visible
        case hidden
    }

    private var panel: NSPanel!
    private let store: ClipboardStore
    private var previousApp: NSRunningApplication?

    /// Initial search query to pre-fill (for CI screenshots)
    var initialSearchQuery: String?

    init(store: ClipboardStore) {
        self.store = store
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 778, height: 518),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = false

        updatePanelContent()
    }

    private func updatePanelContent() {
        let contentView = ContentView(
            store: store,
            onSelect: { [weak self] item in
                self?.selectItem(item)
            },
            onDismiss: { [weak self] in
                self?.hide()
            },
            initialSearchQuery: initialSearchQuery ?? ""
        )
        panel.contentView = NSHostingView(rootView: contentView)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            hide()
        }
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    var visibility: Visibility {
        panel.isVisible ? .visible : .hidden
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        // Update content to apply any initial search query
        if initialSearchQuery != nil {
            updatePanelContent()
        }
        store.prepareForDisplay()
        centerPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel.orderOut(nil)
        store.resetForDisplay()
        previousApp?.activate()
        previousApp = nil
    }

    private func centerPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame

        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2 + screenFrame.height * 0.1

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func selectItem(_ item: ClipboardItem) {
        store.paste(item: item)
        hide()
        if AppSettings.shared.pasteOnSelect {
            simulatePaste()
        }
    }

    /// Simulate Cmd+V keystroke to paste into the previous app
    private func simulatePaste() {
        // Small delay to ensure the previous app is focused
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)

            // Key down: Cmd+V
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = V
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            // Key up: Cmd+V
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
