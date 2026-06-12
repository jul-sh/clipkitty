import ClipKittyRust
import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Clipboard Reading Result

enum PasteboardContent {
    case image(UIImage)
    case link(URL)
    case text(String)
}

// MARK: - Clipboard Service

@MainActor
final class iOSClipboardService {
    private let settings: iOSSettingsStore

    init(settings: iOSSettingsStore) {
        self.settings = settings
    }

    /// The current pasteboard generation. Reading `changeCount` never triggers
    /// the system paste-consent alert, unlike reading the pasteboard contents.
    var pasteboardChangeCount: Int { UIPasteboard.general.changeCount }

    func copy(content: ClipboardContent) {
        let pasteboard = UIPasteboard.general
        switch content {
        case let .text(value):
            pasteboard.string = value
        case let .color(value):
            pasteboard.string = value
        case let .link(url, _):
            if let url = URL(string: url) {
                pasteboard.url = url
            } else {
                pasteboard.string = url
            }
        case let .image(data, _, _):
            if let image = UIImage(data: data) {
                pasteboard.image = image
            }
        case let .file(_, files):
            if let first = files.first {
                pasteboard.string = first.filename
            }
        }
        // Record our own write as already-ingested so auto-add never re-reads
        // it back on the next foreground (mirrors the Mac acknowledgeLocalWrite).
        settings.lastIngestedPasteboardChangeCount = pasteboard.changeCount
    }

    func readCurrentClipboard() -> PasteboardContent? {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image {
            return .image(image)
        }
        if let url = pasteboard.url {
            return .link(url)
        }
        if let string = pasteboard.string, !string.isEmpty {
            return .text(string)
        }
        return nil
    }
}
