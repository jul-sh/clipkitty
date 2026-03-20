import AppKit
import SwiftUI

@MainActor
final class SnackbarWindow {
    private var window: NSWindow?
    private let coordinator: SnackbarCoordinator

    init(coordinator: SnackbarCoordinator) {
        self.coordinator = coordinator
    }

    func showIfNeeded(relativeTo panelFrame: NSRect) {
        let decision = coordinator.evaluate()
        switch decision {
        case let .show(item):
            show(item: item, relativeTo: panelFrame)
        case .showNothing:
            break
        }
    }

    private func show(item: SnackbarItem, relativeTo panelFrame: NSRect) {
        let view = SnackbarView(
            item: item,
            onAction: { [weak self] in
                self?.handleAction(item)
                self?.hide()
            },
            onDismiss: { [weak self] in
                self?.handleDismiss(item)
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        if let existingWindow = window {
            existingWindow.contentView = hostingView
            positionWindow(existingWindow, size: fittingSize, relativeTo: panelFrame)
            existingWindow.orderFront(nil)
            return
        }

        let snackbarWindow = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        snackbarWindow.level = .floating
        snackbarWindow.backgroundColor = .clear
        snackbarWindow.isOpaque = false
        snackbarWindow.hasShadow = true
        snackbarWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        snackbarWindow.contentView = hostingView
        snackbarWindow.ignoresMouseEvents = false

        positionWindow(snackbarWindow, size: fittingSize, relativeTo: panelFrame)

        // Animate in
        snackbarWindow.alphaValue = 0
        var startFrame = snackbarWindow.frame
        startFrame.origin.y += 10
        snackbarWindow.setFrame(startFrame, display: false)
        snackbarWindow.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var endFrame = snackbarWindow.frame
            endFrame.origin.y -= 10
            snackbarWindow.animator().setFrame(endFrame, display: true)
            snackbarWindow.animator().alphaValue = 1
        }

        window = snackbarWindow
    }

    func hide() {
        guard let window else { return }
        self.window = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var endFrame = window.frame
            endFrame.origin.y += 10
            window.animator().setFrame(endFrame, display: true)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    private func positionWindow(_ window: NSWindow, size: NSSize, relativeTo panelFrame: NSRect) {
        let x = panelFrame.minX
        let y = panelFrame.minY - size.height - 8
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func handleAction(_ item: SnackbarItem) {
        switch item {
        case let .nudge(kind):
            coordinator.handleNudgeAction(kind)
        case .info:
            coordinator.handleInfoDismiss()
        }
    }

    private func handleDismiss(_ item: SnackbarItem) {
        switch item {
        case let .nudge(kind):
            coordinator.handleNudgeDismiss(kind)
        case .info:
            coordinator.handleInfoDismiss()
        }
    }
}
