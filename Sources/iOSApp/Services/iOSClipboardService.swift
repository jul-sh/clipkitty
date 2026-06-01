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

enum ClipboardAccessVerification: Equatable {
    case granted
    case needsClipboardItem
    case needsSettingsChange
}

// MARK: - Clipboard Service

@MainActor
final class iOSClipboardService {
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
    }

    func readCurrentClipboard() -> PasteboardContent? {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let image = pasteboard.image {
            return .image(image)
        }
        if pasteboard.hasURLs, let url = pasteboard.url {
            return .link(url)
        }
        if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty {
            return .text(string)
        }
        return nil
    }

    func verifyAutoAddClipboardAccess() -> ClipboardAccessVerification {
        let pasteboard = UIPasteboard.general
        let hasSupportedContent = pasteboard.hasImages || pasteboard.hasURLs || pasteboard.hasStrings
        guard hasSupportedContent else { return .needsClipboardItem }

        if pasteboard.hasImages, pasteboard.image != nil {
            return .granted
        }
        if pasteboard.hasURLs, pasteboard.url != nil {
            return .granted
        }
        if pasteboard.hasStrings, pasteboard.string != nil {
            return .granted
        }
        return .needsSettingsChange
    }
}
