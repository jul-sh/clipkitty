import AppKit
import ClipKittyRust
import SwiftUI

enum PanelMode {
    case production
    case testing
}

private enum PanelState: Equatable {
    case hidden
    case visible(previousApp: NSRunningApplication?)

    /// The previous app captured when showing, if any
    var previousApp: NSRunningApplication? {
        switch self {
        case .hidden: return nil
        case let .visible(app): return app
        }
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel!
    private let store: ClipboardStore
    private let mode: PanelMode
    private let activationService: AppActivationService
    private var panelState: PanelState = .hidden
    private var animatedLayer: CALayer? { panel.contentView?.layer }

    /// Debounce interval to prevent rapid toggle race conditions
    private var lastToggleTime: Date?
    private let toggleDebounceInterval: TimeInterval = 0.15

    /// Initial search query to pre-fill (for CI screenshots)
    var initialSearchQuery: String?

    init(
        store: ClipboardStore,
        mode: PanelMode = .production,
        activationService: AppActivationService? = nil
    ) {
        self.store = store
        self.mode = mode
        self.activationService = activationService ?? AppActivationService()
        super.init()
        setupPanel()
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
        }
    }

    // MARK: - Animation

    private static let panelSize = NSSize(width: 778, height: 518)
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
        store.resetForDisplay()
        if initialSearchQuery != nil { updatePanelContent() }
        centerPanel()

        guard let layer = animatedLayer else { return }
        panel.alphaValue = 0
        layer.transform = scaledTransform
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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
        layer.add(spring, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()

        layer.transform = CATransform3DIdentity
        panel.alphaValue = 1
        panelState = .visible(previousApp: previousApp)
    }

    @discardableResult
    func hide() -> NSRunningApplication? {
        let previousApp: NSRunningApplication?
        switch panelState {
        case .hidden: return nil
        case let .visible(app): previousApp = app
        }

        guard let layer = animatedLayer else { return previousApp }
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
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            layer.removeAllAnimations()
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            self.store.resetForDisplay()
        }
        layer.add(scale, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()

        panelState = .hidden
        activationService.activate(previousApp)
        return previousApp
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

    private func selectItem(itemId: Int64, content: ClipboardContent) {
        store.paste(itemId: itemId, content: content)
        #if !APP_STORE
            let targetApp = hide()
            if case .autoPaste = AppSettings.shared.pasteMode {
                activationService.simulatePaste(to: targetApp)
            } else {
                // Show toast when copying without auto-paste
                ToastWindow.shared.show(message: String(localized: "Copied"))
            }
        #else
            hide()
            ToastWindow.shared.show(message: String(localized: "Copied"))
        #endif
    }

    private func copyOnlyItem(itemId: Int64, content: ClipboardContent) {
        store.paste(itemId: itemId, content: content)
        hide()
        ToastWindow.shared.show(message: String(localized: "Copied"))
    }
}
