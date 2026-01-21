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

            // Check for --take-screenshot argument (renders at 2x and exits)
            if let screenshotIndex = CommandLine.arguments.firstIndex(of: "--take-screenshot"),
               screenshotIndex + 1 < CommandLine.arguments.count {
                let outputPath = CommandLine.arguments[screenshotIndex + 1]
                takeScreenshot(to: outputPath)
                return
            }

            panelController.show()
        }
    }

    /// Render the ContentView at 2x scale to a PNG file and exit
    private var screenshotWindow: NSWindow?

    private func takeScreenshot(to outputPath: String) {
        let scaleFactor: CGFloat = 2.0
        let viewSize = NSSize(width: 778, height: 518)  // Same as panel size

        let contentView = ContentView(
            store: store,
            onSelect: { _ in },
            onDismiss: { },
            initialSearchQuery: panelController.initialSearchQuery ?? ""
        )

        // Create an offscreen window - SwiftUI needs a window to render properly
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: viewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: contentView)
        window.backgroundColor = .clear
        window.isOpaque = false

        // Position offscreen but make it "visible" to trigger SwiftUI rendering
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)

        self.screenshotWindow = window  // Keep reference

        // Wait for SwiftUI to fully render
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.renderWindowToFile(window, scale: scaleFactor, outputPath: outputPath)
            NSApp.terminate(nil)
        }
    }

    private func renderWindowToFile(_ window: NSWindow, scale: CGFloat, outputPath: String) {
        guard let contentView = window.contentView else {
            logError("No content view in window")
            return
        }

        let size = contentView.bounds.size
        let pixelSize = NSSize(width: size.width * scale, height: size.height * scale)

        // Use bitmapImageRepForCachingDisplay which properly captures the rendered view
        guard let bitmapRep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            logError("Failed to create bitmap representation")
            return
        }

        // Capture the display into the bitmap
        contentView.cacheDisplay(in: contentView.bounds, to: bitmapRep)

        // For 2x scale, upscale with high quality interpolation
        // Note: True native 2x would require the window to be on a Retina display
        // This approach produces good quality upscaled output for CI environments
        guard let scaledBitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            logError("Failed to create scaled bitmap")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: scaledBitmapRep) else {
            logError("Failed to create graphics context")
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let sourceImage = NSImage(size: size)
        sourceImage.addRepresentation(bitmapRep)
        sourceImage.draw(in: NSRect(origin: .zero, size: pixelSize),
                         from: NSRect(origin: .zero, size: size),
                         operation: .copy,
                         fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        // Save as PNG
        guard let pngData = scaledBitmapRep.representation(using: .png, properties: [:]) else {
            logError("Failed to create PNG data")
            return
        }

        do {
            try pngData.write(to: URL(fileURLWithPath: outputPath))
            logInfo("Screenshot saved to: \(outputPath) (\(Int(pixelSize.width))x\(Int(pixelSize.height)))")
        } catch {
            logError("Failed to save screenshot: \(error)")
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

            // Insert test items (only built-in macOS apps)
            let testItems: [(String, String, String)] = [
                ("func fibonacci(_ n: Int) -> Int {\n    guard n > 1 else { return n }\n    return fibonacci(n - 1) + fibonacci(n - 2)\n}", "Terminal", "com.apple.Terminal"),
                ("SELECT users.name, orders.total\nFROM users\nJOIN orders ON users.id = orders.user_id\nWHERE orders.status = 'completed';", "Terminal", "com.apple.Terminal"),
                ("The quick brown fox jumps over the lazy dog", "Mail", "com.apple.mail"),
                ("https://github.com/anthropics/claude-code", "Safari", "com.apple.Safari"),
                ("#!/bin/bash\nset -euo pipefail\necho \"Deploying to production...\"", "Terminal", "com.apple.Terminal"),
                ("meeting@3pm re: Q4 planning", "Mail", "com.apple.mail"),
                ("{ \"name\": \"ClipKitty\", \"version\": \"1.0.0\" }", "Terminal", "com.apple.Terminal"),
                ("https://developer.apple.com/documentation/swiftui", "Safari", "com.apple.Safari"),
                ("npm install --save-dev typescript @types/node", "Terminal", "com.apple.Terminal"),
                ("Remember to update the API documentation", "Mail", "com.apple.mail"),
            ]

            // Insert items in reverse order (oldest first) so most recent is at the top
            for (index, (content, sourceApp, bundleID)) in testItems.enumerated().reversed() {
                // Add a small delay between inserts to ensure different timestamps
                _ = try rustStore.saveText(text: content, sourceApp: sourceApp, sourceAppBundleId: bundleID)
                // Sleep a tiny bit to space out timestamps
                if index > 0 {
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
