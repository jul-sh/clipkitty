import ClipKittyRust
import ClipKittyShared
import Foundation
import os
import UIKit

/// Keeps the keyboard extension's snapshot (`KeyboardFeedStore`) in step with
/// clipboard history.
///
/// Refreshes deliberately avoid the foreground: the Rust store allows one
/// active search, so a snapshot search racing the browser's live search would
/// cancel it mid-keystroke. The keyboard is also unusable while ClipKitty
/// itself is frontmost, so a foreground snapshot could never be observed
/// anyway. Instead the snapshot is rewritten at the two moments that matter:
/// when the app suspends (covering every in-app mutation, right before the
/// store is released) and after background sync lands new content while the
/// app isn't active.
@MainActor
final class KeyboardFeedService {
    private nonisolated static let logger = Logger(subsystem: "com.clipkitty", category: "KeyboardFeed")

    private let repository: ClipboardRepository
    /// Overrides the App Group snapshot location; tests use it to stay hermetic.
    private let baseDirectory: URL?
    private var scheduledRefresh: Task<Void, Never>?

    /// Coalesces change bursts (a sync batch reports one change per item).
    private static let debounceInterval: Duration = .seconds(1)

    init(repository: ClipboardRepository, baseDirectory: URL? = nil) {
        self.repository = repository
        self.baseDirectory = baseDirectory
    }

    /// Called whenever feed content changes. Only refreshes if the app is
    /// still non-active when the debounce fires (i.e. a background-sync
    /// change); foreground changes are picked up by `refreshOnSuspension()`.
    func scheduleRefresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            guard UIApplication.shared.applicationState != .active else { return }
            await self.refresh()
        }
    }

    /// Called while the app prepares for suspension, before the store is
    /// released. This is the moment the snapshot has to be right: the user is
    /// leaving for another app, where the keyboard may come up next.
    func refreshOnSuspension() async {
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        await refresh()
    }

    private func refresh() async {
        let outcome = await repository.search(query: "", filter: .all, presentation: .card)
        guard case let .success(result) = outcome else { return }

        let candidateIds = result.matches
            .map(\.itemMetadata)
            .filter { Self.isInsertable(icon: $0.icon) }
            .prefix(KeyboardFeedStore.maxItems)
            .map(\.itemId)

        let fetched = await repository.fetchItems(ids: Array(candidateIds))
        let byId = Dictionary(fetched.map { ($0.itemMetadata.itemId, $0) }) { first, _ in first }
        let items = candidateIds.compactMap { byId[$0].flatMap(Self.feedItem(from:)) }

        do {
            try KeyboardFeedStore.write(items: items, in: baseDirectory)
        } catch {
            Self.logger.error("Keyboard feed write failed: \(error.localizedDescription)")
        }
    }

    /// The keyboard inserts text at the cursor, so only text-representable
    /// kinds belong in its feed. Images and files are excluded (their bytes
    /// can't go through `UITextDocumentProxy`).
    private static func isInsertable(icon: ItemIcon) -> Bool {
        switch icon {
        case let .symbol(iconType):
            return iconType == .text || iconType == .link || iconType == .color
        case .colorSwatch:
            return true
        case .thumbnail:
            return false
        }
    }

    private static func feedItem(from item: ClipboardItem) -> KeyboardFeedStore.Item? {
        let metadata = item.itemMetadata
        let kind: KeyboardFeedStore.Item.Kind
        let text: String
        var colorRGBA: UInt32?

        switch item.content {
        case let .text(value):
            kind = .text
            text = value
        case let .link(url, _):
            kind = .link
            text = url
        case let .color(value):
            kind = .color
            text = value
            if case let .colorSwatch(rgba) = metadata.icon {
                colorRGBA = rgba
            }
        case .image, .file:
            return nil
        }

        guard !text.isEmpty, text.count <= KeyboardFeedStore.maxInsertableTextLength else { return nil }

        return KeyboardFeedStore.Item(
            id: metadata.itemId,
            kind: kind,
            text: text,
            sourceApp: metadata.sourceApp,
            timestampUnix: metadata.timestampUnix,
            colorRGBA: colorRGBA
        )
    }
}
