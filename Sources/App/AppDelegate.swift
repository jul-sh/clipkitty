import AppKit
import SwiftUI
import ClipKittyRust

private enum LaunchMode {
    case production
    case simulatedDatabase(initialSearchQuery: String?)

    static func fromCommandLine() -> LaunchMode {
        guard CommandLine.arguments.contains("--use-simulated-db") else {
            return .production
        }

        var searchQuery: String? = nil
        if let searchIndex = CommandLine.arguments.firstIndex(of: "--search"),
           searchIndex + 1 < CommandLine.arguments.count {
            searchQuery = CommandLine.arguments[searchIndex + 1]
        }
        return .simulatedDatabase(initialSearchQuery: searchQuery)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let launchMode: LaunchMode = .fromCommandLine()
    private var panelController: FloatingPanelController!
    private var hotKeyManager: HotKeyManager!
    private var store: ClipboardStore!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var showHistoryMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?
    #if !APP_STORE
    private var updateController: UpdateController?
    #endif

    /// Set activation policy before the app finishes launching.
    /// Without LSUIElement in Info.plist, we must set the policy at runtime.
    /// This fires early enough for XCUITest to see the app as non-"Disabled".
    func applicationWillFinishLaunching(_ notification: Notification) {
        switch launchMode {
        case .production:
            NSApp.setActivationPolicy(.accessory)
        case .simulatedDatabase:
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontManager.registerFonts()

        syncLaunchAtLogin()

        if case .simulatedDatabase = launchMode {
            populateTestDatabase()
        }

        switch launchMode {
        case .production:
            store = ClipboardStore(screenshotMode: false)
            store.startMonitoring()
            panelController = FloatingPanelController(store: store, mode: .production)
        case .simulatedDatabase:
            store = ClipboardStore(screenshotMode: true)
            panelController = FloatingPanelController(store: store, mode: .testing)
        }

        hotKeyManager = HotKeyManager { [weak self] in
            Task { @MainActor in
                self?.panelController.toggle()
            }
        }
        hotKeyManager.register(hotKey: AppSettings.shared.hotKey)

        setupMenuBar()

        #if !APP_STORE
        updateController = UpdateController()
        #endif

        // When using simulated DB, show the panel immediately
        if case .simulatedDatabase(let initialSearchQuery) = launchMode {
            if let searchQuery = initialSearchQuery {
                panelController.initialSearchQuery = searchQuery
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
            button.image = makeStatusItemImage() ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: NSLocalizedString("ClipKitty", comment: "App name used as accessibility description for menu bar icon"))
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        let hotKey = AppSettings.shared.hotKey
        showHistoryMenuItem = NSMenuItem(title: NSLocalizedString("Show Clipboard History", comment: "Menu bar item to show clipboard history panel"), action: #selector(showPanel), keyEquivalent: hotKey.keyEquivalent)
        showHistoryMenuItem?.keyEquivalentModifierMask = hotKey.modifierMask
        menu.addItem(showHistoryMenuItem!)
        menu.addItem(NSMenuItem.separator())
        #if !APP_STORE
        menu.addItem(NSMenuItem(title: NSLocalizedString("Check for Updates...", comment: "Menu bar item to check for app updates"), action: #selector(checkForUpdates), keyEquivalent: ""))
        #endif
        menu.addItem(NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu bar item to open settings window"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: "Menu bar item to quit the app"), action: #selector(quit), keyEquivalent: "q"))

        statusMenu = menu
        updateMenuBarBehavior()
    }

    /// Update menu bar click behavior based on settings
    func updateMenuBarBehavior() {
        if AppSettings.shared.clickToOpenEnabled {
            // Click opens panel, right-click shows menu
            statusItem?.menu = nil
        } else {
            // Default: click shows menu
            statusItem?.menu = statusMenu
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if AppSettings.shared.clickToOpenEnabled {
            if event.type == .rightMouseUp {
                // Right-click shows the menu
                if let menu = statusMenu {
                    statusItem?.menu = menu
                    statusItem?.button?.performClick(nil)
                    statusItem?.menu = nil
                }
            } else {
                // Left-click toggles the panel (show if hidden, hide if visible)
                panelController.toggle()
            }
        } else {
            // Default behavior: menu is always attached, this shouldn't be called
            // but just in case, toggle the panel
            panelController.toggle()
        }
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
            let settingsView = SettingsView(
                store: store,
                onHotKeyChanged: { [weak self] hotKey in
                    self?.hotKeyManager.register(hotKey: hotKey)
                    self?.updateMenuHotKey()
                },
                onMenuBarBehaviorChanged: { [weak self] in
                    self?.updateMenuBarBehavior()
                }
            )

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("ClipKitty Settings", comment: "Settings window title")
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

    #if !APP_STORE
    @objc private func checkForUpdates() {
        updateController?.checkForUpdates()
    }
    #endif

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
            launchAtLogin.setDisabledDueToLocationError()
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

