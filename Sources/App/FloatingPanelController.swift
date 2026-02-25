import AppKit
import SwiftUI
import ClipKittyRust

enum PanelMode {
    case production
    case testing
}

private enum PanelState {
    case hidden
    case visible(previousApp: NSRunningApplication?)
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel!
    private let store: ClipboardStore
    private let mode: PanelMode
    private var panelState: PanelState = .hidden

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
        switch panelState {
        case .hidden:
            show()
        case .visible:
            hide()
        }
    }

    func show() {
        let previousApp = NSWorkspace.shared.frontmostApplication
        panelState = .visible(previousApp: previousApp)
        // Update content to apply any initial search query
        if initialSearchQuery != nil {
            updatePanelContent()
        }
        centerPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        guard case .visible(let previousApp) = panelState else { return }
        panel.orderOut(nil)
        store.resetForDisplay()
        previousApp?.activate()
        panelState = .hidden
    }

    private func centerPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame

        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2 + screenFrame.height * 0.1

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func selectItem(itemId: Int64, content: ClipboardContent) {
        store.paste(itemId: itemId, content: content)
        let targetApp: NSRunningApplication?
        if case .visible(let previousApp) = panelState {
            targetApp = previousApp
        } else {
            targetApp = nil
        }
        hide()

        // Skip auto-paste for remote desktop apps — their clipboard protocol (CLIPRDR)
        // uses lazy sync, and simulating Cmd+V causes the remote side to paste stale
        // content or leaves the Cmd key stuck. Just restore to clipboard and let the
        // user paste manually.
        let isRemoteDesktop = targetApp?.bundleIdentifier
            .map { Self.remoteDesktopBundleIDs.contains($0) } ?? false

        if case .autoPaste = AppSettings.shared.pasteMode, !isRemoteDesktop {
            simulatePaste(targetApp: targetApp)
        }
    }

    private func copyOnlyItem(itemId: Int64, content: ClipboardContent) {
        store.paste(itemId: itemId, content: content)
        hide()
    }

    /// Known remote desktop app bundle IDs. Auto-paste is disabled for these apps
    /// because their clipboard protocol (CLIPRDR) uses lazy sync — simulating Cmd+V
    /// causes stale pastes or leaves modifier keys stuck on the remote side.
    private static let remoteDesktopBundleIDs: Set<String> = [
        "com.microsoft.rdc.macos",        // Microsoft Remote Desktop
        "com.microsoft.rdc.osx",          // Microsoft Remote Desktop (older)
        "com.royalapps.royaltsx",         // Royal TSX
        "net.parallels.desktop.console",  // Parallels Desktop
        "com.vmware.fusion",              // VMware Fusion
        "com.citrix.XenAppViewer",        // Citrix Workspace
        "com.citrix.receiver.icaviewer",  // Citrix Receiver
        "com.realvnc.vncviewer",          // RealVNC Viewer
        "com.tigervnc.vncviewer",         // TigerVNC
        "org.turbovnc.vncviewer",         // TurboVNC
        "com.thinomenon.remotix",         // Remotix
        "com.nulana.rxcontrolmac",        // Remote Desktop Manager
        "com.devolutions.remotedesktopmanager", // Devolutions RDM
        "com.teamviewer.TeamViewer",      // TeamViewer
        "us.zoom.xos",                    // Zoom (remote control)
        "com.anydesk.anydesk",            // AnyDesk
    ]

    /// Simulate Cmd+V keystroke to paste into the target app
    private func simulatePaste(targetApp: NSRunningApplication?) {
        guard let targetApp = targetApp else {
            return
        }

        // Wait for the target app to become active before sending keystroke
        Task {
            // Poll until the target app is active (max ~500ms)
            for _ in 0..<50 {
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
