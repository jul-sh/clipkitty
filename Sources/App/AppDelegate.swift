import AppKit
import ServiceManagement
import SwiftUI
import GRDB
import ClipKittyCore

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

        // Screenshot mode: populate fresh database with test data
        let isScreenshotMode = CommandLine.arguments.contains("--screenshot-mode")
        if isScreenshotMode {
            populateTestDatabase()
        }

        enableLaunchAtLogin()

        store = ClipboardStore()
        if !isScreenshotMode {
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

        // Support --show-panel launch argument for CI/screenshots
        if CommandLine.arguments.contains("--show-panel") {
            panelController.keepOpen = true

            // Check for --search argument
            if let searchIndex = CommandLine.arguments.firstIndex(of: "--search"),
               searchIndex + 1 < CommandLine.arguments.count {
                panelController.initialSearchQuery = CommandLine.arguments[searchIndex + 1]
            }

            panelController.show()
        }
    }

    /// Populate database with test data for screenshots (uses same paths as ClipboardStore)
    private func populateTestDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let dbPath = appDir.appendingPathComponent("clipboard.sqlite").path

        // Remove existing database for clean state
        try? FileManager.default.removeItem(atPath: dbPath)

        do {
            let dbQueue = try DatabaseQueue(path: dbPath)

            try dbQueue.write { db in
                // Create tables (same schema as ClipboardStore)
                try db.create(table: "items", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("content", .text).notNull()
                    t.column("contentHash", .text).notNull()
                    t.column("timestamp", .datetime).notNull()
                    t.column("sourceApp", .text)
                    t.column("contentType", .text).defaults(to: "text")
                    t.column("imageData", .blob)
                    t.column("linkTitle", .text)
                    t.column("linkImageData", .blob)
                    t.column("sourceAppBundleID", .text)
                }

                try db.create(index: "idx_items_hash", on: "items", columns: ["contentHash"], ifNotExists: true)
                try db.create(index: "idx_items_timestamp", on: "items", columns: ["timestamp"], ifNotExists: true)

                // FTS table
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                        content, content=items, content_rowid=id, tokenize='trigram'
                    )
                """)

                // Triggers
                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
                        INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
                        INSERT INTO items_fts(items_fts, rowid, content) VALUES('delete', old.id, old.content);
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
                        INSERT INTO items_fts(items_fts, rowid, content) VALUES('delete', old.id, old.content);
                        INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
                    END
                """)

                // Insert test items
                let testItems: [(String, String, String)] = [
                    ("func fibonacci(_ n: Int) -> Int {\n    guard n > 1 else { return n }\n    return fibonacci(n - 1) + fibonacci(n - 2)\n}", "Xcode", "com.apple.dt.Xcode"),
                    ("SELECT users.name, orders.total\nFROM users\nJOIN orders ON users.id = orders.user_id\nWHERE orders.status = 'completed';", "TablePlus", "com.tinyapp.TablePlus"),
                    ("The quick brown fox jumps over the lazy dog", "Notes", "com.apple.Notes"),
                    ("https://github.com/anthropics/claude-code", "Safari", "com.apple.Safari"),
                    ("#!/bin/bash\nset -euo pipefail\necho \"Deploying to production...\"", "Terminal", "com.apple.Terminal"),
                    ("meeting@3pm re: Q4 planning", "Mail", "com.apple.mail"),
                    ("{ \"name\": \"ClipKitty\", \"version\": \"1.0.0\" }", "VS Code", "com.microsoft.VSCode"),
                    ("rgba(59, 130, 246, 0.5)", "Figma", "com.figma.Desktop"),
                    ("npm install --save-dev typescript @types/node", "Terminal", "com.apple.Terminal"),
                    ("Remember to update the API documentation", "Notion", "notion.id"),
                ]

                let now = Date()
                for (index, (content, sourceApp, bundleID)) in testItems.enumerated() {
                    let timestamp = now.addingTimeInterval(Double(-index * 300))
                    let item = ClipboardItem(text: content, sourceApp: sourceApp, sourceAppBundleID: bundleID, timestamp: timestamp)
                    try item.insert(db)
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

    private func enableLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            logError("Failed to enable launch at login: \(error)")
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

    func applicationWillTerminate(_ notification: Notification) {
        store.stopMonitoring()
        hotKeyManager.unregister()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
