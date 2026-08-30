import SwiftUI
import UIKit

/// Computes the extra bottom inset occupied by a docked keyboard.
///
/// `UIKeyboardLayoutGuide` deliberately ties its top to the normal safe-area
/// bottom while a keyboard is floating, split, undocked, or offscreen (with
/// `followsUndockedKeyboard` left disabled). In those states this returns
/// zero; a docked keyboard produces the space between its top and the normal
/// safe-area bottom.
enum DockedKeyboardInsetCalculator {
    static func bottomInset(
        safeAreaMaxY: CGFloat,
        keyboardGuideMinY: CGFloat
    ) -> CGFloat {
        guard safeAreaMaxY.isFinite, keyboardGuideMinY.isFinite else { return 0 }
        return max(0, safeAreaMaxY - keyboardGuideMinY)
    }
}

private struct DockedKeyboardInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Space occupied below the current scene's normal safe area by a docked
    /// keyboard. It is always zero for floating, split, and undocked keyboards.
    var dockedKeyboardInset: CGFloat {
        get { self[DockedKeyboardInsetKey.self] }
        set { self[DockedKeyboardInsetKey.self] = newValue }
    }
}

extension View {
    /// Replaces SwiftUI's full-width keyboard safe-area adjustment with an
    /// inset derived from UIKit's docked-keyboard layout guide.
    ///
    /// This keeps bottom chrome above a normal docked keyboard without moving
    /// it into the middle of an iPad window when the keyboard floats.
    /// Views with bottom-anchored chrome consume `dockedKeyboardInset` to add
    /// their own docked-only offset.
    func avoidsOnlyDockedKeyboard() -> some View {
        modifier(DockedKeyboardAvoidanceModifier())
    }
}

private struct DockedKeyboardAvoidanceModifier: ViewModifier {
    @State private var dockedKeyboardInset: CGFloat = 0

    func body(content: Content) -> some View {
        let inset = $dockedKeyboardInset

        content
            // SwiftUI represents every keyboard as a full-width bottom safe
            // area. Use UIKit's guide below to add back only the docked case.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .environment(\.dockedKeyboardInset, dockedKeyboardInset)
            .background {
                DockedKeyboardGuideReader { newInset in
                    guard abs(inset.wrappedValue - newInset) > 0.5 else { return }
                    inset.wrappedValue = newInset
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

/// A full-size UIKit host is important here: the guide resolves keyboard
/// geometry in its owning view's coordinate space, correctly handling Split
/// View, Stage Manager, and external displays.
private struct DockedKeyboardGuideReader: UIViewControllerRepresentable {
    let onInsetChange: (CGFloat) -> Void

    func makeUIViewController(context _: Context) -> DockedKeyboardGuideViewController {
        DockedKeyboardGuideViewController(onInsetChange: onInsetChange)
    }

    func updateUIViewController(_ controller: DockedKeyboardGuideViewController, context _: Context) {
        controller.onInsetChange = onInsetChange
        controller.scheduleMeasurement()
    }
}

private final class DockedKeyboardGuideViewController: UIViewController {
    var onInsetChange: (CGFloat) -> Void

    private let guideMarker = UIView()
    private var keyboardObservers: [NSObjectProtocol] = []
    private var isMeasurementScheduled = false
    private var lastDeliveredInset: CGFloat?

    init(onInsetChange: @escaping (CGFloat) -> Void) {
        self.onInsetChange = onInsetChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let keyboardGuide = view.keyboardLayoutGuide
        // This is UIKit's default, but make the policy explicit: floating,
        // split, and undocked keyboards must resolve to the normal safe area.
        keyboardGuide.followsUndockedKeyboard = false
        keyboardGuide.usesBottomSafeArea = true

        // Moving this marker whenever the layout guide moves guarantees a
        // layout pass for dock/undock, keyboard-size, and rotation changes.
        guideMarker.translatesAutoresizingMaskIntoConstraints = false
        guideMarker.isUserInteractionEnabled = false
        view.addSubview(guideMarker)
        NSLayoutConstraint.activate([
            guideMarker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guideMarker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guideMarker.topAnchor.constraint(equalTo: keyboardGuide.topAnchor),
            guideMarker.heightAnchor.constraint(equalToConstant: 0),
        ])

        // The marker-driven layout pass is normally sufficient. These cover
        // a keyboard animation whose layout-guide update lands between parent
        // layout passes, while the measurement still comes from the guide—not
        // from an unreliable screen-coordinate keyboard frame.
        keyboardObservers = [
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleMeasurement()
            }
        }
    }

    deinit {
        for observer in keyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleMeasurement()
    }

    func scheduleMeasurement() {
        guard !isMeasurementScheduled else { return }
        isMeasurementScheduled = true

        // Layout can be running inside SwiftUI's update pass. Publishing on
        // the next main-loop turn both lets UIKit settle the guide and avoids
        // mutating @State during that pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMeasurementScheduled = false

            let inset = DockedKeyboardInsetCalculator.bottomInset(
                safeAreaMaxY: self.view.safeAreaLayoutGuide.layoutFrame.maxY,
                keyboardGuideMinY: self.view.keyboardLayoutGuide.layoutFrame.minY
            )
            guard self.lastDeliveredInset.map({ abs($0 - inset) > 0.5 }) ?? true else { return }

            self.lastDeliveredInset = inset
            self.onInsetChange(inset)
        }
    }
}
