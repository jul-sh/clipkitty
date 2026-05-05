import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

enum ShortcutSavableContent: Sendable {
    case text(String)
    case image(data: Data, thumbnail: Data?, isAnimated: Bool)
}

enum ShortcutPasteboardRead: Sendable {
    case content(ShortcutSavableContent)
    case empty
    case unsupported(String)
}

@MainActor
enum ShortcutPasteboard {
    static func read() -> ShortcutPasteboardRead {
        #if os(macOS)
            readMacPasteboard()
        #elseif os(iOS)
            readIOSPasteboard()
        #else
            .unsupported("ClipKitty Shortcuts support is available on macOS and iOS.")
        #endif
    }

    #if os(macOS)
        private static func readMacPasteboard() -> ShortcutPasteboardRead {
            let pasteboard = NSPasteboard.general
            let availableTypes = Set(pasteboard.types ?? [])
            guard !availableTypes.isEmpty else { return .empty }

            let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
            if availableTypes.contains(gifType),
               let data = pasteboard.data(forType: gifType) {
                return .content(.image(
                    data: data,
                    thumbnail: ShortcutImageThumbnail.makeThumbnail(from: data),
                    isAnimated: true
                ))
            }

            for type in [NSPasteboard.PasteboardType.tiff, .png] where availableTypes.contains(type) {
                guard let data = pasteboard.data(forType: type) else { continue }
                return .content(.image(
                    data: data,
                    thumbnail: ShortcutImageThumbnail.makeThumbnail(from: data),
                    isAnimated: false
                ))
            }

            if availableTypes.contains(.string),
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                return .content(.text(text))
            }

            return .unsupported("The current clipboard item is not text or an image.")
        }
    #endif

    #if os(iOS)
        private static func readIOSPasteboard() -> ShortcutPasteboardRead {
            let pasteboard = UIPasteboard.general

            if let image = pasteboard.image,
               let data = image.pngData() {
                return .content(.image(
                    data: data,
                    thumbnail: ShortcutImageThumbnail.makeThumbnail(from: data),
                    isAnimated: false
                ))
            }

            if let url = pasteboard.url {
                return .content(.text(url.absoluteString))
            }

            if let text = pasteboard.string, !text.isEmpty {
                return .content(.text(text))
            }

            if pasteboard.hasImages || pasteboard.hasURLs || pasteboard.hasStrings {
                return .unsupported("The current clipboard item could not be read by ClipKitty.")
            }

            return .empty
        }
    #endif
}

private enum ShortcutImageThumbnail {
    static func makeThumbnail(from data: Data, maxDimension: Int = 200) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let scale = min(
            CGFloat(maxDimension) / CGFloat(image.width),
            CGFloat(maxDimension) / CGFloat(image.height),
            1.0
        )
        let targetWidth = max(1, Int(CGFloat(image.width) * scale))
        let targetHeight = max(1, Int(CGFloat(image.height) * scale))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let thumbnail = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        CGImageDestinationAddImage(destination, thumbnail, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
