import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panelController: FloatingPanelController!
    private var hotKeyManager: HotKeyManager!
    private var store: ClipboardStore!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var showHistoryMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontManager.registerFonts()

        enableLaunchAtLogin()

        store = ClipboardStore()
        store.startMonitoring()

        panelController = FloatingPanelController(store: store) { [weak self] in
            self?.simulatePaste()
        }

        hotKeyManager = HotKeyManager { [weak self] in
            Task { @MainActor in
                self?.panelController.toggle()
            }
        }
        hotKeyManager.register(hotKey: AppSettings.shared.hotKey)

        setupMenuBar()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipKitty")
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        let hotKey = AppSettings.shared.hotKey
        showHistoryMenuItem = NSMenuItem(title: "Show Clipboard History", action: #selector(showPanel), keyEquivalent: hotKey.keyEquivalent)
        showHistoryMenuItem?.keyEquivalentModifierMask = hotKey.modifierMask
        menu.addItem(showHistoryMenuItem!)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusMenu = menu
    }

    private func enableLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Failed to enable launch at login: \(error)")
        }
    }

    private func updateMenuHotKey() {
        let hotKey = AppSettings.shared.hotKey
        showHistoryMenuItem?.keyEquivalent = hotKey.keyEquivalent
        showHistoryMenuItem?.keyEquivalentModifierMask = hotKey.modifierMask
    }

    @objc private func showPanel() {
        panelController.show()
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            panelController.show()
            return
        }

        if event.type == .rightMouseUp || event.type == .rightMouseDown {
            if let menu = statusMenu, let button = statusItem?.button {
                NSMenu.popUpContextMenu(menu, with: event, for: button)
            }
        } else {
            panelController.show()
        }
    }



    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(store: store) { [weak self] hotKey in
                self?.hotKeyManager.register(hotKey: hotKey)
                self?.updateMenuHotKey()
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClipKitty Settings"
            window.contentView = NSHostingView(rootView: settingsView)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopMonitoring()
        hotKeyManager.unregister()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
