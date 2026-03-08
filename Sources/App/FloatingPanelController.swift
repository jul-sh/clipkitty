import AppKit
import SwiftUI
import ClipKittyRust

enum PanelMode {
    case production
    case testing
}

// MARK: - Panel State Machine

/// State machine for panel visibility with transition states to prevent race conditions.
/// Valid transitions:
///   hidden -> showing -> visible
///   visible -> hiding -> hidden
///   showing -> hiding (cancel show)
///   hiding -> showing (cancel hide)
private enum PanelState: Equatable {
    case hidden
    case showing(previousApp: NSRunningApplication?)
    case visible(previousApp: NSRunningApplication?)
    case hiding(previousApp: NSRunningApplication?)

    /// Whether the panel is in a transitioning state
    var isTransitioning: Bool {
        switch self {
        case .showing, .hiding: return true
        case .hidden, .visible: return false
        }
    }

    /// Whether the panel should be considered "open" (showing or visible)
    var isOpen: Bool {
        switch self {
        case .showing, .visible: return true
        case .hidden, .hiding: return false
        }
    }

    /// The previous app captured when showing, if any
    var previousApp: NSRunningApplication? {
        switch self {
        case .hidden: return nil
        case .showing(let app), .visible(let app), .hiding(let app): return app
        }
    }

    // Equatable conformance for NSRunningApplication comparison
    static func == (lhs: PanelState, rhs: PanelState) -> Bool {
        switch (lhs, rhs) {
        case (.hidden, .hidden): return true
        case (.showing(let a), .showing(let b)): return a == b
        case (.visible(let a), .visible(let b)): return a == b
        case (.hiding(let a), .hiding(let b)): return a == b
        default: return false
        }
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel!
    private let store: ClipboardStore
    private let mode: PanelMode
    private var panelState: PanelState = .hidden

    /// Debounce interval to prevent rapid toggle race conditions
    private var lastToggleTime: Date?
    private let toggleDebounceInterval: TimeInterval = 0.15

    /// Initial search query to pre-fill (for CI screenshots)
    var initialSearchQuery: String?

    init(store: ClipboardStore, mode: PanelMode = .production) {
        self.store = store
        self.mode = mode
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        // Testing mode differences:
        //
        // styleMask: Omit .nonactivatingPanel so XCUITest can discover the window.
        // NSPanel with .nonactivatingPanel is invisible to the accessibility hierarchy.
        // Safeguard: UI tests verify the panel is discoverable and interactive.
        //
        // windowLevel: Use a high custom level (2002) to ensure the panel appears above
        // other windows during test screenshots, since .floating level may not suffice
        // without .nonactivatingPanel.
        // Safeguard: UI tests verify panel visibility and z-ordering in screenshots.
        let styleMask: NSWindow.StyleMask
        let windowLevel: NSWindow.Level
        switch mode {
        case .production:
            styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
            windowLevel = .floating
        case .testing:
            styleMask = [.titled, .fullSizeContentView]
            windowLevel = NSWindow.Level(rawValue: 2002)
        }

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 778, height: 518),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        // isFloatingPanel must match whether styleMask contains .nonactivatingPanel,
        // otherwise focus behaves incorrectly. Derived from styleMask to make this invariant unbreakable.
        panel.isFloatingPanel = styleMask.contains(.nonactivatingPanel)
        panel.level = windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
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
            onSelect: { [weak self] itemId, content in
                self?.selectItem(itemId: itemId, content: content)
            },
            onCopyOnly: { [weak self] itemId, content in
                self?.copyOnlyItem(itemId: itemId, content: content)
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
            // shouldDismissOnResignKey: In production, panel hides when it loses focus
            // (user clicked elsewhere). In testing, panel must stay visible so XCUITest
            // can interact with it across multiple actions.
            // Safeguard: UI tests explicitly verify panel dismiss behavior via escape key.
            if case .production = mode {
                hide()
            }
        }
    }

    func toggle() {
        // Debounce rapid toggles to prevent race conditions
        let now = Date()
        if let lastToggle = lastToggleTime,
           now.timeIntervalSince(lastToggle) < toggleDebounceInterval {
            return
        }
        lastToggleTime = now

        switch panelState {
        case .hidden, .hiding:
            show()
        case .visible, .showing:
            hide()
        }
    }

    func show() {
        // Guard: only allow show from hidden or hiding states
        switch panelState {
        case .visible, .showing:
            return  // Already visible or showing
        case .hidden, .hiding:
            break   // Valid transition
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        panelState = .showing(previousApp: previousApp)

        // Update content to apply any initial search query
        if initialSearchQuery != nil {
            updatePanelContent()
        }
        centerPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Transition to stable visible state
        panelState = .visible(previousApp: previousApp)
    }

    func hide() {
        // Guard: only allow hide from visible or showing states
        let previousApp: NSRunningApplication?
        switch panelState {
        case .hidden, .hiding:
            return  // Already hidden or hiding
        case .visible(let app), .showing(let app):
            previousApp = app
        }

        panelState = .hiding(previousApp: previousApp)

        panel.orderOut(nil)
        store.resetForDisplay()

        // Only activate previous app if it hasn't been terminated
        if let app = previousApp, !app.isTerminated {
            app.activate()
        }

        panelState = .hidden
    }

    private func centerPanel() {
        // Fallback to any available screen if main screen is unavailable
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame

        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2 + screenFrame.height * 0.1

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func selectItem(itemId: Int64, content: ClipboardContent) {
        store.paste(itemId: itemId, content: content)
        // Capture previous app before hiding (uses state machine's previousApp property)
        let targetApp = panelState.previousApp
        hide()
        if case .autoPaste = AppSettings.shared.pasteMode {
            simulatePaste(targetApp: targetApp)
        } else {
            // Show toast when copying without auto-paste
            ToastWindow.shared.show(message: String(localized: "Copied"))
        }
    }

    private func copyOnlyItem(itemId: Int64, content: ClipboardContent) {
        store.paste(itemId: itemId, content: content)
        hide()
        ToastWindow.shared.show(message: String(localized: "Copied"))
    }

    /// Simulate Cmd+V keystroke to paste into the target app
    private func simulatePaste(targetApp: NSRunningApplication?) {
        guard let targetApp = targetApp, !targetApp.isTerminated else {
            return
        }

        // Wait for the target app to become active before sending keystroke
        Task {
            // Poll until the target app is active (max ~500ms)
            for _ in 0..<50 {
                // Check if app was terminated during polling
                guard !targetApp.isTerminated else { return }
                if NSWorkspace.shared.frontmostApplication == targetApp {
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            await MainActor.run {
                guard let source = CGEventSource(stateID: .hidSystemState) else {
                    return
                }

                // Key down: Cmd+V
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
                    return
                }
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cgSessionEventTap)

                // Key up: Cmd+V
                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
                    return
                }
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cgSessionEventTap)
            }
        }
    }
}
