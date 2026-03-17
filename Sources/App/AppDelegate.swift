import AppKit
import ClipKittyRust
import Combine
import SwiftUI
#if SPARKLE_RELEASE
    import SparkleUpdater
#endif

private enum LaunchMode {
    case production
    case simulatedDatabase(initialSearchQuery: String?)

    static func fromCommandLine() -> LaunchMode {
        guard CommandLine.arguments.contains("--use-simulated-db") else {
            return .production
        }

        var searchQuery: String? = nil
        if let searchIndex = CommandLine.arguments.firstIndex(of: "--search"),
           searchIndex + 1 < CommandLine.arguments.count
        {
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
    private var cancellables = Set<AnyCancellable>()
    #if SPARKLE_RELEASE
        private var updater: SparkleAppUpdater?
    #endif

    /// Set activation policy before the app finishes launching.
    /// Without LSUIElement in Info.plist, we must set the policy at runtime.
    /// This fires early enough for XCUITest to see the app as non-"Disabled".
    func applicationWillFinishLaunching(_: Notification) {
        switch launchMode {
        case .production:
            NSApp.setActivationPolicy(.accessory)
        case .simulatedDatabase:
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
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

        #if SPARKLE_RELEASE
            let sparkleUpdater = SparkleAppUpdater()
            sparkleUpdater.start { state in
                // Convert SparkleUpdater.UpdateCheckState to app's UpdateCheckState
                switch state {
                case .idle: AppSettings.shared.updateCheckState = .idle
                case .available: AppSettings.shared.updateCheckState = .available
                case .checkFailed: AppSettings.shared.updateCheckState = .checkFailed
                }
            }
            updater = sparkleUpdater
            AppSettings.shared.$autoInstallUpdates
                .dropFirst()
                .sink { [weak sparkleUpdater] enabled in
                    sparkleUpdater?.setAutoInstall(enabled)
                }
                .store(in: &cancellables)
            sparkleUpdater.setUpdateChannel(AppSettings.shared.updateChannel)
            AppSettings.shared.$updateChannel
                .dropFirst()
                .sink { [weak sparkleUpdater] channel in
                    sparkleUpdater?.setUpdateChannel(channel)
                }
                .store(in: &cancellables)
        #endif

        // When using simulated DB, show the panel immediately
        if case let .simulatedDatabase(initialSearchQuery) = launchMode {
            if let searchQuery = initialSearchQuery {
                panelController.initialSearchQuery = searchQuery
            }

            panelController.show()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Ensure the simulated database directory exists (UI Test runner handles file placement)
    private func populateTestDatabase() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
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
        menu.addItem(NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu bar item to open settings window"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: "Menu bar item to quit the app"), action: #selector(quit), keyEquivalent: "q"))

        statusMenu = menu
        configureMenuBarBehavior()
    }

    /// Configure menu bar: click opens panel, right-click shows menu
    private func configureMenuBarBehavior() {
        // No menu attached - we handle clicks manually
        statusItem?.menu = nil
    }

    @objc private func statusItemClicked(_: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click shows the menu
            if let menu = statusMenu {
                statusItem?.menu = menu
                statusItem?.button?.performClick(nil)
                // Remove menu asynchronously to let the menu system handle it
                DispatchQueue.main.async { [weak self] in
                    self?.statusItem?.menu = nil
                }
            }
        } else {
            // Left-click toggles the panel
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
              let image = NSImage(contentsOf: url)
        else {
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
            #if SPARKLE_RELEASE
                let settingsView = SettingsView(
                    store: store,
                    onHotKeyChanged: { [weak self] hotKey in
                        self?.hotKeyManager.register(hotKey: hotKey)
                        self?.updateMenuHotKey()
                    },
                    onInstallUpdate: { [weak self] in
                        self?.updater?.installUpdate()
                    }
                )
            #else
                let settingsView = SettingsView(
                    store: store,
                    onHotKeyChanged: { [weak self] hotKey in
                        self?.hotKeyManager.register(hotKey: hotKey)
                        self?.updateMenuHotKey()
                    }
                )
            #endif

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

    nonisolated func windowWillClose(_: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            // Nullify window reference when closed to refresh content on next open
            self.settingsWindow = nil
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Synchronize launch at login state with user preference on startup.
    /// Re-registers if the user wants it enabled but the system state disagrees
    /// (e.g. after an app update or move).
    private func syncLaunchAtLogin() {
        let launchAtLogin = LaunchAtLogin.shared
        let settings = AppSettings.shared

        if settings.launchAtLoginEnabled, !launchAtLogin.isEnabled {
            launchAtLogin.enable()
        }
    }

    func applicationWillTerminate(_: Notification) {
        store.stopMonitoring()
        hotKeyManager.unregister()
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }
}
