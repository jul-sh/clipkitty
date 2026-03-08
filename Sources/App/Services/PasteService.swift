import AppKit
import ClipKittyRust
import UniformTypeIdentifiers

// MARK: - Paste Result

enum PasteResult: Sendable {
    case success
    case noContent
    case bookmarkResolutionFailed
    case conversionFailed
}

// MARK: - Paste Service

/// Service for paste operations including format conversion.
///
/// NOTE: This is the target architecture for service extraction.
/// Currently the ClipboardStore.swift contains this logic inline.
/// This file serves as documentation of the intended boundary.
enum PasteService {

    // MARK: - Copy to Pasteboard

    @MainActor
    static func copyToPasteboard(_ item: ClipboardItem, pasteboard: NSPasteboard = .general) -> PasteResult {
        pasteboard.clearContents()

        switch item.content {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
            return .success

        case .color(let value):
            pasteboard.setString(value, forType: .string)
            return .success

        case .link(let url, _):
            pasteboard.setString(url, forType: .string)
            if let nsUrl = URL(string: url) {
                pasteboard.setString(url, forType: .URL)
                pasteboard.writeObjects([nsUrl as NSURL])
            }
            return .success

        case .image(let data, _, let isAnimated):
            return copyImageToPasteboard(imageData: data, isAnimated: isAnimated, pasteboard: pasteboard)

        case .file(_, let files):
            return copyFilesToPasteboard(files: files, pasteboard: pasteboard)
        }
    }

    // MARK: - Image Handling

    private static func copyImageToPasteboard(imageData: Data, isAnimated: Bool, pasteboard: NSPasteboard) -> PasteResult {
        // For animated images, convert HEICS back to GIF for compatibility
        if isAnimated {
            if let gifData = ImageIngestService.convertAnimatedHEICToGIF(imageData) {
                pasteboard.setData(gifData, forType: .png) // Many apps handle GIF via PNG type
                pasteboard.setData(gifData, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
                return .success
            }
        }

        // Convert HEIC to TIFF for wider app compatibility
        if let tiffData = convertHEICToTIFF(imageData) {
            pasteboard.setData(tiffData, forType: .tiff)
            return .success
        }

        // Fallback: use original data
        pasteboard.setData(imageData, forType: .png)
        return .success
    }

    private static func convertHEICToTIFF(_ heicData: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(heicData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let tiffData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            tiffData as CFMutableData,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return tiffData as Data
    }

    // MARK: - File Handling

    private static func copyFilesToPasteboard(files: [FileEntry], pasteboard: NSPasteboard) -> PasteResult {
        var urls: [NSURL] = []

        for file in files {
            // Resolve bookmark to URL
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: file.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                continue
            }

            // Start security-scoped access
            let accessed = url.startAccessingSecurityScopedResource()
            if accessed {
                urls.append(url as NSURL)
                // Note: we'd need to track these for later stopAccessingSecurityScopedResource
            }
        }

        guard !urls.isEmpty else {
            return .bookmarkResolutionFailed
        }

        // Copy file URLs to pasteboard
        pasteboard.writeObjects(urls)
        return .success
    }

    // MARK: - Auto-Paste

    @MainActor
    static func autoPaste(delay: TimeInterval = 0.1) {
        Task {
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            simulatePasteKeypress()
        }
    }

    private static func simulatePasteKeypress() {
        // Create Cmd+V key event
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
