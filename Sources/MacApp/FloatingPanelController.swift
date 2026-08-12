import AppKit
import ClipKittyCore
import ClipKittyMacPlatform
import ClipKittyRust
import Combine
import SwiftUI

enum PanelMode {
    case production
    case testing
}

private struct PendingPaste {
    let id: UUID
    let itemId: String
    let content: ClipboardContent
    let targetApp: NSRunningApplication?
}

private struct PasteOperation {
    let id: UUID
    let task: Task<Void, Never>
}

private enum PanelDismissal {
    case previousApplication(previousApp: NSRunningApplication?)
    case appWindow
    case paste(PendingPaste)
    case appWindowCancellingPaste(PendingPaste)
}

private enum PanelState {
    case hidden
    case visible(previousApp: NSRunningApplication?)
    case dismissing(PanelDismissal)
    case preparingPaste(PasteOperation)
    case copyingPasteForAppWindow(PasteOperation)
}

private enum PanelDismissalDestination {
    case previousApplication
    case appWindow
    case focusLoss
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel!
    private let store: ClipboardStore
    private let mode: PanelMode
    private let activationService: AppActivationService
    private let pasteModeProvider: @MainActor () -> PasteMode
    private var panelState: PanelState = .hidden
    private var animatedLayer: CALayer? {
        panel.contentView?.layer
    }

    private let snackbarWindow: SnackbarWindow
    private let snackbarCoordinator: SnackbarCoordinator

    private var snackbarObservationTask: Task<Void, Never>?

    /// Debounce interval to prevent rapid toggle race conditions
    private var lastToggleTime: Date?
    private let toggleDebounceInterval: TimeInterval = 0.15

    /// Initial search query to pre-fill (for CI screenshots)
    var initialSearchQuery: String?

    // Exposes the actual AppKit window to hosted unit tests without making
    // panel lifecycle state externally mutable.
    #if DEBUG
        var panelForTesting: NSPanel {
            panel
        }

        var pastePreparationDidStartForTesting: (() -> Void)?
    #endif

    /// Whether an Accessibility-permission notice has been shown this launch.
    private var hasShownPermissionNotice = false

    /// Provides the window hosting the app's menu bar status item, if any.
    /// Injected by AppDelegate so resign-key handling can recognize clicks on
    /// the status item; see windowDidResignKey.
    var statusItemWindowProvider: () -> NSWindow? = { nil }

    /// Pending safety-net hide armed when a resign-key is attributed to a
    /// status item interaction; see scheduleStatusItemInteractionFallback.
    private var statusItemInteractionFallbackTask: Task<Void, Never>?

    private var textScaleCancellable: AnyCancellable?

    init(
        store: ClipboardStore,
        mode: PanelMode = .production,
        activationService: AppActivationService? = nil,
        snackbarCoordinator: SnackbarCoordinator? = nil,
        pasteModeProvider: @escaping @MainActor () -> PasteMode = { AppRuntimeState.shared.pasteMode }
    ) {
        self.store = store
        self.mode = mode
        self.activationService = activationService ?? AppActivationService()
        self.pasteModeProvider = pasteModeProvider
        let coordinator = snackbarCoordinator ?? SnackbarCoordinator()
        self.snackbarCoordinator = coordinator
        snackbarWindow = SnackbarWindow(coordinator: coordinator)
        super.init()

        coordinator.showNotification = { [weak self] request in
            self?.snackbarWindow.showNotification(request)
        }

        ErrorReporter.showNotification = { [weak self] request in
            self?.snackbarWindow.showNotification(request)
        }

        setupPanel()

        textScaleCancellable = AppRuntimeState.shared.$textScale
            .dropFirst()
            .sink { [weak self] _ in
                self?.handleTextScaleChange()
            }
    }

    private func handleTextScaleChange() {
        panel.setContentSize(Self.oversizedPanelSize)
        updatePanelContent()
        switch panelState {
        case .visible:
            centerPanel()
        case .hidden, .dismissing, .preparingPaste, .copyingPasteForAppWindow:
            break
        }
    }

