#if ENABLE_LINK_PREVIEWS
import ClipKittyRust
import LinkPresentation
import SwiftUI

// MARK: - Shared LPLinkMetadata Builder

/// Builds an `LPLinkMetadata` from a URL string and `LinkMetadataState`.
/// Used by both macOS and iOS link preview wrappers.
func buildLinkMetadata(url: String, metadataState: LinkMetadataState) -> LPLinkMetadata? {
    guard let urlObj = URL(string: url) else { return nil }
    let metadata = LPLinkMetadata()
    metadata.originalURL = urlObj
    metadata.url = urlObj

    if case let .loaded(payload) = metadataState {
        switch payload {
        case let .titleOnly(title, _):
            metadata.title = title
        case let .imageOnly(imageData, _):
            #if canImport(AppKit)
            if let image = NSImage(data: imageData) {
                metadata.imageProvider = NSItemProvider(object: image)
            }
            #else
            if let image = UIImage(data: imageData) {
                metadata.imageProvider = NSItemProvider(object: image)
            }
            #endif
        case let .titleAndImage(title, imageData, _):
            metadata.title = title
            #if canImport(AppKit)
            if let image = NSImage(data: imageData) {
                metadata.imageProvider = NSItemProvider(object: image)
            }
            #else
            if let image = UIImage(data: imageData) {
                metadata.imageProvider = NSItemProvider(object: image)
            }
            #endif
        }
    }
    return metadata
}

// MARK: - Platform Link Preview Views

#if canImport(UIKit)
import UIKit

/// Native link preview using `LPLinkView` on iOS.
public struct LinkPreviewView: UIViewRepresentable {
    public let url: String
    public let metadataState: LinkMetadataState

    public init(url: String, metadataState: LinkMetadataState) {
        self.url = url
        self.metadataState = metadataState
    }

    public func makeUIView(context _: Context) -> LPLinkView {
        let linkView = LPLinkView()
        if let metadata = buildLinkMetadata(url: url, metadataState: metadataState) {
            linkView.metadata = metadata
        }
        return linkView
    }

    public func updateUIView(_ linkView: LPLinkView, context: Context) {
        guard context.coordinator.lastURL != url ||
            context.coordinator.lastMetadataState != metadataState
        else {
            return
        }
        context.coordinator.lastURL = url
        context.coordinator.lastMetadataState = metadataState

        if let metadata = buildLinkMetadata(url: url, metadataState: metadataState) {
            linkView.metadata = metadata
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var lastURL: String?
        var lastMetadataState: LinkMetadataState?
    }
}

#elseif canImport(AppKit)
import AppKit

/// Native link preview using `LPLinkView` on macOS.
public struct LinkPreviewView: NSViewRepresentable {
    public let url: String
    public let metadataState: LinkMetadataState

    public init(url: String, metadataState: LinkMetadataState) {
        self.url = url
        self.metadataState = metadataState
    }

    public func makeNSView(context _: Context) -> LPLinkView {
        let linkView = LPLinkView()
        if let metadata = buildLinkMetadata(url: url, metadataState: metadataState) {
            linkView.metadata = metadata
        }
        return linkView
    }

    public func updateNSView(_ linkView: LPLinkView, context: Context) {
        guard context.coordinator.lastURL != url ||
            context.coordinator.lastMetadataState != metadataState
        else {
            return
        }
        context.coordinator.lastURL = url
        context.coordinator.lastMetadataState = metadataState

        if let metadata = buildLinkMetadata(url: url, metadataState: metadataState) {
            linkView.metadata = metadata
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var lastURL: String?
        var lastMetadataState: LinkMetadataState?
    }
}
#endif // canImport
#endif // ENABLE_LINK_PREVIEWS
