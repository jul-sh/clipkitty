import AppKit
import SwiftUI

@MainActor
final class ToastWindow {
    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?
    private var messages: [String] = []
    private static let maxMessages = 3

    static let shared = ToastWindow()
    private init() {}

    func show(message: String) {
        // If at max capacity, reset and start fresh
        if messages.count >= Self.maxMessages {
            messages.removeAll()
            dismissTask?.cancel()
            window?.orderOut(nil)
            window = nil
        }

        // If window already exists, combine messages and extend timer
        if window != nil {
            // Skip duplicate messages
            guard !messages.contains(message) else { return }
            messages.append(message)

            // Extend dismiss timer based on combined message length
            dismissTask?.cancel()
            dismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(self.duration))
                guard !Task.isCancelled else { return }
                self.dismiss()
            }

            // Update window content with combined message
            updateWindowContent()
            return
        }

        // Start fresh with a new window
        messages = [message]

        // Create toast view
        let toastView = ToastView(message: combinedMessage)
        let hostingView = NSHostingView(rootView: toastView)

        // Let SwiftUI calculate intrinsic size
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Create window
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        // Use screenSaver level to appear above other apps even when we're not active
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = hostingView

        // Position: Center horizontally, near the bottom of the screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - fittingSize.width / 2
            let y = screenFrame.minY + 80
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.window = window
        window.identifier = NSUserInterfaceItemIdentifier("ToastWindow")
        window.orderFront(nil)

        // Schedule auto-dismiss based on message length
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(self.duration))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    /// Combines messages into a single string with " & " separator.
    /// Lowercases subsequent messages for natural reading (e.g., "Copied & saved as new item").
    private var combinedMessage: String {
        guard !messages.isEmpty else { return "" }
        if messages.count == 1 {
            return messages[0]
        }
        // First message stays as-is, subsequent messages are lowercased
        let first = messages[0]
        let rest = messages.dropFirst().map { $0.lowercased() }
        return ([first] + rest).joined(separator: " & ")
    }

    /// Duration based on message length: 2s base + 0.5s per 10 chars over 10, capped at 4.5s
    private var duration: TimeInterval {
        let length = combinedMessage.count
        let baseDuration = 2.0
        let extraChars = max(0, length - 10)
        let extraTime = Double(extraChars / 10) * 0.5
        return min(baseDuration + extraTime, 4.5)
    }

    private func updateWindowContent() {
        guard let window = window else { return }

        let toastView = ToastView(message: combinedMessage)
        let hostingView = NSHostingView(rootView: toastView)

        // Let SwiftUI calculate intrinsic size
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        window.contentView = hostingView

        // Resize window and re-center horizontally
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - fittingSize.width / 2
            let y = screenFrame.minY + 80
            window.setFrame(NSRect(x: x, y: y, width: fittingSize.width, height: fittingSize.height), display: true)
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        messages.removeAll()
        window?.orderOut(nil)
        window = nil
    }
}
