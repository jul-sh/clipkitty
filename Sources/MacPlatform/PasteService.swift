import AppKit
import Foundation

@MainActor
public final class PasteService {
    private let pasteboard: PasteboardProtocol

    public init(pasteboard: PasteboardProtocol) {
        self.pasteboard = pasteboard
    }

    public func writeText(_ text: String) -> Int {
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    #if ENABLE_FILE_CLIPBOARD_ITEMS
        public func writeFiles(_ urls: [URL]) -> Int {
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
    #endif

    public func writeStaticImage(_ tiffData: Data) -> Int {
        pasteboard.clearContents()
        _ = pasteboard.setData(tiffData, forType: .tiff)
        return pasteboard.changeCount
    }

    public func writeAnimatedImage(gifData: Data, tiffFallback: Data?) -> Int {
        pasteboard.clearContents()
        _ = pasteboard.setData(gifData, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        if let tiffFallback {
            _ = pasteboard.setData(tiffFallback, forType: .tiff)
        }
        return pasteboard.changeCount
    }
}
