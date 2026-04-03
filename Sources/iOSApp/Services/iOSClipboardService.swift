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
            // Write accessible file URLs to the pasteboard. Files are stored
            // by path reference, not inline data. If the file no longer exists
            // at its recorded path (e.g. captured on another device), we fall
            // back to copying the filename as a string.
            let fileURLs: [URL] = files.compactMap { file in
                let url = URL(fileURLWithPath: file.path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return nil
                }
                return url
            }
            if !fileURLs.isEmpty {
                pasteboard.urls = fileURLs
            } else if let first = files.first {
                pasteboard.string = first.filename
            }
        }
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
