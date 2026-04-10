import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class for the Share Extension. Hosts the SwiftUI `ShareView`
/// and extracts attachments from the extension context.
@MainActor
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let items = extractAttachments()
        let shareView = ShareView(
            items: items,
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                let error = NSError(domain: "com.eviljuliette.clipkitty.share", code: 0)
                self?.extensionContext?.cancelRequest(withError: error)
            }
        )

        let hostingController = UIHostingController(rootView: shareView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)
    }

    private func extractAttachments() -> [NSItemProvider] {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }
        return extensionItems.compactMap(\.attachments).flatMap { $0 }
    }
}
