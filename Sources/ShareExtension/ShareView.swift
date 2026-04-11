import ClipKittyShared
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Minimal share-sheet UI: saves shared items, shows brief confirmation, then dismisses.
@MainActor
struct ShareView: View {
    let items: [NSItemProvider]
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var state: ShareState = .saving

    enum ShareState: Equatable {
        case saving
        case succeeded(Int)
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                switch state {
                case .saving:
                    ProgressView()
                        .controlSize(.large)
                    Text("Saving to ClipKitty…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case let .succeeded(count):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text(count == 1
                        ? String(localized: "Saved to ClipKitty")
                        : String(localized: "Saved \(count) items to ClipKitty"))
                        .font(.subheadline.weight(.medium))

                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .animation(.snappy, value: state)
        }
        .task {
            await saveItems()
        }
    }

    private func saveItems() async {
        var savedCount = 0

        for provider in items {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if await enqueueImage(from: provider) {
                    savedCount += 1
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if await enqueueURL(from: provider) {
                    savedCount += 1
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if await enqueueText(from: provider) {
                    savedCount += 1
                }
            }
        }

        if savedCount > 0 {
            state = .succeeded(savedCount)
            dismissAfterDelay(seconds: 0.6)
        } else {
            state = .failed(String(localized: "Nothing to save"))
            dismissAfterDelay(seconds: 1.5)
        }
    }

    // MARK: - Item Extraction

    private func enqueueText(from provider: NSItemProvider) async -> Bool {
        guard let text = try? await provider.loadItem(
            forTypeIdentifier: UTType.plainText.identifier
        ) as? String, !text.isEmpty else {
            return false
        }
        return (try? PendingShareQueue.enqueueText(text)) != nil
    }

    private func enqueueURL(from provider: NSItemProvider) async -> Bool {
        let url: URL?
        if let loaded = try? await provider.loadItem(
            forTypeIdentifier: UTType.url.identifier
        ) {
            url = loaded as? URL ?? (loaded as? String).flatMap(URL.init(string:))
        } else {
            url = nil
        }
        guard let url else { return false }
        return (try? PendingShareQueue.enqueueURL(url.absoluteString)) != nil
    }

    private func enqueueImage(from provider: NSItemProvider) async -> Bool {
        guard let data = try? await loadImageData(from: provider) else {
            return false
        }
        let thumbnail = generateThumbnail(from: data)
        return (try? PendingShareQueue.enqueueImage(imageData: data, thumbnail: thumbnail)) != nil
    }

    private func loadImageData(from provider: NSItemProvider) async throws -> Data {
        let item = try await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        if let data = item as? Data {
            return data
        }
        if let url = item as? URL {
            return try Data(contentsOf: url)
        }
        if let image = item as? UIImage, let data = image.pngData() {
            return data
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func generateThumbnail(from imageData: Data) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        let maxDimension: CGFloat = 200
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1.0)
        let targetSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let thumbnailData = renderer.jpegData(withCompressionQuality: 0.7) { context in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return thumbnailData
    }

    private func dismissAfterDelay(seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            onComplete()
        }
    }
}
