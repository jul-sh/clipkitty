import AppKit
import SwiftUI

@MainActor
final class ToastWindow {
    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?

    static let shared = ToastWindow()
    private init() {}

    func show(message: String, duration: TimeInterval = 1.5) {
        // Cancel any existing toast
        dismissTask?.cancel()
        dismiss()

        // Create toast view
        let toastView = ToastView(message: message)
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

        // Schedule auto-dismiss
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
        window = nil
    }
}
