import AppKit
import SwiftUI

// MARK: - Right-Click Popover

struct RightClickPopoverOverlay: NSViewRepresentable {
    let actions: [BrowserActionItem]
    let onShow: () -> Void
    let onHide: () -> Void
    let onAction: (BrowserActionItem) -> Void
    let onConfirmDelete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.coordinator = context.coordinator
        context.coordinator.actions = actions
        context.coordinator.onShow = onShow
        context.coordinator.onHide = onHide
        context.coordinator.onAction = onAction
        context.coordinator.onConfirmDelete = onConfirmDelete
        return view
    }

    func updateNSView(_: RightClickView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.onShow = onShow
        context.coordinator.onHide = onHide
        context.coordinator.onAction = onAction
        context.coordinator.onConfirmDelete = onConfirmDelete
    }

    @MainActor
    final class Coordinator {
        var actions: [BrowserActionItem] = []
        var onShow: (() -> Void)?
        var onHide: (() -> Void)?
        var onAction: ((BrowserActionItem) -> Void)?
        var onConfirmDelete: (() -> Void)?
        private var activeMenuHandler: MenuActionHandler?

        deinit {
            activeMenuHandler = nil
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let handler = MenuActionHandler(
                onAction: { [weak self] action in
                    self?.onAction?(action)
                },
                onConfirmDelete: { [weak self] in
                    self?.onConfirmDelete?()
                }
            )
            activeMenuHandler = handler

            for (index, action) in actions.enumerated() {
                if index > 0, case .delete = action {
                    menu.addItem(.separator())
                }

                let item = NSMenuItem(
                    title: action.label,
                    action: #selector(MenuActionHandler.handleMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = handler
                item.representedObject = action
                item.image = NSImage(
                    systemSymbolName: action.systemImageName,
                    accessibilityDescription: action.label
                )
                menu.addItem(item)
            }

            return menu
        }
    }

    final class RightClickView: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard shouldHandleCurrentEvent else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                rightMouseDown(with: event)
                return
            }
            super.mouseDown(with: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let coordinator, !coordinator.actions.isEmpty else { return }

            coordinator.onShow?()
            let menu = coordinator.makeMenu()
            let clickPoint = convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: clickPoint, in: self)
            coordinator.onHide?()
        }

        override func menu(for _: NSEvent) -> NSMenu? {
            nil
        }

        private var shouldHandleCurrentEvent: Bool {
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return true
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }
    }

    @MainActor
    private final class MenuActionHandler: NSObject {
        let onAction: (BrowserActionItem) -> Void
        let onConfirmDelete: () -> Void

        init(onAction: @escaping (BrowserActionItem) -> Void, onConfirmDelete: @escaping () -> Void) {
            self.onAction = onAction
            self.onConfirmDelete = onConfirmDelete
        }

        @objc
        func handleMenuItem(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? BrowserActionItem else { return }
            if case .delete = action {
                onConfirmDelete()
            } else {
                onAction(action)
            }
        }
    }
}
