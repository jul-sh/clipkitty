import ClipKittyRust
import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Export Payload

/// Enum-driven export model. Every export path (copy, share, drag) pattern-matches
/// on this type instead of switching on `ClipboardContent` independently.
enum ClipboardExportPayload {
    case text(String)
    case color(String)
    case url(url: URL, fallbackText: String)
    case image(data: Data, contentType: UTType, isAnimated: Bool)
    case unsupported(reason: UnsupportedExportReason)
}

enum UnsupportedExportReason {
    case file
    case emptyImage
}

// MARK: - Conversion from ClipboardContent

extension ClipboardExportPayload {
    init(content: ClipboardContent) {
        switch content {
        case let .text(value):
            self = .text(value)

        case let .color(value):
            self = .color(value)

        case let .link(urlString, _):
            if let url = URL(string: urlString) {
                self = .url(url: url, fallbackText: urlString)
            } else {
                // Invalid URL string — export as plain text
                self = .text(urlString)
            }

        case let .image(data, _, isAnimated):
            if data.isEmpty {
                self = .unsupported(reason: .emptyImage)
            } else {
                let contentType = UTType.sniffImageType(from: data) ?? .png
                self = .image(data: data, contentType: contentType, isAnimated: isAnimated)
            }

        case .file:
            self = .unsupported(reason: .file)
        }
    }
}

// MARK: - Pasteboard Writing

extension ClipboardExportPayload {
    /// Write the payload to the system pasteboard.
    func writeToPasteboard(_ pasteboard: UIPasteboard = .general) {
        switch self {
        case let .text(value):
            pasteboard.string = value

        case let .color(value):
            pasteboard.string = value

        case let .url(url, _):
            pasteboard.url = url

        case let .image(data, _, _):
            if let image = UIImage(data: data) {
                pasteboard.image = image
            }

        case .unsupported:
            break
        }
    }
}

// MARK: - Share Items

extension ClipboardExportPayload {
    /// Activity items for UIActivityViewController.
    var shareItems: [Any] {
        switch self {
        case let .text(value):
            return [value]

        case let .color(value):
            return [value]

        case let .url(url, _):
            return [url]

        case let .image(data, _, _):
            if let uiImage = UIImage(data: data) {
                return [uiImage]
            }
            return []

        case .unsupported:
            return []
        }
    }
}

// MARK: - Drag NSItemProvider

extension ClipboardExportPayload {
    /// Create an `NSItemProvider` for drag-and-drop export.
    /// Returns `nil` for unsupported payloads.
    func makeItemProvider() -> NSItemProvider? {
        switch self {
        case let .text(value):
            let provider = NSItemProvider()
            provider.registerObject(value as NSString, visibility: .all)
            return provider

        case let .color(value):
            let provider = NSItemProvider()
            provider.registerObject(value as NSString, visibility: .all)
            return provider

        case let .url(url, fallbackText):
            let provider = NSItemProvider()
            provider.registerObject(url as NSURL, visibility: .all)
            // Also register plain text fallback for targets that don't accept URLs
            provider.registerDataRepresentation(for: .plainText, visibility: .all) { completion in
                completion(fallbackText.data(using: .utf8), nil)
                return nil
            }
            return provider

        case let .image(data, contentType, _):
            let provider = NSItemProvider()
            provider.registerDataRepresentation(for: contentType, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            return provider

        case .unsupported:
            return nil
        }
    }
}

// MARK: - UTType Sniffing

extension UTType {
    /// Detect image UTType from file magic bytes.
    static func sniffImageType(from data: Data) -> UTType? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        // PNG: 89 50 4E 47
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return .png
        }

        // JPEG: FF D8 FF
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return .jpeg
        }

        // GIF: GIF87a or GIF89a
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return .gif
        }

        // WebP: RIFF....WEBP
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50
        {
            return .webP
        }

        // TIFF: 49 49 2A 00 (little-endian) or 4D 4D 00 2A (big-endian)
        if (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)
        {
            return .tiff
        }

        // BMP: 42 4D
        if bytes[0] == 0x42, bytes[1] == 0x4D {
            return .bmp
        }

        return nil
    }
}
