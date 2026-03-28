import AppKit
import SwiftUI

@MainActor
final class SnackbarWindow {
    private var window: NSWindow?
    private let coordinator: SnackbarCoordinator

    // Notification state (transient, auto-dismissing)
    private var notificationWindow: NSWindow?
    private var notificationDismissTask: Task<Void, Never>?
    private var notificationAction: (() -> Void)?

    /// Last known panel frame — used for positioning. Nil when panel is hidden.
    private var panelFrame: NSRect?

    init(coordinator: SnackbarCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Nudge/Info snackbar (polling-based, panel-anchored only)

    func showIfNeeded(relativeTo panelFrame: NSRect) {
        self.panelFrame = panelFrame

        // Don't show nudge/info while a notification is active
        guard notificationWindow == nil else { return }

        let decision = coordinator.evaluate()
        switch decision {
        case let .show(item):
            show(item: item, relativeTo: panelFrame)
        case .showNothing:
            hideNudgeInfo()
        }
    }

    private func show(item: SnackbarItem, relativeTo panelFrame: NSRect) {
        let view = SnackbarView(
            item: item,
            onAction: { [weak self] in
                self?.handleAction(item)
                self?.hideNudgeInfo()
            },
            onDismiss: { [weak self] in
                self?.handleDismiss(item)
                self?.hideNudgeInfo()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        if let existingWindow = window {
            existingWindow.contentView = hostingView
            positionRelativeToPanel(existingWindow, size: fittingSize, panelFrame: panelFrame)
            existingWindow.orderFront(nil)
            return
        }

        let snackbarWindow = makeWindow(hostingView: hostingView)
        positionRelativeToPanel(snackbarWindow, size: fittingSize, panelFrame: panelFrame)
        animateIn(snackbarWindow, slideUp: false)
        window = snackbarWindow
    }

    private func hideNudgeInfo() {
        guard let window else { return }
        self.window = nil
        animateOut(window, slideUp: true)
    }

    // MARK: - Transient notifications (auto-dismiss, dual positioning)

    func showNotification(_ kind: NotificationKind, onAction: (() -> Void)? = nil) {
        // Dismiss any existing notification instantly
        if let existingWindow = notificationWindow {
            notificationDismissTask?.cancel()
            notificationDismissTask = nil
            notificationAction = nil
            notificationWindow = nil
            existingWindow.orderOut(nil)
        }

        // Hide nudge/info while notification is showing
        if window != nil { hideNudgeInfo() }

        let item = SnackbarItem.notification(kind)
        let actionHandler = onAction
        self.notificationAction = actionHandler

        let view = SnackbarView(
            item: item,
            onAction: { [weak self] in
                actionHandler?()
                self?.dismissNotification()
            },
            onDismiss: { [weak self] in
                self?.dismissNotification()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        let notifWindow = makeWindow(hostingView: hostingView)

        if case .actionable = kind {
            notifWindow.ignoresMouseEvents = false
        }

        if let panelFrame {
            positionRelativeToPanel(notifWindow, size: fittingSize, panelFrame: panelFrame)
        } else {
            positionScreenCenter(notifWindow, size: fittingSize)
        }

        notificationWindow = notifWindow

        if panelFrame != nil {
            animateIn(notifWindow, slideUp: false)
        } else {
            animateIn(notifWindow, slideUp: true)
        }

        scheduleNotificationDismiss(duration: kind.duration)
    }

    func dismissNotification() {
        notificationDismissTask?.cancel()
        notificationDismissTask = nil
        notificationAction = nil

        guard let notifWindow = notificationWindow else { return }
        notificationWindow = nil

        if panelFrame != nil {
            animateOut(notifWindow, slideUp: true)
        } else {
            animateOut(notifWindow, slideUp: false)
        }
    }

    private func scheduleNotificationDismiss(duration: TimeInterval) {
        notificationDismissTask?.cancel()
        notificationDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self.dismissNotification()
        }
    }

    // MARK: - Panel lifecycle

    func panelDidHide() {
        panelFrame = nil
        hideNudgeInfo()
    }

    func hide() {
        hideNudgeInfo()
        dismissNotification()
    }

    // MARK: - Positioning

    private func positionRelativeToPanel(_ window: NSWindow, size: NSSize, panelFrame: NSRect) {
        let x = panelFrame.minX
        let y = panelFrame.minY - size.height - 8
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func positionScreenCenter(_ window: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 80
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: - Window creation & animation

    private func makeWindow(hostingView: NSHostingView<some View>) -> NSWindow {
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.identifier = NSUserInterfaceItemIdentifier("SnackbarNotificationWindow")
        window.contentView = hostingView
        window.ignoresMouseEvents = true
        return window
    }

    private func animateIn(_ window: NSWindow, slideUp: Bool) {
        var startFrame = window.frame
        startFrame.origin.y += slideUp ? -20 : 10
        window.setFrame(startFrame, display: false)
        window.alphaValue = 0
        window.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var endFrame = window.frame
            endFrame.origin.y += slideUp ? 20 : -10
            window.animator().setFrame(endFrame, display: true)
            window.animator().alphaValue = 1
        }
    }

    private func animateOut(_ window: NSWindow, slideUp: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var endFrame = window.frame
            endFrame.origin.y += slideUp ? 10 : -20
            window.animator().setFrame(endFrame, display: true)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    // MARK: - Nudge/Info handlers

    private func handleAction(_ item: SnackbarItem) {
        switch item {
        case let .nudge(kind):
            coordinator.handleNudgeAction(kind)
        case .info:
            coordinator.handleInfoDismiss()
        case .notification:
            break
        }
    }

    private func handleDismiss(_ item: SnackbarItem) {
        switch item {
        case let .nudge(kind):
            coordinator.handleNudgeDismiss(kind)
        case .info:
            coordinator.handleInfoDismiss()
        case .notification:
            break
        }
    }
}
