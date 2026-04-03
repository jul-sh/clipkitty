import ClipKittyRust
import UIKit

enum SharePresenter {
    /// Present a share sheet for the given item in the correct window scene.
    ///
    /// - Parameters:
    ///   - item: The clipboard item to share.
    ///   - windowScene: The scene to present in.
    ///   - sourceView: The view the popover arrow points to on iPad.
    ///   - sourceRect: The rect within `sourceView` to anchor the popover arrow.
    ///     Defaults to `sourceView.bounds` when nil.
    @MainActor
    static func present(
        item: ClipboardItem,
        in windowScene: UIWindowScene?,
        sourceView: UIView?,
        sourceRect: CGRect? = nil
    ) {
        let activityItems = shareItems(for: item)
        guard !activityItems.isEmpty else { return }
        presentActivitySheet(
            items: activityItems,
            in: windowScene,
            sourceView: sourceView,
            sourceRect: sourceRect
        )
    }

    /// Present a share sheet for a single file URL.
    @MainActor
    static func presentFile(
        url: URL,
        in windowScene: UIWindowScene?,
        sourceView: UIView?,
        sourceRect: CGRect? = nil
    ) {
        presentActivitySheet(
            items: [url],
            in: windowScene,
            sourceView: sourceView,
            sourceRect: sourceRect
        )
    }

    /// Returns `true` when the item has at least one shareable element.
    /// For file items this means at least one file still exists on disk.
    @MainActor
    static func canShare(item: ClipboardItem) -> Bool {
        return !shareItems(for: item).isEmpty
    }

    // MARK: - Private

    @MainActor
    private static func presentActivitySheet(
        items: [Any],
        in windowScene: UIWindowScene?,
        sourceView: UIView?,
        sourceRect: CGRect?
    ) {
        guard let scene = windowScene else { return }

        guard let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController
        else { return }

        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        // iPad requires popover configuration. Anchor to the provided sourceView
        // so the popover arrow points at the control that triggered it.
        if let popover = activityVC.popoverPresentationController {
            let anchor = sourceView ?? presenter.view!
            popover.sourceView = anchor
            popover.sourceRect = sourceRect ?? anchor.bounds
        }

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
        case let .file(_, files):
            // Resolve file paths to URLs for sharing. Files are stored by path
            // reference (and optional bookmark data), not inline data. If the
            // file no longer exists at its recorded path (e.g. it was captured
            // on another device), sharing is not possible for that entry.
            var urls: [URL] = []
            for file in files {
                let url = URL(fileURLWithPath: file.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    urls.append(url)
                }
            }
            return urls
        }
    }
}
