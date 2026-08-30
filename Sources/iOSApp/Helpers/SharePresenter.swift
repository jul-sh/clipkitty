import ClipKittyRust
import UIKit

enum PreparedSharePayload: Equatable {
    case text(String)
    case url(URL)
    case image(PreparedNativeImage)
}

enum SharePresenter {
    /// Converts one stored item into a bounded activity payload. Image parsing
    /// and the decode probe are delegated to `PasteboardItemEncoder`, whose
    /// cancellable detached worker preserves the original native bytes and UTI.
    static func prepare(item: ClipboardItem) async -> PreparedSharePayload? {
        guard !Task.isCancelled else { return nil }

        switch item.content {
        case let .text(value), let .color(value):
            guard value.utf8.count <= iOSTransferLimits.maximumTextByteCount else {
                return nil
            }
            return .text(value)

        case let .link(value, _):
            guard value.utf8.count <= iOSTransferLimits.maximumTextByteCount else {
                return nil
            }
            if let url = URL(string: value), url.scheme != nil {
                return .url(url)
            }
            return .text(value)

        case .image:
            guard let prepared = await PasteboardItemEncoder.prepareAll([item.content]),
                  !Task.isCancelled,
                  let nativeImage = prepared.singleNativeImage
            else { return nil }
            return .image(nativeImage)

        case .file:
            return nil
        }
    }

    @MainActor
    static func present(payload: PreparedSharePayload) {
        let activityItems = activityItems(for: payload)
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

    @MainActor
    static func activityItems(for payload: PreparedSharePayload) -> [Any] {
        switch payload {
        case let .text(value):
            return [value]
        case let .url(url):
            return [url]
        case let .image(image):
            return [NativeImageActivityItemSource(image: image)]
        }
    }
}

/// Supplies original image bytes together with their concrete ImageIO UTI.
/// `UIActivityItemSource` lets the activity controller request its preferred
/// representation without ClipKitty constructing a `UIImage` or flattening an
/// animated format on the main actor.
private final class NativeImageActivityItemSource: NSObject, UIActivityItemSource {
    private let image: PreparedNativeImage

    init(image: PreparedNativeImage) {
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        image.data
    }

    func activityViewController(
        _: UIActivityViewController,
        itemForActivityType _: UIActivity.ActivityType?
    ) -> Any? {
        image.data
    }

    func activityViewController(
        _: UIActivityViewController,
        dataTypeIdentifierForActivityType _: UIActivity.ActivityType?
    ) -> String {
        image.typeIdentifier
    }
}
