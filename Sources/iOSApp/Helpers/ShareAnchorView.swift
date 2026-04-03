import SwiftUI

/// A zero-size, invisible `UIViewRepresentable` that captures a `UIView`
/// reference so SwiftUI call sites can pass it to UIKit APIs that need a
/// source view (e.g. `UIActivityViewController` popover anchoring on iPad).
///
/// Usage:
/// ```swift
/// @State private var anchorView: UIView?
///
/// Button("Share") { … }
///     .background { ShareAnchorView { anchorView = $0 } }
/// ```
struct ShareAnchorView: UIViewRepresentable {
    let onCapture: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        onCapture(uiView)
    }
}
