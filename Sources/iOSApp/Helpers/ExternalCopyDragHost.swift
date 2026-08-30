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

    init(
        makePayload: @escaping ExternalCopyDragInteractionDelegate.PayloadFactory,
        onExternalCopyTransferCompleted: @escaping ExternalCopyDragInteractionDelegate.Completion,
        @ViewBuilder content: () -> Content
    ) {
        self.makePayload = makePayload
        self.onExternalCopyTransferCompleted = onExternalCopyTransferCompleted
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
        return controller
    }

    func updateUIViewController(
        _ controller: UIHostingController<Content>,
        context: Context
    ) {
        context.coordinator.makePayload = makePayload
        context.coordinator.onExternalCopyTransferCompleted = onExternalCopyTransferCompleted
        controller.rootView = content
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController controller: UIHostingController<Content>,
        context _: Context
    ) -> CGSize? {
        // UIViewControllerRepresentable does not automatically forward the
        // hosted SwiftUI view's ideal height. Without this bridge the UIKit
        // ancestor is laid out at zero height even though its SwiftUI child
        // still draws outside those bounds, leaving a visible card that
        // cannot receive taps, context menus, or drags.
        let constraint = CGSize(
            width: proposal.width ?? .greatestFiniteMagnitude,
            height: proposal.height ?? .greatestFiniteMagnitude
        )
        let fitted = controller.sizeThatFits(in: constraint)
        guard fitted.width.isFinite,
              fitted.height.isFinite,
              fitted.width >= 0,
              fitted.height >= 0
        else {
            return nil
        }
        return CGSize(
            width: proposal.width ?? fitted.width,
            height: proposal.height ?? fitted.height
        )
    }
}
