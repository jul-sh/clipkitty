import ClipKittyShared
import SwiftUI
import UIKit

/// Principal class of the ClipKitty keyboard extension. The keyboard has no
/// keys — it renders the recent-clips feed (from the App Group snapshot the
/// main app maintains; see `KeyboardFeedStore`) and inserts a clip's text at
/// the cursor when a card is tapped. Cards are also drag sources, so a clip
/// can be dropped anywhere in the host app.
final class KeyboardViewController: UIInputViewController {
    /// Taller than a bare QWERTY board (~216pt) so cards get room to show a
    /// useful excerpt, but shy of GIF-keyboard heights that feel like a modal.
    private static let keyboardHeight: CGFloat = 270

    private let model = KeyboardFeedModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(
            rootView: KeyboardRootView(
                model: model,
                insertText: { [weak self] text in
                    self?.textDocumentProxy.insertText(text)
                },
                inputModeSwitchTarget: self
            )
        )
        // Keep the system's keyboard backdrop visible behind the feed.
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        // High-but-not-required so the system can win during rotation and
        // floating-keyboard transitions instead of throwing constraint errors.
        let height = view.heightAnchor.constraint(equalToConstant: Self.keyboardHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // `needsInputModeSwitchKey` isn't reliable until the view is about to
        // appear, so the globe key is decided here, not in viewDidLoad.
        model.needsGlobeKey = needsInputModeSwitchKey
        model.reload(hasFullAccess: hasFullAccess)
    }
}

// MARK: - Model

/// Keyboard-side view state, derived from the snapshot on every appearance.
@MainActor
@Observable
final class KeyboardFeedModel {
    enum State {
        /// Full access is off, so the App Group container (and with it the
        /// snapshot) is unreachable.
        case needsFullAccess
        /// Setup is complete but there is nothing to show yet.
        case empty
        case ready([KeyboardFeedStore.Item])
    }

    private(set) var state: State = .empty
    var needsGlobeKey = false

    func reload(hasFullAccess: Bool) {
        guard hasFullAccess else {
            state = .needsFullAccess
            return
        }
        // Reaching this point proves the whole setup chain (keyboard enabled,
        // full access granted) works — record it so the app's activation flow
        // can show success.
        KeyboardFeedStore.recordKeyboardOpened()

        if let snapshot = KeyboardFeedStore.loadSnapshot(), !snapshot.items.isEmpty {
            state = .ready(snapshot.items)
        } else {
            state = .empty
        }
    }
}
