import AppKit
import SwiftUI
import ClipKittyCore

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    enum Visibility {
        case visible
        case hidden
    }

    private var panel: NSPanel!
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 778, height: 505),
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

        // Add empty toolbar to get macOS Tahoe's 26pt corner radius (vs 16pt for titlebar-only windows)
        let toolbar = NSToolbar()
        panel.toolbar = toolbar

        let contentView = ContentView(
            store: store,
            onSelect: { [weak self] item in
                self?.selectItem(item)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
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
        store.resetForDisplay()

        // Recreate content view to reset all state (search text, selection, focus)
        let contentView = ContentView(
            store: store,
            onSelect: { [weak self] item in
                self?.selectItem(item)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
        panel.contentView = NSHostingView(rootView: contentView)

        centerPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel.orderOut(nil)
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
    }
}
