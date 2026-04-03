import SwiftUI
import UIKit

/// Environment key that provides the current `UIWindowScene` to SwiftUI views.
private struct WindowSceneKey: EnvironmentKey {
    static let defaultValue: UIWindowScene? = nil
}

extension EnvironmentValues {
    var windowScene: UIWindowScene? {
        get { self[WindowSceneKey.self] }
        set { self[WindowSceneKey.self] = newValue }
    }
}

/// A UIKit-backed view that captures the current window scene and injects it
/// into the SwiftUI environment.
struct WindowSceneReader<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var windowScene: UIWindowScene?

    var body: some View {
        content
            .environment(\.windowScene, windowScene)
            .background(WindowSceneCapture(windowScene: $windowScene))
    }
}

private struct WindowSceneCapture: UIViewRepresentable {
    @Binding var windowScene: UIWindowScene?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let scene = uiView.window?.windowScene {
                windowScene = scene
            }
        }
    }
}
