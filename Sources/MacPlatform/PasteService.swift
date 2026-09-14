import AppKit
import Foundation

/// Outcome of a pasteboard write.
///
/// `changeCount` is always the post-write count, even when the write failed:
/// `clearContents()` has already bumped it, so the monitor must acknowledge it
/// or it would re-ingest the emptied pasteboard as a new clip.
public struct PasteboardWriteOutcome: Equatable, Sendable {
    public let changeCount: Int
    public let succeeded: Bool

    public init(changeCount: Int, succeeded: Bool) {
        self.changeCount = changeCount
        self.succeeded = succeeded
    }
}

@MainActor
public final class PasteService {
    /// Legacy Finder type; required for file paste alongside `.fileURL`.
    public static let legacyFileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    public static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")

    private let pasteboard: PasteboardProtocol

    public init(pasteboard: PasteboardProtocol) {
        self.pasteboard = pasteboard
    }

    public func writeText(_ text: String) -> PasteboardWriteOutcome {
        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        return PasteboardWriteOutcome(changeCount: pasteboard.changeCount, succeeded: ok)
    }

    #if ENABLE_FILE_CLIPBOARD_ITEMS
        public func writeFiles(_ urls: [URL]) -> PasteboardWriteOutcome {
            let filenameType = Self.legacyFileNamesType
            let allPaths = urls.map(\.path)
            _ = pasteboard.declareTypes([filenameType, .fileURL, .string], owner: nil)
            var ok = pasteboard.setPropertyList(allPaths, forType: filenameType)
            if let first = urls.first {
                ok = pasteboard.setString(first.absoluteString, forType: .fileURL) && ok
            }
            ok = pasteboard.setString(allPaths.joined(separator: "\n"), forType: .string) && ok
            return PasteboardWriteOutcome(changeCount: pasteboard.changeCount, succeeded: ok)
        }
    #endif

    public func writeStaticImage(_ tiffData: Data) -> PasteboardWriteOutcome {
        pasteboard.clearContents()
        let ok = pasteboard.setData(tiffData, forType: .tiff)
        return PasteboardWriteOutcome(changeCount: pasteboard.changeCount, succeeded: ok)
    }

    public func writeAnimatedImage(gifData: Data, tiffFallback: Data?) -> PasteboardWriteOutcome {
        pasteboard.clearContents()
        var ok = pasteboard.setData(gifData, forType: Self.gifType)
        if let tiffFallback {
            // The GIF is the payload; a failed TIFF fallback degrades
            // compatibility but the paste itself still succeeded.
            ok = pasteboard.setData(tiffFallback, forType: .tiff) || ok
        }
        return PasteboardWriteOutcome(changeCount: pasteboard.changeCount, succeeded: ok)
    }
}
