import AppKit
import SwiftUI

@MainActor
final class ToastWindow {
    private enum ToastState {
        case idle
        case passive(messages: [String], iconSystemName: String, iconColor: NSColor)
        case actionable(message: String, iconSystemName: String, iconColor: NSColor, actionTitle: String, action: () -> Void)
    }

    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?
    private static let maxMessages = 3
    private var state: ToastState = .idle

    static let shared = ToastWindow()
    private init() {}

    func show(message: String) {
        show(
            message: message,
            iconSystemName: "checkmark.circle.fill",
            iconColor: .systemGreen,
            actionTitle: nil,
            action: nil
        )
    }

    func show(
        message: String,
        iconSystemName: String = "checkmark.circle.fill",
        iconColor: NSColor = .systemGreen,
        actionTitle: String?,
        action: (() -> Void)?
    ) {
        if let actionTitle, let action {
            state = .actionable(
                message: message,
                iconSystemName: iconSystemName,
                iconColor: iconColor,
                actionTitle: actionTitle,
                action: action
            )
            dismissTask?.cancel()
            presentToast()
            scheduleDismiss()
            return
        }

        // If at max capacity, reset and start fresh
        if case .passive(let messages, _, _) = state, messages.count >= Self.maxMessages {
            state = .idle
            dismissTask?.cancel()
            window?.orderOut(nil)
            window = nil
        }

        // If window already exists, combine messages and extend timer
        if window != nil, case .passive(let existingMessages, let existingIconSystemName, let existingIconColor) = state {
            // Skip duplicate messages
            guard !existingMessages.contains(message) else { return }
            state = .passive(
                messages: existingMessages + [message],
                iconSystemName: existingIconSystemName,
                iconColor: existingIconColor
            )

            scheduleDismiss()
            presentToast()
            return
        }

        // Start fresh with a new window
        state = .passive(
            messages: [message],
            iconSystemName: iconSystemName,
            iconColor: iconColor
        )
        presentToast()
        scheduleDismiss()
    }

    /// Combines messages into a single string with " & " separator.
    /// Lowercases subsequent messages for natural reading (e.g., "Copied & saved as new item").
    private var combinedMessage: String {
        switch state {
        case .idle:
            return ""
        case .passive(let messages, _, _):
            guard !messages.isEmpty else { return "" }
            if messages.count == 1 {
                return messages[0]
            }
            let first = messages[0]
            let rest = messages.dropFirst().map { $0.lowercased() }
            return ([first] + rest).joined(separator: " & ")
        case .actionable(let message, _, _, _, _):
            return message
        }
    }

    /// Duration based on message length: 2s base + 0.5s per 10 chars over 10, capped at 4.5s
    private var duration: TimeInterval {
        if case .actionable = state {
            return 4.0
        }
        let length = combinedMessage.count
        let baseDuration = 2.0
        let extraChars = max(0, length - 10)
        let extraTime = Double(extraChars / 10) * 0.5
        return min(baseDuration + extraTime, 4.5)
    }

    private func presentToast() {
        let toastView = currentToastView()
        let hostingView = NSHostingView(rootView: toastView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        let toastWindow: NSWindow
        if let existingWindow = self.window {
            toastWindow = existingWindow
            toastWindow.contentView = hostingView
        } else {
            let newWindow = NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            newWindow.level = .screenSaver
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true
            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            newWindow.identifier = NSUserInterfaceItemIdentifier("ToastWindow")
            newWindow.contentView = hostingView
            self.window = newWindow
            toastWindow = newWindow
        }

        switch state {
        case .actionable:
            toastWindow.ignoresMouseEvents = false
        case .idle, .passive:
            toastWindow.ignoresMouseEvents = true
        }

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - fittingSize.width / 2
            let y = screenFrame.minY + 80
            toastWindow.setFrame(NSRect(x: x, y: y, width: fittingSize.width, height: fittingSize.height), display: true)
        }

        // Animate in: fade + slide up
        let isNewWindow = toastWindow.alphaValue == 0 || !toastWindow.isVisible
        if isNewWindow {
            var startFrame = toastWindow.frame
            startFrame.origin.y -= 20
            toastWindow.setFrame(startFrame, display: false)
            toastWindow.alphaValue = 0
        }

        toastWindow.orderFront(nil)

        if isNewWindow {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                var endFrame = toastWindow.frame
                endFrame.origin.y += 20
                toastWindow.animator().setFrame(endFrame, display: true)
                toastWindow.animator().alphaValue = 1
            }
        }
    }

    private func currentToastView() -> ToastView {
        switch state {
        case .idle, .passive:
            let iconSystemName: String
            let iconColor: Color
            switch state {
            case .passive(_, let stateIconSystemName, let stateIconColor):
                iconSystemName = stateIconSystemName
                iconColor = Color(nsColor: stateIconColor)
            case .idle:
                iconSystemName = "checkmark.circle.fill"
                iconColor = .green
            case .actionable:
                fatalError("Unreachable")
            }
            return ToastView(
                message: combinedMessage,
                iconSystemName: iconSystemName,
                iconColor: iconColor,
                actionTitle: nil,
                action: nil
            )
        case .actionable(let message, let iconSystemName, let iconColor, let actionTitle, let action):
            return ToastView(
                message: message,
                iconSystemName: iconSystemName,
                iconColor: Color(nsColor: iconColor),
                actionTitle: actionTitle
            ) {
                action()
                self.dismiss()
            }
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(self.duration))
            guard !Task.isCancelled else { return }
            guard self.window != nil else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        state = .idle

        guard let window = self.window else { return }
        self.window = nil

        // Animate out: fade + slide down
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var endFrame = window.frame
            endFrame.origin.y -= 20
            window.animator().setFrame(endFrame, display: true)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }
}