    private func setupPanel() {
        // Testing mode differences:
        //
        // styleMask: Omit .nonactivatingPanel so XCUITest can discover the window.
        // NSPanel with .nonactivatingPanel is invisible to the accessibility hierarchy.
        // Safeguard: UI tests verify the panel is discoverable and interactive.
        //
        // windowLevel: Use a high custom level (2002) to ensure the panel appears above
        // other windows during test screenshots, since .floating level may not suffice
        // without .nonactivatingPanel.
        // Safeguard: UI tests verify panel visibility and z-ordering in screenshots.
        let styleMask: NSWindow.StyleMask
        let windowLevel: NSWindow.Level
        switch mode {
        case .production:
            styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
            windowLevel = .floating
        case .testing:
            styleMask = [.titled, .fullSizeContentView]
            windowLevel = NSWindow.Level(rawValue: 2002)
        }

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.oversizedPanelSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        // isFloatingPanel must match whether styleMask contains .nonactivatingPanel,
        // otherwise focus behaves incorrectly. Derived from styleMask to make this invariant unbreakable.
        panel.isFloatingPanel = styleMask.contains(.nonactivatingPanel)
        panel.level = windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = false

        updatePanelContent()
    }

    private func updatePanelContent() {
        let contentView = ContentView(
            store: store,
            onSelect: { [weak self] itemId, content in
                self?.selectItem(itemId: itemId, content: content)
            },
            onCopyOnly: { [weak self] itemId, content in
                self?.copyOnlyItem(itemId: itemId, content: content)
            },
            onDismiss: { [weak self] in
                self?.hide()
            },
            showSnackbarNotification: { [weak self] request in
                self?.snackbarWindow.showNotification(request)
            },
            dismissSnackbarNotification: { [weak self] in
                self?.snackbarWindow.dismissNotification()
            },
            initialSearchQuery: initialSearchQuery ?? ""
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        if let radius = systemWindowCornerRadius {
            hostingView.layer?.cornerRadius = radius
            hostingView.layer?.cornerCurve = .continuous
            hostingView.layer?.masksToBounds = true
        }

        // The window is oversized to give headroom for the scale-up animation.
        // Constrain the hosting view inset by the margin so content is centered.
        let container = NSView()
        container.wantsLayer = true
        container.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let m = Self.animationMargin
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: m),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -m),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor, constant: m),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -m),
        ])
        panel.contentView = container
    }

    nonisolated func windowDidResignKey(_: Notification) {
        MainActor.assumeIsolated {
            // shouldDismissOnResignKey: In production, panel hides when it loses focus
            // (user clicked elsewhere). In testing, panel must stay visible so XCUITest
            // can interact with it across multiple actions.
            // Safeguard: UI tests explicitly verify panel dismiss behavior via escape key.
            if case .production = mode {
                switch panelState {
                case .visible:
                    break
                case .hidden, .dismissing, .preparingPaste, .copyingPasteForAppWindow:
                    return
                }

                if isPointerOverStatusItem {
                    // Since the macOS 27 menu bar, pressing a status item of an
                    // accessory app deactivates it at mouse-down, before the
                    // button's action arrives at mouse-up. Hiding here would
                    // flip state to .hidden, so the click's toggle() re-shows
                    // the panel: a hide-show-hide flicker. Leave the transition
                    // to the status item's action; the fallback covers presses
                    // that never deliver one (e.g. dragging off the item).
                    scheduleStatusItemInteractionFallback()
                    return
                }
                hide(destination: .focusLoss)
            }
        }
    }

    /// Whether the mouse is currently over the status item's window. The
    /// causing event is no use for this attribution: the mouse-down resign
    /// arrives as an appKitDefined system event with no window.
    private var isPointerOverStatusItem: Bool {
        guard let statusWindow = statusItemWindowProvider() else { return false }
        return statusWindow.frame.contains(NSEvent.mouseLocation)
    }

    /// Hides the panel after a status-item-attributed resign-key if the
    /// interaction never toggled it: wait for the mouse button to be released,
    /// give the button action a beat to run, then hide unless a toggle already
    /// resolved the click (panel hidden) or the panel regained key.
    private func scheduleStatusItemInteractionFallback() {
        statusItemInteractionFallbackTask?.cancel()
        statusItemInteractionFallbackTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            if case .visible = panelState, !panel.isKeyWindow {
                hide()
            }
        }
    }

    func toggle() {
        // Debounce rapid toggles to prevent race conditions
        let now = Date()
        if let lastToggle = lastToggleTime,
           now.timeIntervalSince(lastToggle) < toggleDebounceInterval
        {
            return
        }
        lastToggleTime = now

        switch panelState {
        case .hidden:
            show()
        case .visible:
            hide()
        case .dismissing, .preparingPaste, .copyingPasteForAppWindow:
            break
        }
    }

    // MARK: - Animation

    private static let basePanelSize = NSSize(width: 778, height: 518)
    private static var panelSize: NSSize {
        let s = AppRuntimeState.shared.textScale
        var size = NSSize(width: basePanelSize.width * s, height: basePanelSize.height * s)
        if let screen = NSScreen.main?.visibleFrame {
            size.width = min(size.width, screen.width - 40)
            size.height = min(size.height, screen.height - 40)
        }
        return size
    }

    private static let animationScale: CGFloat = 1.05
    private static var animationMargin: CGFloat {
        ceil(max(panelSize.width, panelSize.height) * (animationScale - 1) / 2) + 2
    }

    private static var oversizedPanelSize: NSSize {
        let m = animationMargin * 2
        return NSSize(width: panelSize.width + m, height: panelSize.height + m)
    }

    private var scaledTransform: CATransform3D {
        let b = panel.contentView?.bounds ?? .zero
        let s = Self.animationScale
        let t = CGAffineTransform(translationX: b.midX, y: b.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -b.midX, y: -b.midY)
        return CATransform3DMakeAffineTransform(t)
    }

    func show() {
        guard case .hidden = panelState else { return }

        let previousApp = activationService.frontmostApplication()
        if initialSearchQuery != nil { updatePanelContent() }
        centerPanel()

        guard let layer = animatedLayer else { return }
        panel.alphaValue = 0
        layer.transform = scaledTransform
        panel.makeKeyAndOrderFront(nil)
        switch mode {
        case .production:
            // The nonactivating panel can take keyboard focus without bringing
            // ClipKitty forward or deactivating the app the user will paste into.
            break
        case .testing:
            // The test-only window is intentionally activatable so XCUITest can
            // discover and drive it through the accessibility hierarchy.
            NSApp.activate(ignoringOtherApps: true)
        }

        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = layer.transform
        spring.toValue = CATransform3DIdentity
        spring.mass = 1; spring.stiffness = 400; spring.damping = 30
        spring.duration = spring.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(0); fade.toValue = Float(1)
        fade.duration = 0.1
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in
            // Remove animations after they settle so CA doesn't walk the full
            // layer tree (200+ layers) on every frame during active use.
            layer?.removeAllAnimations()
        }
        layer.add(spring, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()

        layer.transform = CATransform3DIdentity
        panel.alphaValue = 1
        panelState = .visible(previousApp: previousApp)
        store.setPanelVisibility(true)

        let m = Self.animationMargin
        let contentFrame = panel.frame.insetBy(dx: m, dy: m)
        snackbarWindow.showIfNeeded(relativeTo: contentFrame)
        startSnackbarObservation()
    }

    private func startSnackbarObservation() {
        snackbarObservationTask?.cancel()
        snackbarObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, case .visible = self.panelState else { break }
                let m = Self.animationMargin
                let contentFrame = self.panel.frame.insetBy(dx: m, dy: m)
                self.snackbarWindow.showIfNeeded(relativeTo: contentFrame)
            }
        }
    }

    func hide() {
        hide(destination: .previousApplication)
    }

    func hideForAppWindow() {
        hide(destination: .appWindow)
    }

    private func hide(destination: PanelDismissalDestination) {
        switch panelState {
        case .hidden:
            break
        case let .visible(previousApp):
            switch destination {
            case .previousApplication:
                beginDismissal(.previousApplication(previousApp: previousApp))
            case .appWindow, .focusLoss:
                beginDismissal(.appWindow)
            }
        case let .dismissing(dismissal):
            switch (dismissal, destination) {
            case (.previousApplication, .appWindow):
                panelState = .dismissing(.appWindow)
            case (.previousApplication, .focusLoss):
                panelState = .dismissing(.appWindow)
            case let (.paste(pendingPaste), .appWindow):
                // An app window being opened has priority over an external-app
                // paste. Keep the clipboard write, but do not reactivate the old
                // target or synthesize Cmd-V after the app window takes focus.
                panelState = .dismissing(.appWindowCancellingPaste(pendingPaste))
            case (.previousApplication, .previousApplication),
                 (.appWindow, _),
                 (.paste, .previousApplication),
                 (.paste, .focusLoss),
                 (.appWindowCancellingPaste, _):
                break
            }
        case let .preparingPaste(operation):
            switch destination {
            case .previousApplication:
                break
            case .appWindow, .focusLoss:
                operation.task.cancel()
                panelState = .copyingPasteForAppWindow(operation)
            }
        case .copyingPasteForAppWindow:
            break
        }
    }

    private func beginDismissal(_ dismissal: PanelDismissal) {
        snackbarObservationTask?.cancel()
        snackbarObservationTask = nil
        snackbarWindow.panelDidHide()

        panelState = .dismissing(dismissal)

        guard let layer = animatedLayer else {
            completeDismissal(layer: nil)
            return
        }
        let easeIn = CAMediaTimingFunction(name: .easeIn)

        let scale = CABasicAnimation(keyPath: "transform")
        scale.toValue = scaledTransform
        scale.duration = 0.1; scale.timingFunction = easeIn
        scale.fillMode = .forwards; scale.isRemovedOnCompletion = false

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = Float(0)
        fade.duration = 0.08; fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.completeDismissal(layer: layer)
        }
        layer.add(scale, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    private func completeDismissal(layer: CALayer?) {
        guard case let .dismissing(dismissal) = panelState else { return }

        // orderOut is the focus-release boundary: when the panel is key, AppKit
        // makes the window behind it key before this call returns.
        panel.orderOut(nil)
        panel.alphaValue = 1
        layer?.removeAllAnimations()
        layer?.transform = CATransform3DIdentity
        layer?.opacity = 1
        store.resetForDisplay()
        store.setPanelVisibility(false)

        switch dismissal {
        case let .previousApplication(previousApp):
            panelState = .hidden
            activationService.activate(previousApp)
        case .appWindow:
            panelState = .hidden
        case let .paste(pendingPaste):
            activationService.activate(pendingPaste.targetApp)
            startPastePreparation(pendingPaste)
        case let .appWindowCancellingPaste(pendingPaste):
            startCopyingPasteForAppWindow(pendingPaste)
        }
    }

    private func centerPanel() {
        // Fallback to any available screen if main screen is unavailable
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame

        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2 + screenFrame.height * 0.1

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func selectItem(itemId: String, content: ClipboardContent) {
        #if ENABLE_SYNTHETIC_PASTE
            guard case let .visible(previousApp) = panelState else { return }
            beginDismissal(.paste(PendingPaste(
                id: UUID(),
                itemId: itemId,
                content: content,
                targetApp: previousApp
            )))
        #else
            hide()
            Task { @MainActor in
                guard await pasteReportingProgress(itemId: itemId, content: content) else { return }
                showCopiedNotification()
            }
        #endif
    }

    #if DEBUG
        func selectItemForTesting(itemId: String, content: ClipboardContent) {
            selectItem(itemId: itemId, content: content)
        }
    #endif

    #if ENABLE_SYNTHETIC_PASTE
        private func startPastePreparation(_ pendingPaste: PendingPaste) {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await prepareAndPaste(pendingPaste)
            }
            panelState = .preparingPaste(PasteOperation(id: pendingPaste.id, task: task))
        }

        private func prepareAndPaste(_ pendingPaste: PendingPaste) async {
            defer { finishPasteOperation(id: pendingPaste.id) }

            guard case let .preparingPaste(operation) = panelState,
                  operation.id == pendingPaste.id
            else {
                return
            }

            #if DEBUG
                pastePreparationDidStartForTesting?()
            #endif

            guard await pasteReportingProgress(
                itemId: pendingPaste.itemId,
                content: pendingPaste.content
            ) else {
                return
            }

            switch panelState {
            case let .preparingPaste(currentOperation)
                where currentOperation.id == pendingPaste.id && !Task.isCancelled:
                break
            case let .copyingPasteForAppWindow(currentOperation)
                where currentOperation.id == pendingPaste.id:
                showCopiedNotification()
                return
            case .hidden, .visible, .dismissing, .preparingPaste, .copyingPasteForAppWindow:
                return
            }

            let runtimeState = AppRuntimeState.shared
            runtimeState.accessibilityPermissionMonitor.refresh()
            switch pasteModeProvider() {
            case .autoPaste:
                switch activationService.syntheticPasteBehavior(for: pendingPaste.targetApp) {
                case let .paste(targetApp):
                    let didPaste = await activationService.simulatePaste(to: targetApp)
                    switch panelState {
                    case let .preparingPaste(currentOperation)
                        where currentOperation.id == pendingPaste.id && !Task.isCancelled:
                        if !didPaste {
                            showCopiedNotification()
                        }
                    case let .copyingPasteForAppWindow(currentOperation)
                        where currentOperation.id == pendingPaste.id:
                        // The clipboard was already written before activation
                        // polling. Settings now owns focus, so suppress Cmd-V.
                        showCopiedNotification()
                    case .hidden, .visible, .dismissing, .preparingPaste, .copyingPasteForAppWindow:
                        return
                    }
                case .copyOnly:
                    showCopiedNotification()
                }
            case .copyOnly:
                showCopiedNotification()
            case let .unavailable(reason):
                showCopiedWithPermissionNotice(reason)
            }
        }

        private func finishPasteOperation(id: UUID) {
            switch panelState {
            case let .preparingPaste(operation),
                 let .copyingPasteForAppWindow(operation):
                guard operation.id == id else { return }
                panelState = .hidden
            case .hidden, .visible, .dismissing:
                break
            }
        }

        private func startCopyingPasteForAppWindow(_ pendingPaste: PendingPaste) {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await copyPendingPaste(pendingPaste)
            }
            panelState = .copyingPasteForAppWindow(PasteOperation(
                id: pendingPaste.id,
                task: task
            ))
        }

        private func copyPendingPaste(_ pendingPaste: PendingPaste) async {
            defer { finishPasteOperation(id: pendingPaste.id) }
            guard case let .copyingPasteForAppWindow(operation) = panelState,
                  operation.id == pendingPaste.id
            else {
                return
            }

            guard await pasteReportingProgress(
                itemId: pendingPaste.itemId,
                content: pendingPaste.content
            ) else {
                return
            }
            guard case let .copyingPasteForAppWindow(currentOperation) = panelState,
                  currentOperation.id == pendingPaste.id
            else {
                return
            }
            showCopiedNotification()
        }
    #endif

    private func copyOnlyItem(itemId: String, content: ClipboardContent) {
        hide()
        Task { @MainActor in
            guard await pasteReportingProgress(itemId: itemId, content: content) else { return }
            showCopiedNotification()
        }
    }

    /// Writes the item to the pasteboard, surfacing a delayed progress snackbar
    /// for slow image conversions and an error snackbar on failure.
    private func pasteReportingProgress(itemId: String, content: ClipboardContent) async -> Bool {
        let progressTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            snackbarWindow.showProgress(.preparingPaste)
        }
        let ok = await store.paste(itemId: itemId, content: content)
        progressTask.cancel()
        snackbarWindow.dismissProgress()
        if !ok, !Task.isCancelled {
            snackbarWindow.showNotification(.passive(message: String(localized: "Couldn’t copy image"), iconSystemName: "exclamationmark.triangle.fill"))
        }
        return ok
    }

    /// Copy succeeded but synthetic paste is unavailable; explain how to restore
    /// it once per launch, then use the normal copied notification thereafter.
    private func showCopiedWithPermissionNotice(_ reason: AutomaticPasteUnavailableReason) {
        if hasShownPermissionNotice {
            showCopiedNotification()
            return
        }
        hasShownPermissionNotice = true

        let presentation: (message: String, actionTitle: String) = switch reason {
        case .permissionNotGranted:
            (
                String(localized: "Copied. Enable Accessibility to paste automatically"),
                String(localized: "Enable")
            )
        case .permissionRequiresRepair:
            (
                String(localized: "Copied. Repair Accessibility to paste automatically"),
                String(localized: "Repair")
            )
        }

        snackbarWindow.showNotification(
            .actionable(
                message: presentation.message,
                iconSystemName: "exclamationmark.triangle.fill",
                actionTitle: presentation.actionTitle,
                action: {
                    NotificationCenter.default.post(name: .clipKittyOpenSettings, object: nil)
                }
            )
        )
    }

    private func showCopiedNotification() {
        snackbarWindow.showNotification(.passive(
            message: String(localized: "Copied"),
            iconSystemName: "checkmark.circle.fill"
        ))
    }
}
