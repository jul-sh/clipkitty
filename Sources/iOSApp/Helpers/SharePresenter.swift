import ClipKittyRust
import UIKit

enum SharePresenter {
    @MainActor
    static func present(item: ClipboardItem) {
        let activityItems = shareItems(for: item)
        guard !activityItems.isEmpty else { return }

        let activityVC = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let rootVC = windowScene.windows.first?.rootViewController
        else { return }

        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        activityVC.popoverPresentationController?.sourceView = presenter.view
        presenter.present(activityVC, animated: true)
    }

    private static func shareItems(for item: ClipboardItem) -> [Any] {
        switch item.content {
        case let .text(value):
            return [value]
        case let .link(url, _):
            if let linkURL = URL(string: url) {
                return [linkURL]
            }
            return [url]
        case let .image(data, _, _):
            if let uiImage = UIImage(data: data) {
                return [uiImage]
            }
            return []
        case let .color(value):
            return [value]
        case .file:
            return []
        }
    }
}
