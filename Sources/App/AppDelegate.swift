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

        // When using simulated DB, show the panel immediately
        if useSimulatedDb {
            // Check for --search argument
            if let searchIndex = CommandLine.arguments.firstIndex(of: "--search"),
               searchIndex + 1 < CommandLine.arguments.count {
                panelController.initialSearchQuery = CommandLine.arguments[searchIndex + 1]
            }

            panelController.show()
        }
    }

    /// Populate database with test data for screenshots (uses separate database to preserve user data)
    private func populateTestDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let dbPath = appDir.appendingPathComponent(ClipboardStore.databaseFilename(screenshotMode: true)).path

        // Remove existing screenshot database for clean state (never touches the real database)
        try? FileManager.default.removeItem(atPath: dbPath)

        do {
            // Use the Rust store to populate test data
            let rustStore = try ClipKittyRust.ClipboardStore(dbPath: dbPath)

            // Bundle ID mapping to preinstalled macOS apps
            // Note: Use preinstalled macOS apps for App Store compliance
            let numbers = "com.apple.Numbers"          // TablePlus replacement
            let passwords = "com.apple.Passwords"      // 1Password replacement
            let textEdit = "com.apple.TextEdit"        // VS Code replacement
            let notes = "com.apple.Notes"              // Notes (stock)
            let freeform = "com.apple.freeform"        // Figma replacement
            let reminders = "com.apple.reminders"      // Notion replacement
            let safari = "com.apple.Safari"            // Safari (stock)
            let terminal = "com.apple.Terminal"        // Terminal (stock)
            let automator = "com.apple.Automator"      // Xcode replacement
            let preview = "com.apple.Preview"          // Sketch replacement
            let mail = "com.apple.mail"                // Postman replacement
            let stickies = "com.apple.Stickies"        // Obsidian replacement
            let pages = "com.apple.iWork.Pages"        // Pages (stock)
            let finder = "com.apple.finder"            // Finder (stock)
            let photos = "com.apple.Photos"            // Photos (stock)

            // Test items ordered from OLDEST to NEWEST (reverse of display order)
            // Items are inserted oldest first, so most recent appears at top of list
            // Format: (content, sourceApp name, bundleID, optionalOldTimestamp)
            let testItems: [(String, String, String, Int64?)] = [
                // --- Scene 3: Typo Forgiveness items (oldest, some with old timestamps) ---

                // The "6 months old" apartment note - set to Jul 14, 2025
                ("Apartment walkthrough notes: 437 Riverside Dr #12, hardwood floors throughout, south-facing windows with park views, original crown molding, in-unit washer/dryer, $2850/mo, super lives on-site, contact Marcus Realty about lease terms and move-in date flexibility...", "Notes", notes,
                 1752451200), // Jul 14, 2025 00:00:00 UTC

                // Other Scene 3 support items
                ("riverside_park_picnic_directions.txt", "Notes", notes, nil),
                ("driver_config.yaml", "TextEdit", textEdit, nil),
                ("river_animation_keyframes.css", "TextEdit", textEdit, nil),
                ("derive_key_from_password(salt: Data, iterations: Int) -> Data { ... }", "Automator", automator, nil),
                ("private_key_backup.pem", "Finder", finder, nil),
                ("return fetchData().then(res => res.json()).catch(handleError)...", "TextEdit", textEdit, nil),
                ("README.md", "Finder", finder, nil),
                ("RFC 2616 HTTP/1.1 Specification full text...", "Safari", safari, nil),
                ("grep -rn \"TODO\\|FIXME\" ./src", "Terminal", terminal, nil),
                ("border-radius: 8px;", "TextEdit", textEdit, nil),

                // --- Scene 2: Color and Image items ---

                // Images (with AI-labeled descriptions)
                ("Orange tabby cat sleeping on mechanical keyboard", "Photos", photos, nil),
                ("Architecture diagram with service mesh", "Safari", safari, nil),

                // Colors (hex codes)
                ("#7C3AED", "Freeform", freeform, nil),  // Purple
                ("#FF5733", "Freeform", freeform, nil),  // Orange
                ("#2DD4BF", "Preview", preview, nil),     // Teal
                ("#1E293B", "Freeform", freeform, nil),  // Dark slate
                ("#F472B6", "Preview", preview, nil),     // Pink

                // Large CSS file for # search
                ("#border-container { margin: 0; padding: 16px; display: flex; flex-direction: column; ...", "TextEdit", textEdit, nil),

                // Other Scene 2 items
                ("catalog_api_response.json", "Mail", mail, nil),
                ("catch (error) { logger.error(error); Sentry.captureException(error); ...", "TextEdit", textEdit, nil),
                ("concatenate_strings(a, b)", "TextEdit", textEdit, nil),
                ("categories: [{ id: 1, name: \"Electronics\", subcategories: [...] }]", "TextEdit", textEdit, nil),

                // --- Scene 1: Meta Pitch items ---

                // Hello-related items (for "hello" search refinement)
                ("Hello ClipKitty!\n\n• Unlimited History\n• Instant Search\n• Private\n\nYour clipboard, supercharged.", "Notes", notes, nil),  // Marketing blurb
                ("Hello and welcome to the onboarding flow for new team members. This document covers everything you need to know about getting started...", "Reminders", reminders, nil),
                ("hello_world.py", "Finder", finder, nil),
                ("sayHello(user: User) -> String { ... }", "Automator", automator, nil),
                ("Othello character analysis notes", "Pages", pages, nil),
                ("hello_config.json", "TextEdit", textEdit, nil),
                ("client_hello_handshake()", "TextEdit", textEdit, nil),
                ("clipboard_manager_notes.md", "Stickies", stickies, nil),
                ("cache_hello_responses()", "TextEdit", textEdit, nil),
                ("check_health_status()", "TextEdit", textEdit, nil),
                ("HashMap<String, Vec<Box<dyn Handler>>>", "TextEdit", textEdit, nil),

                // Default/empty state items (most recent, shown at 0:00)
                ("The quick brown fox jumps over the lazy dog", "Notes", notes, nil),
                ("https://developer.apple.com/documentation/swiftui", "Safari", safari, nil),
                ("sk-proj-Tj7X9...", "Passwords", passwords, nil),  // API key
                ("#!/bin/bash\nset -euo pipefail\necho \"Deploying to prod...\"", "TextEdit", textEdit, nil),
                ("SELECT users.name, orders.total FROM orders JOIN users ON users.id = orders.user_id WHERE orders.status = 'completed' AND orders.created_at > NOW() - INTERVAL '30 days' ORDER BY orders.total DESC LIMIT 100;", "Numbers", numbers, nil),  // SQL query (most recent - top of list)
            ]

            // Insert items oldest first so most recent ends up at top
            for (index, (content, sourceApp, bundleID, oldTimestamp)) in testItems.enumerated() {
                let itemId = try rustStore.saveText(text: content, sourceApp: sourceApp, sourceAppBundleId: bundleID)

                // Set old timestamp if specified (e.g., for the "6 months ago" apartment note)
                if let timestamp = oldTimestamp, itemId > 0 {
                    try rustStore.setTimestamp(itemId: itemId, timestampUnix: timestamp)
                }

                // Small delay between inserts to ensure different timestamps for recent items
                if index < testItems.count - 1 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        } catch {
            logError("Failed to populate test database: \(error)")
        }
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
    private func syncLaunchAtLogin() {
        let launchAtLogin = LaunchAtLogin.shared
        let settings = AppSettings.shared

        // Refresh the actual system state
        launchAtLogin.refresh()

        // If user wants launch at login enabled and we're in Applications
        if settings.launchAtLoginEnabled && launchAtLogin.isInApplicationsDirectory {
            if !launchAtLogin.isEnabled {
                // Re-register (handles app being moved/updated)
                launchAtLogin.enable()
            }
        } else if settings.launchAtLoginEnabled && !launchAtLogin.isInApplicationsDirectory {
            // User wants it enabled but app is not in Applications - disable the preference
            settings.launchAtLoginEnabled = false
            if launchAtLogin.isEnabled {
                launchAtLogin.disable()
            }
        } else if !settings.launchAtLoginEnabled && launchAtLogin.isEnabled {
            // User doesn't want it but it's enabled - disable it
            launchAtLogin.disable()
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
