import AppKit
import SwiftUI
import ClipKittyRust

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

        // Sync launch at login state with user preference
        syncLaunchAtLogin()

        // Use simulated database with test data (for UI tests and screenshots)
        let useSimulatedDb = CommandLine.arguments.contains("--use-simulated-db")
        let shouldShow = useSimulatedDb

        if useSimulatedDb {
            populateTestDatabase()
        }

        store = ClipboardStore(screenshotMode: useSimulatedDb)
        if !useSimulatedDb {
            store.startMonitoring()
        }

        panelController = FloatingPanelController(store: store)

        hotKeyManager = HotKeyManager { [weak self] in
            Task { @MainActor in
                self?.panelController.toggle()
            }
        }
        hotKeyManager.register(hotKey: AppSettings.shared.hotKey)

        setupMenuBar()

        // When using simulated DB or --show, show the panel immediately
        if shouldShow {
            // Check for --search argument
            if let searchIndex = CommandLine.arguments.firstIndex(of: "--search"),
               searchIndex + 1 < CommandLine.arguments.count {
                panelController.initialSearchQuery = CommandLine.arguments[searchIndex + 1]
            }

            panelController.show()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Ensure the simulated database directory exists (UI Test runner handles file placement)
    private func populateTestDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeStatusItemImage() ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipKitty")
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
        statusItem?.menu = menu
    }

    private func updateMenuHotKey() {
        let hotKey = AppSettings.shared.hotKey
        showHistoryMenuItem?.keyEquivalent = hotKey.keyEquivalent
        showHistoryMenuItem?.keyEquivalentModifierMask = hotKey.modifierMask
    }

    private func makeStatusItemImage() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "menu-bar", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func showPanel() {
        panelController.show()
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

    /// Synchronize launch at login state with user preference on startup.
    /// This handles cases where:
    /// - The app was moved to/from Applications directory
    /// - The system state differs from user preference
    /// - First launch: auto-enable if in Applications
    private func syncLaunchAtLogin() {
        let launchAtLogin = LaunchAtLogin.shared
        let settings = AppSettings.shared

        // If user wants launch at login enabled and we're in Applications
        if settings.launchAtLoginEnabled && launchAtLogin.isInApplicationsDirectory {
            if !launchAtLogin.isEnabled {
                // Re-register (handles app being moved/updated)
                launchAtLogin.enable()
            }
        } else if settings.launchAtLoginEnabled && !launchAtLogin.isInApplicationsDirectory {
            // User wants it enabled but app is not in Applications - disable the preference
            settings.launchAtLoginEnabled = false
            launchAtLogin.errorMessage = "Launch at login was disabled because ClipKitty is not in the Applications folder."
            if launchAtLogin.isEnabled {
                launchAtLogin.disable()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopMonitoring()
        hotKeyManager.unregister()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

