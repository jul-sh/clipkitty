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
    private var welcomeWindowController: WelcomeWindowController?
    private var showHistoryMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?
    private var cancellables = Set<AnyCancellable>()
    private var snackbarCoordinator: SnackbarCoordinator!
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

        if case .simulatedDatabase = launchMode {
            populateTestDatabase()
        }

        switch launchMode {
        case .production:
            store = ClipboardStore(screenshotMode: false)
        case .simulatedDatabase:
            store = ClipboardStore(screenshotMode: true)
        }

        snackbarCoordinator = SnackbarCoordinator(store: store)
        snackbarCoordinator.syncWithSystem()

        switch launchMode {
        case .production:
            panelController = FloatingPanelController(store: store, mode: .production, snackbarCoordinator: snackbarCoordinator)
        case .simulatedDatabase:
            panelController = FloatingPanelController(store: store, mode: .testing, snackbarCoordinator: snackbarCoordinator)
        }

        // Start monitoring after bootstrap completes. When no rebuild is needed
        // the store is already ready synchronously, so this fires immediately.
        Task {
            await store.awaitReady()
            self.store.startMonitoring()
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
                case .checking: AppSettings.shared.updateCheckState = .checking
                case .downloading: AppSettings.shared.updateCheckState = .downloading
                case .installing: AppSettings.shared.updateCheckState = .installing
                case .available: AppSettings.shared.updateCheckState = .available
                case .checkFailed: AppSettings.shared.updateCheckState = .checkFailed
                }
            }
            updater = sparkleUpdater
            snackbarCoordinator.onInstallUpdate = { [weak sparkleUpdater] in
                sparkleUpdater?.installUpdate()
            }
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

        // Show welcome screen on first launch
        if !AppSettings.shared.hasCompletedOnboarding, case .production = launchMode {
            showWelcome()
        }

        // When using simulated DB, wait for bootstrap then show the panel
        if case let .simulatedDatabase(initialSearchQuery) = launchMode {
            if let searchQuery = initialSearchQuery {
                panelController.initialSearchQuery = searchQuery
            }

            Task {
                await store.awaitReady()
                panelController.show()
                NSApp.activate(ignoringOtherApps: true)
            }
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
                    },
                    onCheckForUpdates: { [weak self] in
                        self?.updater?.checkForUpdates()
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

    private func showWelcome() {
        let controller = WelcomeWindowController()
        controller.onComplete = { [weak self] in
            AppSettings.shared.hasCompletedOnboarding = true
            // Also dismiss the launch-at-login prompt since onboarding covers it
            AppSettings.shared.launchAtLoginPromptDismissed = true
            self?.welcomeWindowController = nil
            NSApp.setActivationPolicy(.accessory)
            self?.panelController.show()
        }
        controller.onHotKeyChanged = { [weak self] hotKey in
            self?.hotKeyManager.register(hotKey: hotKey)
            self?.updateMenuHotKey()
        }
        controller.windowDelegate = self
        welcomeWindowController = controller

        NSApp.setActivationPolicy(.regular)
        controller.showWindow()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if let closedWindow = notification.object as? NSWindow,
               closedWindow == self.welcomeWindowController?.window
            {
                // Welcome window closed via X button
                AppSettings.shared.hasCompletedOnboarding = true
                AppSettings.shared.launchAtLoginPromptDismissed = true
                self.welcomeWindowController = nil
            } else {
                // Settings window closed
                self.settingsWindow = nil
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // Prevent macOS from switching to .regular activation policy when the
        // user double-clicks the app icon while it's already running.
        false
    }

    func applicationWillTerminate(_: Notification) {
        store.stopMonitoring()
        hotKeyManager.unregister()
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }
}
