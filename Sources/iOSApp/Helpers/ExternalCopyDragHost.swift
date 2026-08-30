import SwiftUI
import UIKit

/// Hosts SwiftUI content in a UIKit view that owns a `UIDragInteraction`.
///
/// SwiftUI's iOS drag modifiers do not expose transfer completion. Hosting the
/// existing card content preserves its tap and context-menu gestures while the
/// UIKit delegate can observe `sessionDidTransferItems` without relying on
/// private SwiftUI view-hierarchy introspection.
@MainActor
struct ExternalCopyDragHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let makePayload: ExternalCopyDragInteractionDelegate.PayloadFactory
    let onExternalCopyTransferCompleted: ExternalCopyDragInteractionDelegate.Completion
    let accessibilityDragName: String?

    init(
        makePayload: @escaping ExternalCopyDragInteractionDelegate.PayloadFactory,
        onExternalCopyTransferCompleted: @escaping ExternalCopyDragInteractionDelegate.Completion,
        accessibilityDragName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.makePayload = makePayload
        self.onExternalCopyTransferCompleted = onExternalCopyTransferCompleted
        self.accessibilityDragName = accessibilityDragName
        self.content = content()
    }

    func makeCoordinator() -> ExternalCopyDragInteractionDelegate {
        ExternalCopyDragInteractionDelegate(
            makePayload: makePayload,
            onExternalCopyTransferCompleted: onExternalCopyTransferCompleted
        )
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        controller.sizingOptions = [.intrinsicContentSize]
        controller.view.addInteraction(context.coordinator.interaction)
        configureAccessibility(on: controller.view)
        return controller
    }

    func updateUIViewController(
        _ controller: UIHostingController<Content>,
        context: Context
    ) {
        context.coordinator.makePayload = makePayload
        context.coordinator.onExternalCopyTransferCompleted = onExternalCopyTransferCompleted
        controller.rootView = content
        configureAccessibility(on: controller.view)
    }

    private func configureAccessibility(on view: UIView) {
        // Keep SwiftUI's accessible card descendants visible; only attach the
        // drag location metadata to the UIKit view that owns the interaction.
        view.isAccessibilityElement = false
        if let accessibilityDragName, !accessibilityDragName.isEmpty {
            view.accessibilityDragSourceDescriptors = [
                UIAccessibilityLocationDescriptor(name: accessibilityDragName, view: view),
            ]
        } else {
            view.accessibilityDragSourceDescriptors = nil
        }
    }
}
