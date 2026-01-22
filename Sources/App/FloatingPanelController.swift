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
        let targetApp = previousApp
        hide()
        #if !SANDBOXED
        // Always attempt to paste in non-sandboxed mode
        simulatePaste(targetApp: targetApp)
        #endif
    }

    #if !SANDBOXED
    /// Simulate Cmd+V keystroke to paste into the target app
    private func simulatePaste(targetApp: NSRunningApplication?) {
        guard let targetApp = targetApp else {
            logError("No target app to paste into")
            return
        }

        logInfo("simulatePaste: targeting \(targetApp.localizedName ?? "unknown")")

        // Wait for the target app to become active before sending keystroke
        Task {
            // Poll until the target app is active (max ~500ms)
            var attempts = 0
            for _ in 0..<50 {
                attempts += 1
                if NSWorkspace.shared.frontmostApplication == targetApp {
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            logInfo("simulatePaste: after \(attempts) attempts, frontmost app is \(frontmost)")

            await MainActor.run {
                guard let source = CGEventSource(stateID: .hidSystemState) else {
                    logError("Failed to create CGEventSource - check Accessibility permissions")
                    return
                }
                logInfo("simulatePaste: CGEventSource created")

                // Key down: Cmd+V
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
                    logError("Failed to create keyDown event")
                    return
                }
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cgSessionEventTap)
                logInfo("simulatePaste: keyDown posted")

                // Key up: Cmd+V
                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
                    logError("Failed to create keyUp event")
                    return
                }
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cgSessionEventTap)
                logInfo("simulatePaste: keyUp posted - paste complete")
            }
        }
    }
    #endif
}
