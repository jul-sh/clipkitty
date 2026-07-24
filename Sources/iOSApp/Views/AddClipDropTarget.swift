import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// Makes this view a window-wide drop target that saves dropped content
    /// (images, URLs, text) as new clips — the drag-and-drop counterpart of
    /// the + menu's paste/import paths.
    func addClipDropTarget() -> some View {
        modifier(AddClipDropTarget())
    }
}

/// Accepts drags from other apps anywhere over the window and adds them to
/// the history, with the same toast/haptic/refresh choreography as the other
/// add paths. ClipKitty's own card drags are recognized (via
/// `DragItemProvider.internalDragMarker`) and declined so dragging a clip
/// around the app never duplicates it. In practice cross-app drags exist on
/// iPad today, but nothing here is idiom-gated — an iPhone that can source a
/// drag gets the same behavior for free.
private struct AddClipDropTarget: ViewModifier {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: DroppedClipReader.acceptedTypes,
                delegate: ClipDropDelegate(
                    ingest: { providers in
                        Task { await ingest(providers) }
                    }
                )
            )
    }

    /// Saves every readable payload in the drop, then reports once for the
    /// whole batch — one "Added" toast, not a volley.
    @MainActor
    private func ingest(_ providers: [NSItemProvider]) async {
        var savedAny = false
        var failedAny = false

        for provider in providers {
            guard let payload = await DroppedClipReader.load(from: provider) else {
                failedAny = true
                continue
            }

            let result: Result<String, ClipboardError>
            switch payload {
            case let .image(data, isAnimated):
                let thumbnail = UIImage(data: data)?
                    .preparingThumbnail(of: CGSize(width: 200, height: 200))?
                    .jpegData(compressionQuality: 0.7)
                result = await appState.saveImage(
                    imageData: data,
                    thumbnail: thumbnail,
                    sourceApp: "Drop",
                    sourceAppBundleId: nil,
                    isAnimated: isAnimated
                )
            case let .url(url):
                result = await container.repository.saveText(
                    text: url.absoluteString,
                    sourceApp: "Drop",
                    sourceAppBundleId: nil
                )
            case let .text(text):
                result = await container.repository.saveText(
                    text: text,
                    sourceApp: "Drop",
                    sourceAppBundleId: nil
                )
            }

            switch result {
            case .success: savedAny = true
            case .failure: failedAny = true
            }
        }

        if savedAny {
            haptics.fire(.success)
            appState.showToast(.addSucceeded)
            appState.refreshFeed()
        } else if failedAny {
            haptics.fire(.destructive)
            appState.showToast(.addFailed(String(localized: "Could not read dropped content")))
        }
    }
}

/// Session gatekeeper for the drop target: ClipKitty's own card drags are
/// rejected at validation time — no dead drop — because the clip already
/// lives in the store; everything else is handed to `ingest` on release.
private struct ClipDropDelegate: DropDelegate {
    let ingest: ([NSItemProvider]) -> Void

    /// Providers worth saving: conforming to an accepted type and not marked
    /// as one of our own card drags. Type metadata (unlike item data) is
    /// readable while the drag merely hovers, so validation can filter on it.
    private func externalProviders(_ info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: DroppedClipReader.acceptedTypes)
            .filter { !DroppedClipReader.isInternalDrag($0) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        !externalProviders(info).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = externalProviders(info)
        guard !providers.isEmpty else { return false }
        ingest(providers)
        return true
    }
}
