import AppKit
import SwiftUI

@MainActor
final class SnackbarWindow {
    private let coordinator: SnackbarCoordinator

    private var nudgeWindow: NSWindow?
    private var notification: ActiveNotification?

    /// Last known panel frame — used for positioning. Nil when panel is hidden.
    private var panelFrame: NSRect?

    private struct ActiveNotification {
        let window: NSWindow
        let anchoredToPanel: Bool
        var dismissTask: Task<Void, Never>?
        var action: (() -> Void)?
    }

    init(coordinator: SnackbarCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Nudge/Info (polling-based, panel-anchored only)

    func showIfNeeded(relativeTo panelFrame: NSRect) {
        self.panelFrame = panelFrame

        guard notification == nil else { return }

        let decision = coordinator.evaluate()
        switch decision {
        case let .show(item):
            showNudge(item: item, relativeTo: panelFrame)
        case .showNothing:
            dismissNudge()
        }
    }

    private func showNudge(item: SnackbarItem, relativeTo panelFrame: NSRect) {
        let view = SnackbarView(
            item: item,
            onAction: { [weak self] in
                self?.handleAction(item)
                self?.dismissNudge()
            },
            onDismiss: { [weak self] in
                self?.handleDismiss(item)
                self?.dismissNudge()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        if let existingWindow = nudgeWindow {
            existingWindow.contentView = hostingView
            positionRelativeToPanel(existingWindow, size: fittingSize, panelFrame: panelFrame)
            existingWindow.orderFront(nil)
            return
        }

        let window = makeWindow(hostingView: hostingView)
        positionRelativeToPanel(window, size: fittingSize, panelFrame: panelFrame)
        animateIn(window, slideUp: false)
        nudgeWindow = window
    }

    private func dismissNudge() {
        guard let nudgeWindow else { return }
        self.nudgeWindow = nil
        animateOut(nudgeWindow, slideUp: true)
    }

    // MARK: - Transient notifications (auto-dismiss, dual positioning)

    func showNotification(_ kind: NotificationKind, onAction: (() -> Void)? = nil) {
        if let existing = notification {
            existing.dismissTask?.cancel()
            existing.window.orderOut(nil)
            notification = nil
        }

        if nudgeWindow != nil { dismissNudge() }

        let item = SnackbarItem.notification(kind)

        let view = SnackbarView(
            item: item,
            onAction: { [weak self] in
                onAction?()
                self?.dismissNotification()
            },
            onDismiss: { [weak self] in
                self?.dismissNotification()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        let window = makeWindow(hostingView: hostingView)

        if case .actionable = kind {
            window.ignoresMouseEvents = false
        }

        let anchored = panelFrame != nil

        if let panelFrame {
            positionRelativeToPanel(window, size: fittingSize, panelFrame: panelFrame)
        } else {
            positionScreenCenter(window, size: fittingSize)
        }

        animateIn(window, slideUp: !anchored)

        notification = ActiveNotification(
            window: window,
            anchoredToPanel: anchored,
            dismissTask: scheduleDismiss(after: kind.duration),
            action: onAction
        )
    }

    func dismissNotification() {
        guard let active = notification else { return }
        active.dismissTask?.cancel()
        notification = nil
        animateOut(active.window, slideUp: active.anchoredToPanel)
    }

    private func scheduleDismiss(after duration: TimeInterval) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self.dismissNotification()
        }
    }

    // MARK: - Panel lifecycle

    func panelDidHide() {
        panelFrame = nil
        dismissNudge()
        if notification?.anchoredToPanel == true {
            dismissNotification()
        }
    }

    func hideAll() {
        dismissNudge()
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
