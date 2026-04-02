import AppKit
import Foundation

@MainActor
final class PasteService {
    private let pasteboard: PasteboardProtocol

    init(pasteboard: PasteboardProtocol) {
        self.pasteboard = pasteboard
    }

    func writeText(_ text: String) -> Int {
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func writeFiles(_ urls: [URL]) -> Int {
        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let allPaths = urls.map(\.path)
        _ = pasteboard.declareTypes([filenameType, .fileURL, .string], owner: nil)
        _ = pasteboard.setPropertyList(allPaths, forType: filenameType)
        if let first = urls.first {
            _ = pasteboard.setString(first.absoluteString, forType: .fileURL)
        }
        _ = pasteboard.setString(allPaths.joined(separator: "\n"), forType: .string)
        return pasteboard.changeCount
    }

    func writeStaticImage(_ tiffData: Data) -> Int {
        pasteboard.clearContents()
        _ = pasteboard.setData(tiffData, forType: .tiff)
        return pasteboard.changeCount
    }

    func writeAnimatedImage(gifData: Data, tiffFallback: Data?) -> Int {
        pasteboard.clearContents()
        _ = pasteboard.setData(gifData, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        if let tiffFallback {
            _ = pasteboard.setData(tiffFallback, forType: .tiff)
        }
        return pasteboard.changeCount
    }
}
