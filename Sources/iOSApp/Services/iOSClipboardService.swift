import ClipKittyRust
import Foundation
import UIKit
import UniformTypeIdentifiers

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

    func readCurrentClipboard() -> (type: String, content: Any)? {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image {
            return ("image", image)
        }
        if let url = pasteboard.url {
            return ("link", url)
        }
        if let string = pasteboard.string, !string.isEmpty {
            return ("text", string)
        }
        return nil
    }
}
